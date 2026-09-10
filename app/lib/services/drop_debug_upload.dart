import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../core/drop_prefs.dart';
import 'drop_debug.dart';
import 'drop_debug_log.dart';

/// Opt-in Nearby debug: ring buffer plus uploads until the user turns it off.
///
/// Interval stays at 8 minutes so a phone stays well under the 24-uploads/hour
/// gate on aml.one. Significant radio / network events coalesce to the same
/// floor so we do not poll the UI thread.
class DropDebugUpload with WidgetsBindingObserver {
  DropDebugUpload._();

  static final DropDebugUpload instance = DropDebugUpload._();

  static const _period = Duration(minutes: 8);

  Timer? _timer;
  DateTime? _lastUploadAt;
  String? lastStatus;
  bool _busy = false;
  bool _wired = false;

  void attach() {
    if (_wired) return;
    _wired = true;
    DropDebugLog.onSignificant = (kind) {
      unawaited(_maybeUpload(kind));
    };
    WidgetsBinding.instance.addObserver(this);
    if (DropPrefs.debugUploadOptIn) {
      _armTimer();
      unawaited(_maybeUpload('start', force: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && DropPrefs.debugUploadOptIn) {
      DropDebugLog.event('resume');
      unawaited(_maybeUpload('resume'));
    }
  }

  Future<void> setOptIn(bool value) async {
    await DropPrefs.setDebugUploadOptIn(value);
    if (!value) {
      _timer?.cancel();
      _timer = null;
      lastStatus = 'Off';
      DropDebugLog.event('opt_out');
      return;
    }
    DropDebugLog.event('opt_in');
    _armTimer();
    await _maybeUpload('opt_in', force: true);
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_period, (_) {
      unawaited(_maybeUpload('timer'));
    });
  }

  Future<void> _maybeUpload(String trigger, {bool force = false}) async {
    if (!DropPrefs.debugUploadOptIn) return;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    if (_busy) return;
    final last = _lastUploadAt;
    if (!force && last != null && DateTime.now().difference(last) < _period) {
      return;
    }
    _busy = true;
    try {
      final id = await uploadOneDropDebug(trigger: trigger);
      _lastUploadAt = DateTime.now();
      lastStatus = 'Uploaded $id';
    } catch (error) {
      lastStatus = 'Upload failed ($error)';
    } finally {
      _busy = false;
    }
  }
}
