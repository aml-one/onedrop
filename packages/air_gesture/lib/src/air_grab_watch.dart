import 'hand_shape.dart';

/// When the front camera should run for AirGrab.
///
/// Catch watching follows a peer who is holding — including when this app
/// is in Recents or on the home screen. Sender watching still needs a
/// visible surface (viewer / selection / tray panel).
bool airGrabWantCatchCamera({
  required bool enabled,
  required bool sending,
  required bool handingOff,
  required bool selfHolding,
  required bool peerHolding,
}) {
  if (!enabled || sending || handingOff || selfHolding) return false;
  return peerHolding;
}

bool airGrabWantSenderCamera({
  required bool resumed,
  required bool surfaceArmed,
  required bool wantCatch,
}) {
  return resumed && surfaceArmed && !wantCatch;
}

/// Show the catch beacon whenever a peer is holding, even if the camera
/// watcher is already running from a previous pass.
///
/// A computer without a camera stays dark when another nearby device
/// (not the sender) has a camera — that camera should catch instead.
bool airGrabShouldShowCatchBeacon({
  required bool armed,
  required bool selfHolding,
  required bool peerHolding,
  bool selfHasCamera = true,
  bool nearbyOtherCamera = false,
}) {
  if (!peerHolding || armed || selfHolding) return false;
  if (!selfHasCamera && nearbyOtherCamera) return false;
  return true;
}

/// Debounce fist/palm flicker so LAN `seesHand` does not broadcast every frame.
class HandSeenLatch {
  HandSeenLatch({this.onNeeded = 4, this.offNeeded = 4});

  final int onNeeded;
  final int offNeeded;
  var latched = false;
  var _on = 0;
  var _off = 0;

  /// True when [latched] flipped.
  bool ingest(bool sees) {
    if (sees) {
      _off = 0;
      if (latched) return false;
      _on++;
      if (_on < onNeeded) return false;
      latched = true;
      return true;
    }
    _on = 0;
    if (!latched) return false;
    _off++;
    if (_off < offNeeded) return false;
    latched = false;
    return true;
  }

  void reset() {
    latched = false;
    _on = 0;
    _off = 0;
  }
}

enum AirGrabFogKind { discover, lock }

/// Discovery is a small white hint while a nearby phone is holding.
/// Lock is the yellow pulse when *this* camera has chosen the person —
/// a closed fist in front of this screen.
AirGrabFogKind airGrabCatchFogKind({
  required bool aimedAtMe,
  required bool seesHand,
}) {
  if (seesHand) return AirGrabFogKind.lock;
  return AirGrabFogKind.discover;
}

/// Yellow while this camera sees a closed fist. Stay yellow through the
/// open-palm catch so the fog does not drop back to white mid-transfer.
bool airGrabCatchSeesChosen({
  required bool inFrame,
  required HandShape shape,
  required bool alreadyChosen,
}) {
  if (!inFrame) return false;
  if (shape == HandShape.fist) return true;
  return alreadyChosen && shape == HandShape.palm;
}

/// Catchers advertise an open palm as soon as they see one. Sitting in
/// front of the tablet, or a fist, is not a catch.
bool airGrabMayAdvertiseCatchHand({
  required bool aimedAtMe,
  required bool sawHandBeforeAim,
}) {
  return true;
}

/// Keep the last holding peer for a short grace after BLE/LAN blips.
///
/// Catch camera bind pauses discovery for a moment, and the sender also
/// pauses while its camera is up. Without a latch the FSM resets as soon
/// as `peerHolding` goes false, so an open palm never fires.
class CatchHolderLatch<T> {
  CatchHolderLatch({
    this.grace = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration grace;
  final DateTime Function() _clock;
  T? _held;
  DateTime? _until;

  T? remember(T? live) {
    if (live != null) {
      _held = live;
      _until = _clock().add(grace);
      return live;
    }
    final held = _held;
    final until = _until;
    if (held != null && until != null && _clock().isBefore(until)) {
      return held;
    }
    clear();
    return null;
  }

  void clear() {
    _held = null;
    _until = null;
  }
}

/// Keep the camera on so this screen can still be chosen as a target.
bool airGrabWantNearbyWatch({
  required bool enabled,
  required bool sending,
  required bool handingOff,
  required bool hasPeers,
}) {
  if (!enabled || sending || handingOff) return false;
  return hasPeers;
}
