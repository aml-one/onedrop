import 'package:air_gesture/air_gesture.dart';
import 'package:test/test.dart';

const _away = GazeObservation(known: true, face: true, looking: false, attention: 0.1);
const _atScreen = GazeObservation(
  known: true,
  face: true,
  looking: true,
  attention: 0.8,
);
const _palm = HandObservation(
  shape: HandShape.palm,
  inFrame: true,
  score: 1,
  gaze: _atScreen,
);
const _fist = HandObservation(
  shape: HandShape.fist,
  inFrame: true,
  score: 1,
  gaze: _atScreen,
);
const _gone = HandObservation(shape: HandShape.none, inFrame: false);
const _maybe = HandObservation(shape: HandShape.none, inFrame: true);
const _fistAway = HandObservation(
  shape: HandShape.fist,
  inFrame: true,
  score: 1,
  gaze: _away,
);
const _fistLooking = HandObservation(
  shape: HandShape.fist,
  inFrame: true,
  score: 1,
  gaze: _atScreen,
);
const _palmAway = HandObservation(
  shape: HandShape.palm,
  inFrame: true,
  score: 1,
  gaze: _away,
);

void main() {
  test('palm then fist becomes a hold; leaving the frame fires leftFrame', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      lostFramesNeeded: 4,
    );
    AirGrabPhase phase = AirGrabPhase.idle;
    for (var i = 0; i < 3; i++) {
      phase = fsm.ingestSender(_palm).phase;
    }
    expect(phase, AirGrabPhase.palm);
    for (var i = 0; i < 3; i++) {
      phase = fsm.ingestSender(_fist).phase;
    }
    expect(phase, AirGrabPhase.holding);
    AirGrabEvent? left;
    for (var i = 0; i < 4; i++) {
      left = fsm.ingestSender(_gone);
    }
    expect(left!.phase, AirGrabPhase.leftFrame);
    expect(left.wasStableHold, isTrue);
  });

  test('a blink of lost tracking does not count as walking away', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      lostFramesNeeded: 4,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    fsm.ingestSender(_gone);
    fsm.ingestSender(_gone);
    expect(fsm.ingestSender(_fist).phase, AirGrabPhase.holding);
  });

  test('opening the palm while holding returns to close-your-hand', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      cancelPalmFrames: 12,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    for (var i = 0; i < 11; i++) {
      expect(fsm.ingestSender(_palm).phase, AirGrabPhase.holding);
    }
    expect(fsm.ingestSender(_palm).phase, AirGrabPhase.palm);
    fsm.ingestSender(_fist);
    fsm.ingestSender(_fist);
    expect(fsm.ingestSender(_fist).phase, AirGrabPhase.holding);
  });

  test('a fist flicker while opening the palm still cancels the hold', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      cancelPalmFrames: 4,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    fsm.ingestSender(_palm);
    fsm.ingestSender(_palm);
    fsm.ingestSender(_fist);
    fsm.ingestSender(_palm);
    expect(fsm.ingestSender(_palm).phase, AirGrabPhase.palm);
  });

  test('one palm flicker does not drop a hold', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 3, fistFramesNeeded: 3);
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    expect(fsm.ingestSender(_palm).phase, AirGrabPhase.holding);
    expect(fsm.ingestSender(_fist).phase, AirGrabPhase.holding);
  });

  test('receiver only catches while a peer is holding', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 3);
    for (var i = 0; i < 3; i++) {
      expect(
        fsm.ingestReceiver(_palm, peerHolding: false).phase,
        AirGrabPhase.idle,
      );
    }
    AirGrabPhase phase = AirGrabPhase.idle;
    for (var i = 0; i < 3; i++) {
      phase = fsm
          .ingestReceiver(
            _palm,
            peerHolding: true,
            aimedAtThisScreen: true,
          )
          .phase;
    }
    expect(phase, AirGrabPhase.catchPalm);
  });

  test('receiver catches an open palm while a peer is holding, even before aim', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 2);
    AirGrabPhase phase = AirGrabPhase.idle;
    for (var i = 0; i < 2; i++) {
      phase = fsm
          .ingestReceiver(
            _palm,
            peerHolding: true,
            aimedAtThisScreen: false,
          )
          .phase;
    }
    expect(phase, AirGrabPhase.catchPalm);
  });

  test('a few empty frames do not drop an open palm', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      lostFramesNeeded: 4,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    fsm.ingestSender(_gone);
    fsm.ingestSender(_gone);
    expect(fsm.ingestSender(_gone).phase, AirGrabPhase.palm);
    expect(fsm.ingestSender(_gone).phase, AirGrabPhase.idle);
  });

  test('a couple of unlabeled frames during palm still allow a fist', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      lostFramesNeeded: 4,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    expect(fsm.ingestSender(_maybe).phase, AirGrabPhase.palm);
    expect(fsm.ingestSender(_maybe).phase, AirGrabPhase.palm);
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    expect(fsm.phase, AirGrabPhase.holding);
  });

  test('an unlabeled in-frame blob during palm does not drop the grab', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      lostFramesNeeded: 4,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    fsm.ingestSender(_maybe);
    fsm.ingestSender(_maybe);
    fsm.ingestSender(_maybe);
    expect(fsm.ingestSender(_maybe).phase, AirGrabPhase.palm);
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    expect(fsm.phase, AirGrabPhase.holding);
  });

  test('a palm during the close resets the fist and does not false-grab', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    fsm.ingestSender(_fist);
    fsm.ingestSender(_palm);
    fsm.ingestSender(_fist);
    fsm.ingestSender(_palm);
    expect(fsm.ingestSender(_fist).phase, AirGrabPhase.palm);
  });

  test('a close after three palms still grabs even if the HUD has not flipped yet', () {
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
    );
    fsm.ingestSender(_palm);
    fsm.ingestSender(_palm);
    fsm.ingestSender(_palm);
    fsm.ingestSender(_fist);
    fsm.ingestSender(_fist);
    expect(fsm.ingestSender(_fist).phase, AirGrabPhase.holding);
  });

  test('fists with no open palm stay idle', () {
    final fsm = AirGrabFsm();
    for (var i = 0; i < 8; i++) {
      expect(fsm.ingestSender(_fist).phase, AirGrabPhase.idle);
    }
  });

  test('hold times out after ten seconds', () {
    var t = DateTime(2026, 8, 30, 16);
    final fsm = AirGrabFsm(
      palmFramesNeeded: 3,
      fistFramesNeeded: 3,
      now: () => t,
    );
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fist);
    }
    t = t.add(const Duration(seconds: 10));
    expect(fsm.ingestSender(_fist).phase, AirGrabPhase.timedOut);
  });

  test('a fist while looking away from this screen does not grab', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 3, fistFramesNeeded: 3);
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      expect(fsm.ingestSender(_fistAway).phase, AirGrabPhase.idle);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_palm);
    }
    for (var i = 0; i < 3; i++) {
      fsm.ingestSender(_fistLooking);
    }
    expect(fsm.phase, AirGrabPhase.holding);
  });

  test('a palm while looking away does not arm a grab', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 3, fistFramesNeeded: 3);
    for (var i = 0; i < 6; i++) {
      expect(fsm.ingestSender(_palmAway).phase, AirGrabPhase.idle);
    }
  });

  test('unknown gaze does not arm a grab', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 3, fistFramesNeeded: 3);
    const blindPalm = HandObservation(
      shape: HandShape.palm,
      inFrame: true,
      score: 1,
    );
    for (var i = 0; i < 6; i++) {
      expect(fsm.ingestSender(blindPalm).phase, AirGrabPhase.idle);
    }
  });

  test('catch camera watches a holding peer even when this app is not in front', () {
    expect(
      airGrabWantCatchCamera(
        enabled: true,
        sending: false,
        handingOff: false,
        selfHolding: false,
        peerHolding: true,
      ),
      isTrue,
    );
    expect(
      airGrabWantSenderCamera(
        resumed: false,
        surfaceArmed: false,
        wantCatch: true,
      ),
      isFalse,
    );
    expect(
      airGrabWantCatchCamera(
        enabled: true,
        sending: false,
        handingOff: false,
        selfHolding: true,
        peerHolding: true,
      ),
      isFalse,
    );
    expect(
      airGrabWantCatchCamera(
        enabled: true,
        sending: false,
        handingOff: false,
        selfHolding: false,
        peerHolding: false,
      ),
      isFalse,
    );
  });

  test('catch beacon still shows when the camera is already watching', () {
    expect(
      airGrabShouldShowCatchBeacon(
        armed: false,
        selfHolding: false,
        peerHolding: true,
      ),
      isTrue,
    );
    expect(
      airGrabShouldShowCatchBeacon(
        armed: true,
        selfHolding: false,
        peerHolding: true,
      ),
      isFalse,
    );
  });

  test('a headless PC stays dark when another camera can catch', () {
    expect(
      airGrabShouldShowCatchBeacon(
        armed: false,
        selfHolding: false,
        peerHolding: true,
        selfHasCamera: false,
        nearbyOtherCamera: true,
      ),
      isFalse,
    );
    expect(
      airGrabShouldShowCatchBeacon(
        armed: false,
        selfHolding: false,
        peerHolding: true,
        selfHasCamera: false,
        nearbyOtherCamera: false,
      ),
      isTrue,
    );
  });

  test('catch fog goes yellow when this camera sees a closed fist', () {
    expect(
      airGrabCatchFogKind(aimedAtMe: false, seesHand: false),
      AirGrabFogKind.discover,
    );
    expect(
      airGrabCatchFogKind(aimedAtMe: true, seesHand: false),
      AirGrabFogKind.discover,
    );
    expect(
      airGrabCatchFogKind(aimedAtMe: false, seesHand: true),
      AirGrabFogKind.lock,
    );
  });

  test('catch lock is a fist, and stays through the open-palm catch', () {
    expect(
      airGrabCatchSeesChosen(
        inFrame: true,
        shape: HandShape.fist,
        alreadyChosen: false,
      ),
      isTrue,
    );
    expect(
      airGrabCatchSeesChosen(
        inFrame: true,
        shape: HandShape.palm,
        alreadyChosen: false,
      ),
      isFalse,
    );
    expect(
      airGrabCatchSeesChosen(
        inFrame: true,
        shape: HandShape.palm,
        alreadyChosen: true,
      ),
      isTrue,
    );
    expect(
      airGrabCatchSeesChosen(
        inFrame: false,
        shape: HandShape.fist,
        alreadyChosen: true,
      ),
      isFalse,
    );
  });

  test('catcher advertises an open palm without waiting for sender aim', () {
    expect(
      airGrabMayAdvertiseCatchHand(aimedAtMe: false, sawHandBeforeAim: true),
      isTrue,
    );
    expect(
      airGrabMayAdvertiseCatchHand(aimedAtMe: true, sawHandBeforeAim: false),
      isTrue,
    );
  });

  test('catch holder latch keeps the peer through a short discovery gap', () {
    var now = DateTime(2026, 8, 31, 12);
    final latch = CatchHolderLatch<String>(
      grace: const Duration(seconds: 12),
      clock: () => now,
    );
    expect(latch.remember('phone'), 'phone');
    expect(latch.remember(null), 'phone');
    now = now.add(const Duration(seconds: 13));
    expect(latch.remember(null), isNull);
    expect(latch.remember('tablet'), 'tablet');
    latch.clear();
    expect(latch.remember(null), isNull);
  });

  test('nearby peers keep the camera on so this screen can be a target again', () {
    expect(
      airGrabWantNearbyWatch(
        enabled: true,
        sending: false,
        handingOff: false,
        hasPeers: true,
      ),
      isTrue,
    );
    expect(
      airGrabWantNearbyWatch(
        enabled: true,
        sending: false,
        handingOff: false,
        hasPeers: false,
      ),
      isFalse,
    );
  });

  test('hand-seen latch ignores one-frame flicker', () {
    final latch = HandSeenLatch(onNeeded: 4, offNeeded: 4);
    expect(latch.ingest(true), isFalse);
    expect(latch.ingest(true), isFalse);
    expect(latch.ingest(false), isFalse);
    expect(latch.latched, isFalse);
    for (var i = 0; i < 3; i++) {
      expect(latch.ingest(true), isFalse);
    }
    expect(latch.ingest(true), isTrue);
    expect(latch.latched, isTrue);
    expect(latch.ingest(false), isFalse);
    expect(latch.latched, isTrue);
    for (var i = 0; i < 2; i++) {
      expect(latch.ingest(false), isFalse);
    }
    expect(latch.ingest(false), isTrue);
    expect(latch.latched, isFalse);
  });

  test('receiver catch accepts an open palm even if the face is not at the camera', () {
    final fsm = AirGrabFsm(palmFramesNeeded: 3);
    AirGrabPhase phase = AirGrabPhase.idle;
    for (var i = 0; i < 3; i++) {
      phase = fsm
          .ingestReceiver(
            _palmAway,
            peerHolding: true,
            aimedAtThisScreen: true,
          )
          .phase;
    }
    expect(phase, AirGrabPhase.catchPalm);
  });
}
