import 'package:flutter/material.dart';

/// Catch fog. Discovery is a small cool-white hint. Lock is a yellow
/// pulse when this camera sees a closed fist (the chosen target).
class AirGrabTargetGlow extends StatefulWidget {
  const AirGrabTargetGlow({super.key, this.locked = false});

  final bool locked;

  @override
  State<AirGrabTargetGlow> createState() => _AirGrabTargetGlowState();
}

class _AirGrabTargetGlowState extends State<AirGrabTargetGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.locked ? 1200 : 1800),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AirGrabTargetGlow old) {
    super.didUpdateWidget(old);
    if (old.locked == widget.locked) return;
    _pulse.duration = Duration(milliseconds: widget.locked ? 1200 : 1800);
    if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          return CustomPaint(
            painter: AirGrabTargetGlowPainter(
              breath: Curves.easeInOut.transform(_pulse.value),
              locked: widget.locked,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class AirGrabTargetGlowPainter extends CustomPainter {
  const AirGrabTargetGlowPainter({
    required this.breath,
    required this.locked,
  });

  final double breath;
  final bool locked;

  static const _white = Color(0xFFF4F7FF);
  static const _yellow = Color(0xFFFFE14A);
  static const _green = Color(0xFF5CCBB4);
  static const _blue = Color(0xFF6FB1F0);

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height / 2);
    final span = size.shortestSide;
    if (locked) {
      final radius = span * (0.30 + breath * 0.08);
      final inner = 0.62 + breath * 0.14;
      final mid = 0.26 + breath * 0.10;
      _blob(canvas, origin + Offset(-0.04, -0.03) * radius, radius, _yellow, inner, mid);
      _blob(canvas, origin + Offset(0.10, 0.06) * radius, radius * 0.72, _green, inner * 0.55, mid * 0.55);
      _blob(canvas, origin + Offset(-0.08, 0.08) * radius, radius * 0.68, _blue, inner * 0.48, mid * 0.48);
      return;
    }
    final radius = span * (0.18 + breath * 0.03);
    final inner = 0.52 + breath * 0.08;
    final mid = 0.18 + breath * 0.05;
    _blob(canvas, origin, radius, _white, inner, mid);
  }

  void _blob(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
    double inner,
    double mid,
  ) {
    final paint = Paint()
      ..blendMode = BlendMode.srcOver
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: inner.clamp(0.0, 1.0)),
          color.withValues(alpha: mid.clamp(0.0, 1.0)),
          color.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.40, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(AirGrabTargetGlowPainter old) =>
      old.breath != breath || old.locked != locked;
}
