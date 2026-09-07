import 'dart:async';

import 'package:air_gesture/air_gesture.dart';
import 'package:flutter/widgets.dart';

import '../core/drop_prefs.dart';
import '../core/panel_window.dart';
import 'air_grab_camera.dart';
import 'drop_service.dart';

enum AirGrabHud {
  hidden,
  palm,
  holding,
  catchPrompt,
  pick,
  sending,
}

class AirGrabSession extends ChangeNotifier with WidgetsBindingObserver {
  AirGrabSession._();
  static final instance = AirGrabSession._();

  final _fsm = AirGrabFsm(
    palmFramesNeeded: 2,
    fistFramesNeeded: 4,
    cancelPalmFrames: 4,
    lostFramesNeeded: 4,
  );
  List<DropOutgoing> _queue = const [];
  var _armed = false;
  StreamSubscription<HandObservation>? _frames;
  var _attached = false;
  var _catching = false;
  var _catchFogShown = false;
  var _catchClaimed = false;
  var _sending = false;
  DropSendCancelToken? _sendCancel;
  var _handingOff = false;
  final _catchHolders = CatchHolderLatch<DropPeer>();
  final _handLatch = HandSeenLatch(onNeeded: 2, offNeeded: 2);

  AirGrabHud hud = AirGrabHud.hidden;
  String catchFrom = '';
  String facingName = '';
  var facingCatch = false;
  var catchLocked = false;
  String status = '';
  List<DropPeer> pickPeers = const [];
  DropSendProgress? sendProgress;

  bool get enabled => DropPrefs.airGrabEnabled;
  bool get armed => _armed;
  List<DropOutgoing> get queue => _queue;

  DropPeer? get _holdingPeer {
    for (final peer in DropService.instance.peerList) {
      if (peer.isHolding) return peer;
    }
    return null;
  }

  DropPeer? get _activeHolder => _catchHolders.remember(_holdingPeer);

  List<AirDropPeer> get _nearby => [
        for (final peer in DropService.instance.peerList) peer.airPeer,
      ];

  bool get _nearbyOtherCamera {
    final holderId = _activeHolder?.id;
    return DropService.instance.peerList.any(
      (peer) => peer.camera && peer.id != holderId,
    );
  }

  bool get _wantCatchFog =>
      enabled &&
      !_catchClaimed &&
      airGrabShouldShowCatchBeacon(
        armed: _armed,
        selfHolding: hud == AirGrabHud.holding,
        peerHolding: _activeHolder != null,
        selfHasCamera: DropService.instance.cameraCapable,
        nearbyOtherCamera: _nearbyOtherCamera,
      );

  void _refreshFacing() {
    _noteFacing(
      resolveLeftFrame(
        nearby: _nearby,
        holdTimedOut: false,
      ),
    );
  }

  void _noteFacing(LeftFrameDecision decision) {
    _publishAim(decision.target?.id);
    final name = decision.target?.name ?? '';
    final catchPalm = decision.action == LeftFrameAction.waitCatch;
    if (name == facingName && catchPalm == facingCatch) return;
    facingName = name;
    facingCatch = catchPalm;
    notifyListeners();
  }

  void _publishAim(String? id) {
    DropService.instance.setAim(_handingOff ? id : null);
  }

