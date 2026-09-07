import 'gaze_observation.dart';
import 'hand_landmarks.dart';

enum HandShape { none, palm, fist }

class HandObservation {
  const HandObservation({
    required this.shape,
    required this.inFrame,
    this.score = 0,
    this.gaze = GazeObservation.unknown,
  });

  final HandShape shape;
  final bool inFrame;
  final double score;
  final GazeObservation gaze;

  static const empty = HandObservation(
    shape: HandShape.none,
    inFrame: false,
  );
}

HandShape parseHandShape(String? raw) {
  switch (raw) {
    case 'palm':
      return HandShape.palm;
    case 'fist':
      return HandShape.fist;
    default:
      return HandShape.none;
  }
}

/// Native adapters may send a label instead of 21 points.
HandObservation observationFromNative({
  required String shape,
  required bool inFrame,
  double score = 1,
  GazeObservation gaze = GazeObservation.unknown,
}) {
  if (!inFrame) {
    return HandObservation(
      shape: HandShape.none,
      inFrame: false,
      gaze: gaze,
    );
  }
  final parsed = parseHandShape(shape);
  if (parsed == HandShape.none) {
    return HandObservation(
      shape: HandShape.none,
      inFrame: true,
      gaze: gaze,
    );
  }
  return HandObservation(
    shape: parsed,
    inFrame: true,
    score: score,
    gaze: gaze,
  );
}

/// EventChannel map from Android / Windows.
HandObservation observationFromFrameMap(Map<Object?, Object?> map) {
  final gaze = gazeFromNative(map);
  final points = map['points'];
  if (points is List && points.length == 21) {
    final parsed = <({double x, double y})>[];
    for (final row in points) {
      if (row is! List || row.length < 2) {
        return HandObservation(
          shape: HandShape.none,
          inFrame: false,
          gaze: gaze,
        );
      }
      parsed.add((
        x: (row[0] as num).toDouble(),
        y: (row[1] as num).toDouble(),
      ));
    }
    return observationFromLandmarks(HandLandmarks(parsed), gaze: gaze);
  }
  return observationFromNative(
    shape: map['shape'] as String? ?? 'none',
    inFrame: map['inFrame'] == true,
    gaze: gaze,
  );
}

/// Classify an open palm vs a closed fist from 21 landmarks.
HandShape classifyHand(HandLandmarks hand) {
  if (!hand.isComplete) return HandShape.none;
  final palm = hand.palmWidth;
  if (palm < 0.02) return HandShape.none;

  var extended = 0;
  var curled = 0;
  void tally(
    ({double x, double y}) mcp,
    ({double x, double y}) pip,
    ({double x, double y}) tip,
  ) {
    if (_fingerCurled(mcp, tip, palm)) {
      curled++;
    } else if (_fingerOpen(hand.wrist, mcp, pip, tip)) {
      extended++;
    }
  }

  tally(hand.indexMcp, hand.indexPip, hand.indexTip);
  tally(hand.middleMcp, hand.middlePip, hand.middleTip);
  tally(hand.ringMcp, hand.ringPip, hand.ringTip);
  tally(hand.pinkyMcp, hand.pinkyPip, hand.pinkyTip);

  final pinch = landmarkDistance(hand.thumbTip, hand.indexTip);
  final pinchNorm = palm <= 0 ? 1.0 : pinch / palm;

  if (extended >= 3) return HandShape.palm;
  if (extended >= 2 && pinchNorm > 0.30) return HandShape.palm;
  final openness = _fingerOpenness(hand);
  if (openness >= 1.22 && extended >= 2) return HandShape.palm;
  if (curled >= 3 || (extended <= 1 && curled >= 2)) return HandShape.fist;
  if (openness <= 1.05 && curled >= 2) return HandShape.fist;
  if (extended <= 1 && pinchNorm < 0.55) return HandShape.fist;
  return HandShape.none;
}

double _fingerOpenness(HandLandmarks hand) {
  double ratio(
    ({double x, double y}) mcp,
    ({double x, double y}) tip,
  ) {
    final toMcp = landmarkDistance(hand.wrist, mcp);
    if (toMcp <= 0) return 1;
    return landmarkDistance(hand.wrist, tip) / toMcp;
  }

  return (ratio(hand.indexMcp, hand.indexTip) +
          ratio(hand.middleMcp, hand.middleTip) +
          ratio(hand.ringMcp, hand.ringTip) +
          ratio(hand.pinkyMcp, hand.pinkyTip)) /
      4;
}

bool _fingerOpen(
  ({double x, double y}) wrist,
  ({double x, double y}) mcp,
  ({double x, double y}) pip,
  ({double x, double y}) tip,
) {
  final toTip = landmarkDistance(wrist, tip);
  final toPip = landmarkDistance(wrist, pip);
  final toMcp = landmarkDistance(wrist, mcp);
  if (toMcp <= 0) return false;
  return toTip > toPip * 1.08 && toTip > toMcp * 1.15;
}

bool _fingerCurled(
  ({double x, double y}) mcp,
  ({double x, double y}) tip,
  double palm,
) {
  if (palm <= 0) return false;
  return landmarkDistance(mcp, tip) < palm * 0.85;
}

HandObservation observationFromLandmarks(
  HandLandmarks? hand, {
  GazeObservation gaze = GazeObservation.unknown,
}) {
  if (hand == null || !hand.isComplete) {
    return HandObservation(
      shape: HandShape.none,
      inFrame: false,
      gaze: gaze,
    );
  }
  final shape = classifyHand(hand);
  if (shape == HandShape.none) {
    return HandObservation(
      shape: HandShape.none,
      inFrame: true,
      gaze: gaze,
    );
  }
  return HandObservation(
    shape: shape,
    inFrame: true,
    score: 1,
    gaze: gaze,
  );
}
