import 'dart:math' as math;

/// MediaPipe-style 21-point hand. Coordinates are normalized 0–1 in the frame.
class HandLandmarks {
  const HandLandmarks(this.points);

  /// wrist, thumb×4, index×4, middle×4, ring×4, pinky×4
  final List<({double x, double y})> points;

  bool get isComplete => points.length == 21;

  ({double x, double y}) get wrist => points[0];

  ({double x, double y}) get indexTip => points[8];
  ({double x, double y}) get indexPip => points[6];
  ({double x, double y}) get indexMcp => points[5];

  ({double x, double y}) get middleTip => points[12];
  ({double x, double y}) get middlePip => points[10];
  ({double x, double y}) get middleMcp => points[9];

  ({double x, double y}) get ringTip => points[16];
  ({double x, double y}) get ringPip => points[14];
  ({double x, double y}) get ringMcp => points[13];

  ({double x, double y}) get pinkyTip => points[20];
  ({double x, double y}) get pinkyPip => points[18];
  ({double x, double y}) get pinkyMcp => points[17];

  ({double x, double y}) get thumbTip => points[4];
  ({double x, double y}) get thumbIp => points[3];
  ({double x, double y}) get thumbMcp => points[2];

  double get palmWidth {
    if (!isComplete) return 0;
    return landmarkDistance(indexMcp, pinkyMcp);
  }
}

double landmarkDistance(
  ({double x, double y}) a,
  ({double x, double y}) b,
) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}
