import 'dart:async';
import 'dart:io';

import 'package:air_gesture/air_gesture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AirGrabCamera {
  AirGrabCamera._();

  static const _methods = MethodChannel('one.aml.onedrop/air_grab');
  static const _events = EventChannel('one.aml.onedrop/air_grab/frames');

  static StreamSubscription? _sub;
  static final _frames = StreamController<HandObservation>.broadcast();
  static var _running = false;

  static Stream<HandObservation> get frames => _frames.stream;
  static bool get running => _running;

  static bool get _supported =>
      Platform.isWindows || Platform.isMacOS;

  static Future<bool> hasCamera() async {
    if (!_supported) return false;
    try {
      final cam = await _methods.invokeMethod<bool>('hasCamera') ?? false;
      debugPrint('AIRGRAB hasCamera=$cam');
      return cam;
    } catch (error) {
      debugPrint('AIRGRAB hasCamera fail $error');
      return false;
    }
  }

  static Future<bool> start() async {
    if (!_supported) return false;
    if (_running) return true;
    _sub ??= _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {
      _frames.add(HandObservation.empty);
    });
    try {
      final ok = await _methods.invokeMethod<bool>('start') ?? false;
      _running = ok;
      if (!ok) await stop();
      return ok;
    } catch (_) {
      await stop();
      return false;
    }
  }

  static Future<void> stop() async {
    _running = false;
    if (!_supported) return;
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static void _onEvent(dynamic raw) {
    if (raw is! Map) {
      _frames.add(HandObservation.empty);
      return;
    }
    _frames.add(observationFromFrameMap(Map<Object?, Object?>.from(raw)));
  }
}
