import 'hand_shape.dart';

enum AirGrabPhase {
  idle,
  palm,
  holding,
  leftFrame,
  catchPalm,
  cancelled,
  timedOut,
}

class AirGrabEvent {
  const AirGrabEvent(this.phase, {this.wasStableHold = false});

  final AirGrabPhase phase;
  final bool wasStableHold;
}

/// Sender: open palm → fist hold → open palm here to cancel, or fist leaves the frame to send.
/// Receiver: open palm only while a peer is holding and aimed here.
/// Receiver: open palm only while a peer is holding and aimed here.
class AirGrabFsm {
  AirGrabFsm({
    this.palmFramesNeeded = 6,
    this.fistFramesNeeded = 8,
    this.cancelPalmFrames = 12,
    this.lostFramesNeeded = 4,
    this.holdTimeout = const Duration(seconds: 10),
    this.now,
  });

  final int palmFramesNeeded;
  final int fistFramesNeeded;
  final int cancelPalmFrames;
  final int lostFramesNeeded;
  final Duration holdTimeout;
  DateTime Function()? now;

  AirGrabPhase phase = AirGrabPhase.idle;
  var _palmRun = 0;
  var _fistRun = 0;
  var _lostRun = 0;
  var _stableHold = false;
  DateTime? _holdAt;

  void reset() {
    phase = AirGrabPhase.idle;
    _palmRun = 0;
    _fistRun = 0;
    _lostRun = 0;
    _stableHold = false;
    _holdAt = null;
  }

  DateTime _clock() => now?.call() ?? DateTime.now();

  AirGrabEvent ingestSender(HandObservation frame) {
    if (phase == AirGrabPhase.timedOut ||
        phase == AirGrabPhase.cancelled ||
        phase == AirGrabPhase.leftFrame) {
      reset();
    }

    if (phase == AirGrabPhase.holding) {
      final started = _holdAt;
      if (started != null && _clock().difference(started) >= holdTimeout) {
        phase = AirGrabPhase.timedOut;
        _stableHold = false;
        return const AirGrabEvent(AirGrabPhase.timedOut);
      }
    }

    if (!frame.inFrame) {
      if (phase == AirGrabPhase.holding && _stableHold) {
        _lostRun++;
        if (_lostRun >= lostFramesNeeded) {
          phase = AirGrabPhase.leftFrame;
          return AirGrabEvent(AirGrabPhase.leftFrame, wasStableHold: true);
        }
        return AirGrabEvent(phase, wasStableHold: true);
      }
      _lostRun++;
      if (_lostRun >= lostFramesNeeded) {
        if (phase == AirGrabPhase.palm) {
          phase = AirGrabPhase.idle;
        }
        _palmRun = 0;
        _fistRun = 0;
        _lostRun = 0;
      }
      return AirGrabEvent(phase);
    }

    if (frame.shape == HandShape.none) {
      if (phase == AirGrabPhase.palm || _palmRun > 0) {
        return AirGrabEvent(phase);
      }
      return AirGrabEvent(phase, wasStableHold: _stableHold);
    }

    _lostRun = 0;

    // Grab only while looking at this screen. Once holding, looking away
    // is fine — that is how you face the drop target. Cancel-with-palm
    // while holding also does not need gaze.
    if (phase != AirGrabPhase.holding && !frame.gaze.mayArmGrab) {
      if (frame.shape == HandShape.palm || frame.shape == HandShape.fist) {
        _palmRun = 0;
        _fistRun = 0;
        if (phase == AirGrabPhase.palm) {
          phase = AirGrabPhase.idle;
        }
        return AirGrabEvent(phase);
      }
    }

    if (frame.shape == HandShape.palm) {
      _palmRun++;
      _fistRun = 0;
      if (phase == AirGrabPhase.holding && _stableHold) {
        if (_palmRun >= cancelPalmFrames) {
          phase = AirGrabPhase.palm;
          _stableHold = false;
          _holdAt = null;
          return const AirGrabEvent(AirGrabPhase.palm);
        }
        return AirGrabEvent(phase, wasStableHold: true);
      }
      if (_palmRun >= palmFramesNeeded) {
        phase = AirGrabPhase.palm;
      }
      return AirGrabEvent(phase);
    }

    // Fist — do not wipe palm progress. A close often arrives before the HUD locks.
    _fistRun++;
    if (phase == AirGrabPhase.holding) {
      // One fist flicker while opening the hand must not restart the cancel.
      if (_fistRun >= 2) _palmRun = 0;
    }
    if (phase == AirGrabPhase.idle && _palmRun >= palmFramesNeeded) {
      phase = AirGrabPhase.palm;
    }
    if (phase == AirGrabPhase.palm || phase == AirGrabPhase.holding) {
      if (_fistRun >= fistFramesNeeded) {
        phase = AirGrabPhase.holding;
        _holdAt ??= _clock();
        _stableHold = true;
        _palmRun = 0;
      }
    }
    return AirGrabEvent(phase, wasStableHold: _stableHold);
  }

  AirGrabEvent ingestReceiver(
    HandObservation frame, {
    required bool peerHolding,
    bool aimedAtThisScreen = false,
  }) {
    if (!peerHolding) {
      reset();
      return const AirGrabEvent(AirGrabPhase.idle);
    }
    // An open palm on this camera is the catch. Do not wait for the
    // sender to leave their own camera or publish aim — that left Honor
    // white while the user was already in front of it.
    if (frame.shape == HandShape.palm && frame.inFrame) {
      _palmRun++;
      if (_palmRun >= palmFramesNeeded) {
        phase = AirGrabPhase.catchPalm;
        return const AirGrabEvent(AirGrabPhase.catchPalm);
      }
      return AirGrabEvent(phase);
    }
    _palmRun = 0;
    if (phase == AirGrabPhase.catchPalm) {
      phase = AirGrabPhase.idle;
    }
    return AirGrabEvent(phase);
  }
}
