import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

import '../services/air_grab_session.dart';
import '../services/drop_service.dart';
import 'drop_prefs.dart';
import 'media_size.dart';
import 'panel_window.dart';

enum SendOutcome { ok, declined, failed }

class DropController extends ChangeNotifier {
  DropController() {
    _peers = DropService.instance.peers.stream.listen((list) {
      peers = list;
      notifyListeners();
    });
    _incoming = DropService.instance.incoming.stream.listen((offer) {
      incoming = offer;
      settingsOpen = false;
      notifyListeners();
      PanelWindow.busy = true;
      unawaited(PanelWindow.show(force: true));
    });
    _receiving = DropService.instance.receiving.stream.listen((next) {
      receiveProgress = next;
      incoming = null;
      settingsOpen = false;
      _applyBusy();
      notifyListeners();
      unawaited(PanelWindow.show(force: true));
    });
    _received = DropService.instance.received.stream.listen((batch) {
      toast = batch.message;
      incoming = null;
      _applyBusy();
      unawaited(revealReceivedBatch(batch));
      // Centered media preview is AirGrab-only. Normal LAN One Drop stays quiet
      // (toast + tray panel) so the PC is not interrupted mid-work.
      if (batch.airGrab && batch.paths.isNotEmpty) {
        openPreview(batch.paths, title: 'From ${batch.peerName}');
      } else {
        notifyListeners();
        unawaited(PanelWindow.show(force: true));
      }
      _toastTimer?.cancel();
      _receiveDoneTimer?.cancel();
      _toastTimer = Timer(const Duration(seconds: 4), () {
        toast = null;
        notifyListeners();
      });
      _receiveDoneTimer = Timer(const Duration(milliseconds: 800), () {
        if (receiveProgress?.done != true) return;
        receiveProgress = null;
        _applyBusy();
        notifyListeners();
      });
    });
    peers = DropService.instance.peerList;
  }

  late final StreamSubscription<List<DropPeer>> _peers;
  late final StreamSubscription<DropOffer> _incoming;
  late final StreamSubscription<DropReceiveProgress> _receiving;
  late final StreamSubscription<DropReceivedBatch> _received;
  Timer? _toastTimer;
  Timer? _receiveDoneTimer;
  int _sendGen = 0;

  List<DropPeer> peers = const [];
  DropOffer? incoming;
  DropReceiveProgress? receiveProgress;
  List<DropOutgoing> pending = const [];
  DropSendProgress? progress;
  DropSendCancelToken? cancel;
  SendOutcome? outcome;
  String error = '';
  String? toast;
  List<String>? previewPaths;
  String? previewTitle;
  bool settingsOpen = false;
  bool picking = false;

  bool get transferring =>
      (progress != null && outcome == null && cancel != null) ||
      (receiveProgress != null && receiveProgress?.done != true);

  void _applyBusy() {
    PanelWindow.busy =
        incoming != null || transferring || receiveProgress != null || previewPaths != null;
  }

  void openSettings() {
    settingsOpen = true;
    notifyListeners();
    unawaited(PanelWindow.show());
  }

  void closeSettings() {
    settingsOpen = false;
    notifyListeners();
  }

