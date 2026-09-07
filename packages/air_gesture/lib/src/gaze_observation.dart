/// Head pose toward *this* device's camera. Native adapters fill this.
class GazeObservation {
  const GazeObservation({
    this.known = false,
    this.face = false,
    this.looking = false,
    this.attention = 0,
    this.yaw = 0,
    this.pitch = 0,
  });

  /// True when this frame ran a face / head-pose estimator.
  final bool known;

  /// A face is in view of this camera.
  final bool face;

  /// Face is aimed at this screen (small yaw/pitch).
  final bool looking;

  /// 0–1 how strongly this camera thinks the user is facing it.
  final double attention;

  /// Radians, 0 = at the camera. Positive is typically right.
  final double yaw;

  /// Radians, 0 = at the camera. Positive is typically up.
  final double pitch;

  static const unknown = GazeObservation();

  static const none = GazeObservation(known: true);

  bool get turnedAway => known && face && !looking;

  /// Palm → fist may start only while the face is aimed at this screen.
  /// Unknown gaze (no face pass) does not count as looking.
  bool get mayArmGrab => looking;
}

GazeObservation gazeFromNative(Map<Object?, Object?> map) {
  if (map['gaze'] != true) return GazeObservation.unknown;
  final face = map['face'] == true;
  final attention = (map['attention'] as num?)?.toDouble() ?? 0;
  final yaw = (map['yaw'] as num?)?.toDouble() ?? 0;
  final pitch = (map['pitch'] as num?)?.toDouble() ?? 0;
  final looking = map['looking'] == true ||
      (face && attention >= kLookingAttention);
  return GazeObservation(
    known: true,
    face: face,
    looking: looking,
    attention: attention.clamp(0, 1),
    yaw: yaw,
    pitch: pitch,
  );
}

/// Attention at or above this means "facing this screen".
const kLookingAttention = 0.38;

/// Winner must beat the runner-up by this to auto-send.
const kAttentionLead = 0.12;
