import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:video_player/video_player.dart';

import 'labels.dart';

/// Natural pixel size of an image or video on disk.
Future<Size> probeMediaSize(String path) async {
  if (isVideoPath(path)) {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      final size = controller.value.size;
      if (size.width > 0 && size.height > 0) return size;
    } catch (_) {
      // Fall through to a landscape default.
    } finally {
      await controller.dispose();
    }
    return const Size(1280, 720);
  }

  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    return size;
  } catch (_) {
    return const Size(1080, 1080);
  }
}

/// Shrink [natural] so it fits inside [maxFraction] of [screen], never upscale.
Size fitWithinScreenFraction(
  Size natural,
  Size screen, {
  double maxFraction = 0.7,
}) {
  final maxW = screen.width * maxFraction;
  final maxH = screen.height * maxFraction;
  if (natural.width <= 0 || natural.height <= 0) {
    return Size(maxW.clamp(240, maxW), maxH.clamp(240, maxH));
  }
  if (natural.width <= maxW && natural.height <= maxH) {
    return natural;
  }
  final scale = (maxW / natural.width < maxH / natural.height)
      ? maxW / natural.width
      : maxH / natural.height;
  return Size(natural.width * scale, natural.height * scale);
}

/// Default centered grid window for picking among several received files.
Size gridPreviewWindowSize(Size screen, {double maxFraction = 0.7}) {
  final maxW = screen.width * maxFraction;
  final maxH = screen.height * maxFraction;
  return Size(
    maxW.clamp(360, 760).toDouble(),
    maxH.clamp(360, 640).toDouble(),
  );
}

/// Outer HWND size for a single media path: natural size, capped at 70% screen,
/// plus compact chrome for the title bar.
Future<Size> previewWindowSizeForPath(
  String path,
  Size screen, {
  double maxFraction = 0.7,
  double chromeWidth = 24,
  double chromeHeight = 72,
}) async {
  final natural = await probeMediaSize(path);
  final media = fitWithinScreenFraction(
    natural,
    screen,
    maxFraction: maxFraction,
  );
  return Size(
    (media.width + chromeWidth).clamp(320, screen.width * maxFraction + chromeWidth),
    (media.height + chromeHeight).clamp(240, screen.height * maxFraction + chromeHeight),
  );
}

