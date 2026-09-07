import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/labels.dart';

/// White rounded pill with the duration punched out — same look as
/// MessageMe chat video thumbs.
class VideoDurationBadge extends StatelessWidget {
  const VideoDurationBadge({super.key, required this.seconds});

  final int seconds;

  static const _radius = 4.0;
  static const _hPad = 5.0;
  static const _vPad = 2.0;
  static const _style = TextStyle(
    fontSize: 10,
    height: 1.0,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w400,
    color: Colors.white,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const _strut = StrutStyle(
    fontSize: 10,
    height: 1.0,
    forceStrutHeight: true,
    leadingDistribution: TextLeadingDistribution.even,
  );
  static const _heightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  @override
  Widget build(BuildContext context) {
    if (seconds <= 0) return const SizedBox.shrink();
    final label = formatVideoDuration(seconds);
    return CustomPaint(
      painter: _VideoDurationBadgePainter(label: label),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: _vPad),
        child: Text(
          label,
          style: _style.copyWith(color: Colors.transparent),
          strutStyle: _strut,
          textHeightBehavior: _heightBehavior,
          maxLines: 1,
        ),
      ),
    );
  }
}

class _VideoDurationBadgePainter extends CustomPainter {
  _VideoDurationBadgePainter({required this.label});

  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      bounds,
      const Radius.circular(VideoDurationBadge._radius),
    );
    canvas.saveLayer(bounds, Paint());
    canvas.drawRRect(
      rrect,
      Paint()..color = Colors.white.withValues(alpha: 0.92),
    );
    final textPainter = TextPainter(
      text: TextSpan(text: label, style: VideoDurationBadge._style),
      textDirection: TextDirection.ltr,
      strutStyle: VideoDurationBadge._strut,
      textHeightBehavior: VideoDurationBadge._heightBehavior,
      maxLines: 1,
    )..layout();
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstOut);
    textPainter.paint(
      canvas,
      const Offset(VideoDurationBadge._hPad, VideoDurationBadge._vPad),
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VideoDurationBadgePainter oldDelegate) =>
      oldDelegate.label != label;
}