  /// Phone back swipe. Never leaves the app; only unwinds in-app chrome.
  /// Returns true when something in-app was dismissed (so the activity
  /// must not finish).
  bool handleSystemBack() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (previewPaths != null) {
      closePreview();
      return true;
    }
    if (settingsOpen) {
      closeSettings();
      return true;
    }
    if (outcome != null) {
      clearSend();
      return true;
    }
    if (progress != null && cancel != null) {
      abortSend();
      return true;
    }
    if (receiveProgress != null) {
      abortReceive();
      return true;
    }
    return false;
  }

  void refresh() => notifyListeners();

  void queue(List<DropOutgoing> files) {
    if (files.isEmpty) return;
    pending = files;
    settingsOpen = false;
    outcome = null;
    error = '';
    notifyListeners();
  }

  void armAirGrab() {
    if (pending.isEmpty || !DropPrefs.airGrabEnabled) return;
    unawaited(AirGrabSession.instance.arm(pending));
    settingsOpen = false;
    notifyListeners();
    unawaited(PanelWindow.show(force: true));
  }

  void decideIncoming(bool accept) {
    final offer = incoming;
    if (offer == null) return;
    DropService.instance.decide(offer, accept);
    incoming = null;
    if (accept) {
      receiveProgress = DropService.instance.currentReceive ??
          DropReceiveProgress(
            offerId: offer.id,
            peerName: offer.peerName,
            receivedBytes: 0,
            totalBytes: dropOfferTotalBytes(offer.files),
            fileIndex: 0,
            fileCount: offer.files.length,
          );
    }
    _applyBusy();
    notifyListeners();
  }

  Future<void> sendTo(DropPeer peer) async {
    if (pending.isEmpty || transferring) return;
    unawaited(AirGrabSession.instance.disarm());
    final gen = ++_sendGen;
    final token = DropSendCancelToken();
    cancel = token;
    outcome = null;
    error = '';
    progress = DropSendProgress(
      phase: DropSendPhase.waiting,
      peerName: peer.name,
      fraction: 0,
      label: 'Waiting for ${peer.name} to accept',
    );
    PanelWindow.busy = true;
    notifyListeners();
    unawaited(PanelWindow.show(force: true));
    try {
      await DropService.instance.send(
        peer,
        pending,
        cancel: token,
        onProgress: (next) {
          if (gen != _sendGen || outcome != null) return;
          progress = next;
          notifyListeners();
        },
      );
      if (gen != _sendGen || token.isCancelled) return;
      outcome = SendOutcome.ok;
      pending = const [];
    } on DropCancelled {
      if (gen != _sendGen) return;
      progress = null;
      cancel = null;
      _applyBusy();
      notifyListeners();
      return;
    } on DropDeclined {
      if (gen != _sendGen || token.isCancelled) return;
      outcome = SendOutcome.declined;
    } catch (err) {
      if (gen != _sendGen || token.isCancelled) return;
      outcome = SendOutcome.failed;
      error = '$err';
    }
    if (gen != _sendGen) return;
    cancel = null;
    _applyBusy();
    notifyListeners();
  }

  void abortSend() {
    if (outcome != null) {
      clearSend();
      return;
    }
    _sendGen++;
    cancel?.cancel();
    progress = null;
    cancel = null;
    _applyBusy();
    notifyListeners();
  }

  void abortReceive() {
    DropService.instance.abortReceive();
    receiveProgress = null;
    incoming = null;
    _receiveDoneTimer?.cancel();
    _applyBusy();
    notifyListeners();
  }

  void clearReceive() {
    receiveProgress = null;
    _receiveDoneTimer?.cancel();
    _applyBusy();
    notifyListeners();
  }

  void clearSend() {
    _sendGen++;
    progress = null;
    cancel = null;
    outcome = null;
    error = '';
    pending = const [];
    unawaited(AirGrabSession.instance.disarm());
    _applyBusy();
    notifyListeners();
  }


  void openPreview(List<String> paths, {String? title}) {
    final existing = [
      for (final path in paths)
        if (path.isNotEmpty && File(path).existsSync()) path,
    ];
    if (existing.isEmpty) return;
    previewPaths = existing;
    previewTitle = title;
    settingsOpen = false;
    // Drop receive chrome — the little docked panel should not linger.
    if (receiveProgress?.done == true) {
      receiveProgress = null;
    }
    _applyBusy();
    notifyListeners();
    unawaited(_presentPreviewWindow(existing));
  }

  Future<void> _presentPreviewWindow(List<String> paths) async {
    final screen = await PanelWindow.screenVisibleSize();
    final Size window;
    if (paths.length == 1) {
      window = await previewWindowSizeForPath(paths.first, screen);
    } else {
      window = gridPreviewWindowSize(screen);
    }
    await PanelWindow.showCenteredPreview(window);
  }

  void previewPending() {
    openPreview(
      [for (final item in pending) item.file.path],
      title: 'Ready to send',
    );
  }

  void closePreview() {
    if (previewPaths == null) return;
    previewPaths = null;
    previewTitle = null;
    _applyBusy();
    notifyListeners();
    unawaited(PanelWindow.endPreview(hideWindow: true));
  }

  @override
  void dispose() {
    _peers.cancel();
    _incoming.cancel();
    _receiving.cancel();
    _received.cancel();
    _toastTimer?.cancel();
    _receiveDoneTimer?.cancel();
    super.dispose();
  }
}
