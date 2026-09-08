import 'package:flutter/widgets.dart';

/// 720p-class phones (Oppo A72, Fire HD) cannot composite a full-screen
/// RadialGradient + five rings at 60fps without hitching ColorOS system UI.
bool cheapNearbyMotion(BuildContext context) {
  final mq = MediaQuery.maybeOf(context);
  if (mq == null) return false;
  if (mq.disableAnimations) return true;
  final physical = mq.size * mq.devicePixelRatio;
  final pixels = physical.width * physical.height;
  return pixels < 1600 * 1000 || mq.devicePixelRatio <= 2.05;
}