  bool get _aimedAtMe {
    final self = DropService.instance.peerId;
    return _activeHolder?.aimsAt(self) ?? false;
  }

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    PanelWindow.onVisibilityChanged = () {
      unawaited(_syncCamera());
    };
    DropService.instance.peers.stream.listen((_) => _onPeers());
    DropService.instance.catches.stream.listen(_onCatch);
    await refreshCapability();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_stopCamera());
      return;
    }
    unawaited(_syncCamera());
  }

  Future<void> refreshCapability() async {
    if (!enabled) {
      DropService.instance.setCameraCapable(false);
      await disarm();
      return;
    }
    final cam = await AirGrabCamera.hasCamera();
    DropService.instance.setCameraCapable(cam);
    await _syncCamera();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    await DropPrefs.setAirGrabEnabled(value);
    await refreshCapability();
  }

  Future<void> arm(List<DropOutgoing> files) async {
    if (!enabled || files.isEmpty) return;
    _queue = List<DropOutgoing>.of(files);
    _armed = true;
    _fsm.reset();
    hud = AirGrabHud.hidden;
    pickPeers = const [];
    unawaited(PanelWindow.show(force: true));
    await _syncCamera();
    notifyListeners();
  }

  Future<void> disarm() async {
    _armed = false;
    _catchHolders.clear();
    DropService.instance.setHolding(null);
    DropService.instance.setAim(null);
    if (hud == AirGrabHud.palm ||
        hud == AirGrabHud.holding ||
        hud == AirGrabHud.pick) {
      hud = AirGrabHud.hidden;
      pickPeers = const [];
    }
    await _syncCamera();
    notifyListeners();
  }

  Future<void> pick(DropPeer peer) async {
    pickPeers = const [];
    await _sendTo(peer);
  }

  Future<void> cancelGrab() async {
    if (_sending) {
      _sendCancel?.cancel();
      return;
    }
    _handingOff = false;
    _fsm.reset();
    pickPeers = const [];
    facingName = '';
    facingCatch = false;
    DropService.instance.setHolding(null);
    DropService.instance.setAim(null);
    hud = AirGrabHud.hidden;
    notifyListeners();
    await _syncCamera();
  }

  Future<void> dismissPick() => cancelGrab();

  void _onPeers() {
    _refreshFacing();
    final holder = _activeHolder;
    if (_catchClaimed && holder == null) {
      _catchClaimed = false;
    }
    if (_wantCatchFog) {
      catchFrom = holder!.name;
      if (!_catchFogShown || hud != AirGrabHud.catchPrompt) {
        _catchFogShown = true;
        hud = AirGrabHud.catchPrompt;
        unawaited(PanelWindow.showBeacon(locked: catchLocked));
        notifyListeners();
      }
      _applyCatchLock();
    } else if (_catchFogShown || hud == AirGrabHud.catchPrompt || PanelWindow.beacon) {
      _catchFogShown = false;
      _handLatch.reset();
      DropService.instance.setSeesHand(false);
      catchLocked = false;
      hud = AirGrabHud.hidden;
      catchFrom = '';
      unawaited(PanelWindow.hideBeacon());
      notifyListeners();
    }
    unawaited(_syncCamera());
  }

  void _noteCatchHand(bool sees) {
    if (!_handLatch.ingest(sees)) return;
    DropService.instance.setSeesHand(_handLatch.latched);
    _applyCatchLock();
  }

  void _updateCatchHand(HandObservation frame) {
    _noteCatchHand(
      airGrabCatchSeesChosen(
        inFrame: frame.inFrame,
        shape: frame.shape,
        alreadyChosen: _handLatch.latched,
      ),
    );
  }

  void _applyCatchLock() {
    final next = airGrabCatchFogKind(
          aimedAtMe: _aimedAtMe,
          seesHand: _handLatch.latched,
        ) ==
        AirGrabFogKind.lock;
    _setCatchLocked(next);
  }

  void _setCatchLocked(bool next) {
    if (catchLocked == next) return;
    catchLocked = next;
    notifyListeners();
    if (_wantCatchFog) {
      unawaited(PanelWindow.showBeacon(locked: catchLocked));
    }
  }

  void _onCatch(DropPeer peer) {
    if (_sending || !_armed || _queue.isEmpty) return;
    if (!_handingOff && hud != AirGrabHud.holding) return;
    unawaited(_sendTo(peer));
  }

  Future<void> _syncCamera() async {
    // Windows: never idle-watch the webcam (that hung Liv). Only open for an
    // active send or catch session. Process Job Object caps (80% CPU / RAM)
    // stay on regardless.
    if (!enabled || _sending || _handingOff) {
      await _stopCamera();
      return;
    }
    final wantSender = airGrabWantSenderCamera(
      resumed: PanelWindow.visible,
      surfaceArmed: _armed && _queue.isNotEmpty,
      wantCatch: false,
    );
    final wantCatch = !_catchClaimed &&
        airGrabWantCatchCamera(
      enabled: enabled,
      sending: _sending,
      handingOff: _handingOff,
      selfHolding: wantSender,
      peerHolding: _activeHolder != null,
    ) &&
        DropService.instance.cameraCapable;
    // Idle "nearby watch" kept the webcam open whenever any peer was on
    // the LAN — that burned CPU continuously on Windows. Stay off.
    const wantNearby = false;
    _catching = wantCatch;
    if (!wantSender && !wantCatch && !wantNearby) {
      await _stopCamera();
      return;
    }
    _frames ??= AirGrabCamera.frames.listen(_onFrame);
    final ok = await AirGrabCamera.start();
    if (!ok) return;
    if (!DropService.instance.cameraCapable) {
      DropService.instance.setCameraCapable(true);
    }
  }

  Future<void> _stopCamera() async {
    await _frames?.cancel();
    _frames = null;
    await AirGrabCamera.stop();
    DropService.instance.setAttention(0);
    DropService.instance.setSeesHand(false);
    if (!_armed) DropService.instance.setHolding(null);
  }

  void _onFrame(HandObservation frame) {
    DropService.instance.setAttention(frame.gaze.attention);
    if (_handingOff) return;
    if (_catching) {
      _updateCatchHand(frame);
      final event = _fsm.ingestReceiver(
        frame,
        peerHolding: _activeHolder != null,
        aimedAtThisScreen: true,
      );
      if (event.phase == AirGrabPhase.catchPalm) {
        final holder = _activeHolder;
        _catchClaimed = true;
        _catching = false;
        if (holder != null) DropService.instance.sendCatch(holder);
        _catchHolders.clear();
        hud = AirGrabHud.hidden;
        catchFrom = '';
        _catchFogShown = false;
        catchLocked = false;
        _handLatch.reset();
        DropService.instance.setSeesHand(false);
        unawaited(PanelWindow.hideBeacon());
        notifyListeners();
        unawaited(_stopCamera());
      }
      return;
    }
    if (!_armed || _queue.isEmpty) return;
    final event = _fsm.ingestSender(frame);
    switch (event.phase) {
      case AirGrabPhase.palm:
        hud = AirGrabHud.palm;
        DropService.instance.setHolding(null);
        DropService.instance.setAim(null);
      case AirGrabPhase.holding:
        hud = AirGrabHud.holding;
        DropService.instance.setHolding(
          AirHolding(count: _queue.length, kind: _kind()),
        );
      case AirGrabPhase.leftFrame:
        unawaited(_onLeftFrame(timedOut: false));
        return;
      case AirGrabPhase.timedOut:
        unawaited(_onLeftFrame(timedOut: true));
        return;
      case AirGrabPhase.cancelled:
        hud = AirGrabHud.hidden;
        DropService.instance.setHolding(null);
        DropService.instance.setAim(null);
      case AirGrabPhase.idle:
        if (hud == AirGrabHud.palm) hud = AirGrabHud.hidden;
      case AirGrabPhase.catchPalm:
        break;
    }
    notifyListeners();
    if (hud == AirGrabHud.holding) _refreshFacing();
  }

  String _kind() {
    final videos = _queue.where((file) => file.kind == 'video').length;
    if (videos == _queue.length) return 'video';
    return 'photo';
  }

  Future<void> _onLeftFrame({required bool timedOut}) async {
    if (timedOut) {
      await cancelGrab();
      return;
    }
    _handingOff = true;
    notifyListeners();
    await _stopCamera();
    if (!_handingOff) return;
    var decision = resolveLeftFrame(
      nearby: _nearby,
      holdTimedOut: timedOut,
    );
    _noteFacing(decision);
    if (decision.dropsOnLeave) {
      DropService.instance.setHolding(null);
      await _applyLeftFrame(decision);
      return;
    }
    if (!timedOut) {
      final deadline = DateTime.now().add(leftFrameHandoverWait);
      while (DateTime.now().isBefore(deadline) && _handingOff && !_sending) {
        decision = resolveLeftFrame(
          nearby: _nearby,
          holdTimedOut: false,
        );
        _noteFacing(decision);
        if (decision.dropsOnLeave) {
          DropService.instance.setHolding(null);
          await _applyLeftFrame(decision);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }
      if (!_handingOff || _sending) return;
    }
    if (!_handingOff || _sending) return;
    await cancelGrab();
  }

  Future<void> _applyLeftFrame(LeftFrameDecision decision) async {
    if (!_handingOff) return;
    switch (decision.action) {
      case LeftFrameAction.autoSend:
        final target = _peerById(decision.target?.id);
        if (target != null) {
          await _sendTo(target);
          return;
        }
      case LeftFrameAction.pickNoCamera:
      case LeftFrameAction.pickAllDesktops:
        pickPeers = [
          for (final choice in decision.choices)
            if (_peerById(choice.id) != null) _peerById(choice.id)!,
        ];
        if (pickPeers.length == 1) {
          await _sendTo(pickPeers.first);
          return;
        }
        if (pickPeers.isNotEmpty) {
          hud = AirGrabHud.pick;
          unawaited(PanelWindow.show(force: true));
          notifyListeners();
          return;
        }
      case LeftFrameAction.waitCatch:
      case LeftFrameAction.none:
        break;
    }
    hud = AirGrabHud.hidden;
    facingName = '';
    _handingOff = false;
    DropService.instance.setAim(null);
    _fsm.reset();
    notifyListeners();
  }

  DropPeer? _peerById(String? id) {
    if (id == null) return null;
    for (final peer in DropService.instance.peerList) {
      if (peer.id == id) return peer;
    }
    return null;
  }

  Future<void> _sendTo(DropPeer peer) async {
    if (_sending || _queue.isEmpty) return;
    _sending = true;
    hud = AirGrabHud.sending;
    status = 'Sending to ${peer.name}';
    DropService.instance.setHolding(null);
    DropService.instance.setAim(null);
    await _stopCamera();
    notifyListeners();
    final cancel = DropSendCancelToken();
    _sendCancel = cancel;
    try {
      await DropService.instance.send(
        peer,
        _queue,
        airGrab: true,
        cancel: cancel,
        onProgress: (next) {
          sendProgress = next;
          notifyListeners();
        },
      );
      status = 'Sent to ${peer.name}';
      _queue = const [];
      _armed = false;
    } on DropCancelled {
      status = '';
    } catch (error) {
      status = '$error';
    }
    _sendCancel = null;
    _sending = false;
    _handingOff = false;
    _fsm.reset();
    sendProgress = null;
    hud = AirGrabHud.hidden;
    pickPeers = const [];
    notifyListeners();
    await _syncCamera();
  }
}
