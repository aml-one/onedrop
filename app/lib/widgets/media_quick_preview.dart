import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../core/labels.dart';
import '../core/media_size.dart';
import '../core/panel_window.dart';

/// Fits [aspectRatio] (width/height) inside max bounds like BoxFit.contain.
Size fitMediaContainSize(double maxW, double maxH, double aspectRatio) {
  if (aspectRatio <= 0 || maxW <= 0 || maxH <= 0) return Size(maxW, maxH);
  var w = maxW;
  var h = w / aspectRatio;
  if (h > maxH) {
    h = maxH;
    w = h * aspectRatio;
  }
  return Size(w, h);
}

/// Gallery-style quick look: grid when several files, then full preview/play.
class MediaQuickPreview extends StatefulWidget {
  const MediaQuickPreview({
    super.key,
    required this.paths,
    required this.onClose,
    this.title,
  });

  final List<String> paths;
  final VoidCallback onClose;
  final String? title;

  @override
  State<MediaQuickPreview> createState() => _MediaQuickPreviewState();
}

class _MediaQuickPreviewState extends State<MediaQuickPreview> {
  /// `null` = grid (multi only). Single-file starts in detail.
  int? _focus;

  @override
  void initState() {
    super.initState();
    if (widget.paths.length == 1) {
      _focus = 0;
    }
  }

  @override
  void didUpdateWidget(covariant MediaQuickPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paths != widget.paths) {
      _focus = widget.paths.length == 1 ? 0 : null;
    }
  }

  Future<void> _showGrid() async {
    setState(() => _focus = null);
    final screen = await PanelWindow.screenVisibleSize();
    await PanelWindow.resizeCenteredPreview(gridPreviewWindowSize(screen));
  }

  Future<void> _openItem(int index) async {
    setState(() => _focus = index);
    final screen = await PanelWindow.screenVisibleSize();
    final window = await previewWindowSizeForPath(widget.paths[index], screen);
    await PanelWindow.resizeCenteredPreview(window);
  }

  @override
  Widget build(BuildContext context) {
    final paths = widget.paths;
    if (paths.isEmpty) return const SizedBox.shrink();
    final multi = paths.length > 1;
    final focus = _focus;

    return Material(
      color: const Color(0xFF0C0A14),
      child: SafeArea(
        child: focus == null && multi
            ? _GridBody(
                paths: paths,
                title: widget.title ?? 'Received',
                onClose: widget.onClose,
                onOpen: (i) => unawaited(_openItem(i)),
              )
            : _DetailBody(
                paths: paths,
                index: focus ?? 0,
                title: widget.title,
                multi: multi,
                onClose: widget.onClose,
                onBackToGrid: multi ? () => unawaited(_showGrid()) : null,
                onSelect: (i) => unawaited(_openItem(i)),
              ),
      ),
    );
  }
}

class _GridBody extends StatelessWidget {
  const _GridBody({
    required this.paths,
    required this.title,
    required this.onClose,
    required this.onOpen,
  });

  final List<String> paths;
  final String title;
  final VoidCallback onClose;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Close',
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${paths.length} items — tap to preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemCount: paths.length,
            itemBuilder: (context, i) {
              final path = paths[i];
              final video = isVideoPath(path);
              return Material(
                color: const Color(0xFF1A1628),
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onOpen(i),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (video)
                        const ColoredBox(
                          color: Color(0xFF1A1628),
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white70,
                            size: 36,
                          ),
                        )
                      else
                        Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                          ),
                        ),
                      if (video)
                        const Positioned(
                          right: 6,
                          bottom: 6,
                          child: Icon(
                            Icons.videocam_rounded,
                            color: Colors.white70,
                            size: 16,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.paths,
    required this.index,
    required this.title,
    required this.multi,
    required this.onClose,
    required this.onSelect,
    this.onBackToGrid,
  });

  final List<String> paths;
  final int index;
  final String? title;
  final bool multi;
  final VoidCallback onClose;
  final ValueChanged<int> onSelect;
  final VoidCallback? onBackToGrid;

  @override
  Widget build(BuildContext context) {
    final path = paths[index.clamp(0, paths.length - 1)];
    final name = p.basename(path);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 0),
          child: Row(
            children: [
              if (onBackToGrid != null)
                IconButton(
                  tooltip: 'All items',
                  onPressed: onBackToGrid,
                  icon: const Icon(Icons.grid_view_rounded, color: Colors.white),
                )
              else
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title ?? 'Preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      multi ? '${index + 1} of ${paths.length} · $name' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (onBackToGrid != null)
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
            ],
          ),
        ),
        Expanded(
          child: isVideoPath(path)
              ? _QuickVideoPage(key: ValueKey('vid-$path'), path: path)
              : _QuickImagePage(key: ValueKey('img-$path'), path: path),
        ),
        if (multi)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SizedBox(
              height: 52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: paths.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final item = paths[i];
                  final selected = i == index;
                  return GestureDetector(
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? AmlTheme.sky : Colors.white24,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: isVideoPath(item)
                          ? ColoredBox(
                              color: const Color(0xFF1A1628),
                              child: Icon(
                                Icons.play_circle_fill_rounded,
                                color: selected ? AmlTheme.sky : Colors.white54,
                                size: 22,
                              ),
                            )
                          : Image.file(
                              File(item),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Color(0xFF1A1628),
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.white54,
                                  size: 18,
                                ),
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
          )
        else
          const SizedBox(height: 8),
      ],
    );
  }
}

