import 'package:air_gesture/air_gesture.dart';
import 'package:test/test.dart';

HandLandmarks _openPalm() {
  // Wrist at bottom-center; tips farther from wrist than PIPS.
  final pts = <({double x, double y})>[
    (x: 0.5, y: 0.75), // 0 wrist
    (x: 0.42, y: 0.68),
    (x: 0.38, y: 0.58),
    (x: 0.34, y: 0.48),
    (x: 0.30, y: 0.36), // 4 thumb tip
    (x: 0.46, y: 0.62), // 5 index mcp
    (x: 0.45, y: 0.48),
    (x: 0.44, y: 0.34),
    (x: 0.43, y: 0.18), // 8 index tip
    (x: 0.50, y: 0.62),
    (x: 0.50, y: 0.46),
    (x: 0.50, y: 0.30),
    (x: 0.50, y: 0.14),
    (x: 0.54, y: 0.62),
    (x: 0.55, y: 0.48),
    (x: 0.56, y: 0.34),
    (x: 0.57, y: 0.20),
    (x: 0.58, y: 0.64),
    (x: 0.60, y: 0.52),
    (x: 0.62, y: 0.40),
    (x: 0.64, y: 0.28),
  ];
  return HandLandmarks(pts);
}

HandLandmarks _fist() {
  final pts = <({double x, double y})>[
    (x: 0.5, y: 0.62),
    (x: 0.46, y: 0.58),
    (x: 0.44, y: 0.54),
    (x: 0.43, y: 0.52),
    (x: 0.48, y: 0.50),
    (x: 0.47, y: 0.54),
    (x: 0.47, y: 0.52),
    (x: 0.47, y: 0.51),
    (x: 0.48, y: 0.50),
    (x: 0.50, y: 0.54),
    (x: 0.50, y: 0.52),
    (x: 0.50, y: 0.51),
    (x: 0.50, y: 0.50),
    (x: 0.53, y: 0.54),
    (x: 0.53, y: 0.52),
    (x: 0.53, y: 0.51),
    (x: 0.53, y: 0.50),
    (x: 0.56, y: 0.55),
    (x: 0.56, y: 0.53),
    (x: 0.56, y: 0.52),
    (x: 0.56, y: 0.51),
  ];
  return HandLandmarks(pts);
}

void main() {
  test('open fingers read as a palm', () {
    expect(classifyHand(_openPalm()), HandShape.palm);
  });

  test('curled fingers read as a fist', () {
    expect(classifyHand(_fist()), HandShape.fist);
  });

  test('incomplete landmarks are none', () {
    expect(classifyHand(HandLandmarks(const [])), HandShape.none);
  });

  test('three open fingers still count as a palm when the thumb is tucked', () {
    final pts = List<({double x, double y})>.from(_openPalm().points);
    pts[4] = pts[8];
    expect(classifyHand(HandLandmarks(pts)), HandShape.palm);
  });
}