class _QuickImagePage extends StatelessWidget {
  const _QuickImagePage({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 48,
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickVideoPage extends StatefulWidget {
  const _QuickVideoPage({super.key, required this.path});

  final String path;

  @override
  State<_QuickVideoPage> createState() => _QuickVideoPageState();
}

class _QuickVideoPageState extends State<_QuickVideoPage> {
  static const _hideDelay = Duration(milliseconds: 2500);

  VideoPlayerController? _controller;
  var _ready = false;
  var _failed = false;
  var _muted = true;
  var _controls = true;
  var _scrubbing = false;
  var _wasPlaying = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() {
      _failed = false;
      _ready = false;
    });
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(File(widget.path));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(false);
      await controller.setVolume(0);
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _ready = true;
      });
      await controller.play();
      _showControls(scheduleHide: true);
    } catch (_) {
      await controller?.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.duration > Duration.zero &&
        v.isPlaying &&
        v.position >= v.duration - const Duration(milliseconds: 250)) {
      c.pause();
      c.seekTo(Duration.zero);
      _showControls(scheduleHide: false);
    } else {
      setState(() {});
    }
  }

  void _showControls({required bool scheduleHide}) {
    _hide?.cancel();
    if (!_controls) setState(() => _controls = true);
    if (scheduleHide) {
      _hide = Timer(_hideDelay, () {
        if (!mounted || _scrubbing) return;
        final playing = _controller?.value.isPlaying ?? false;
        if (!playing) return;
        setState(() => _controls = false);
      });
    }
  }

  void _onTap() {
    if (_controls) {
      setState(() => _controls = false);
      _hide?.cancel();
      return;
    }
    _showControls(scheduleHide: _controller?.value.isPlaying ?? false);
  }

  Future<void> _playPause() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
      _showControls(scheduleHide: false);
    } else {
      await c.play();
      _showControls(scheduleHide: true);
    }
  }

  void _toggleMute() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() => _muted = !_muted);
    c.setVolume(_muted ? 0 : 1);
    _showControls(scheduleHide: c.value.isPlaying);
  }

  @override
  void dispose() {
    _hide?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Icon(Icons.videocam_off_rounded, color: Colors.white54, size: 48),
      );
    }
    final c = _controller;
    if (!_ready || c == null || !c.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white70,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = fitMediaContainSize(
          constraints.maxWidth - 20,
          constraints.maxHeight - 16,
          c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Center(
            child: SizedBox(
              width: fitted.width,
              height: fitted.height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ColoredBox(
                      color: Colors.black,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: c.value.size.width,
                          height: c.value.size.height,
                          child: VideoPlayer(c),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      ignoring: !_controls,
                      child: AnimatedOpacity(
                        opacity: _controls ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: _QuickScrubBar(
                          controller: c,
                          muted: _muted,
                          onToggleMute: _toggleMute,
                          onPlayPause: _playPause,
                          onScrubbingChanged: (active) {
                            _scrubbing = active;
                            if (active) {
                              _wasPlaying = c.value.isPlaying;
                              c.pause();
                              _showControls(scheduleHide: false);
                            } else {
                              if (_wasPlaying) unawaited(c.play());
                              _showControls(scheduleHide: _wasPlaying);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QuickScrubBar extends StatelessWidget {
  const _QuickScrubBar({
    required this.controller,
    required this.muted,
    required this.onToggleMute,
    required this.onPlayPause,
    required this.onScrubbingChanged,
  });

  final VideoPlayerController controller;
  final bool muted;
  final VoidCallback onToggleMute;
  final Future<void> Function() onPlayPause;
  final ValueChanged<bool> onScrubbingChanged;

  String _fmt(Duration d) {
    final t = d.isNegative ? Duration.zero : d;
    final m = t.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = t.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final durationMs = value.duration.inMilliseconds;
        if (durationMs <= 0) return const SizedBox.shrink();
        final positionMs = value.position.inMilliseconds.clamp(0, durationMs);
        final progress = positionMs / durationMs;

        return ClipRRect(
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.05),
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 18, 8, 10),
                child: Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => unawaited(onPlayPause()),
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggleMute,
                      icon: Icon(
                        muted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _fmt(Duration(milliseconds: positionMs)),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: progress.clamp(0.0, 1.0),
                          onChangeStart: (_) => onScrubbingChanged(true),
                          onChanged: (v) {
                            controller.seekTo(
                              Duration(
                                milliseconds: (durationMs * v).round(),
                              ),
                            );
                          },
                          onChangeEnd: (_) => onScrubbingChanged(false),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _fmt(value.duration),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
