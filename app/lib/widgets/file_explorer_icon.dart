import 'dart:io';
import 'dart:typed_data';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../core/file_explorer_kind.dart';
import '../services/file_explorer_service.dart';

const kFileExplorerIconSize = 48.0;

class _KindStyle {
  const _KindStyle(this.icon, this.fill, this.accent);
  final IconData icon;
  final Color fill;
  final Color accent;
}

_KindStyle _styleFor(FileExplorerKind kind) {
  return switch (kind) {
    FileExplorerKind.folder => const _KindStyle(
      Icons.folder_rounded,
      Color(0xFFFFF3E0),
      AmlTheme.amber,
    ),
    FileExplorerKind.image => const _KindStyle(
      Icons.image_rounded,
      Color(0xFFE8F2FE),
      AmlTheme.sky,
    ),
    FileExplorerKind.video => const _KindStyle(
      Icons.movie_rounded,
      Color(0xFFFDEAF2),
      AmlTheme.pink,
    ),
    FileExplorerKind.apk => const _KindStyle(
      Icons.android_rounded,
      Color(0xFFF6E7A8),
      Color(0xFFD4A017),
    ),
    FileExplorerKind.pdf => const _KindStyle(
      Icons.picture_as_pdf_rounded,
      Color(0xFFFFE8E4),
      Color(0xFFE05A4F),
    ),
    FileExplorerKind.txt => const _KindStyle(
      Icons.description_rounded,
      Color(0xFFE8F2FE),
      AmlTheme.sky,
    ),
    FileExplorerKind.doc => const _KindStyle(
      Icons.article_rounded,
      Color(0xFFE3F0FF),
      Color(0xFF3B82C4),
    ),
    FileExplorerKind.xml => const _KindStyle(
      Icons.code_rounded,
      Color(0xFFE6F7F2),
      AmlTheme.mint,
    ),
    FileExplorerKind.xls => const _KindStyle(
      Icons.table_chart_rounded,
      Color(0xFFE7F6EA),
      Color(0xFF3D9A55),
    ),
    FileExplorerKind.audio => const _KindStyle(
      Icons.audiotrack_rounded,
      Color(0xFFEDE9FF),
      AmlTheme.violet,
    ),
    FileExplorerKind.file => const _KindStyle(
      Icons.insert_drive_file_rounded,
      Color(0xFFF3F0FA),
      Color(0xFF6B6390),
    ),
  };
}

/// Pastel 48px tile. Images and videos show a thumb when decode succeeds.
class FileExplorerIcon extends StatelessWidget {
  const FileExplorerIcon({
    super.key,
    required this.entry,
    this.kind,
  });

  final FileExplorerEntry entry;
  final FileExplorerKind? kind;

  @override
  Widget build(BuildContext context) {
    final resolved =
        kind ??
        fileExplorerKindFor(name: entry.name, isDirectory: entry.isDirectory);
    if (resolved == FileExplorerKind.image) {
      return _ImageThumb(path: entry.path, fallback: resolved);
    }
    if (resolved == FileExplorerKind.video) {
      return _VideoThumb(path: entry.path, fallback: resolved);
    }
    return FileExplorerKindIcon(kind: resolved);
  }
}

class FileExplorerKindIcon extends StatelessWidget {
  const FileExplorerKindIcon({super.key, required this.kind});

  final FileExplorerKind kind;

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(kind);
    return _Tile(
      fill: style.fill,
      accent: style.accent,
      child: Icon(style.icon, size: 24, color: style.accent),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.fill,
    required this.accent,
    required this.child,
  });

  final Color fill;
  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(Colors.white, fill, 0.55)!, fill],
        ),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: SizedBox(
        width: kFileExplorerIconSize,
        height: kFileExplorerIconSize,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: child,
        ),
      ),
    );
  }
}

class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.path, required this.fallback});

  final String path;
  final FileExplorerKind fallback;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = (kFileExplorerIconSize * dpr).round().clamp(48, 128);
    final style = _styleFor(fallback);
    return _Tile(
      fill: style.fill,
      accent: style.accent,
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        width: kFileExplorerIconSize,
        height: kFileExplorerIconSize,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) =>
            Icon(style.icon, size: 24, color: style.accent),
      ),
    );
  }
}

class _VideoThumb extends StatefulWidget {
  const _VideoThumb({required this.path, required this.fallback});

  final String path;
  final FileExplorerKind fallback;

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  static const _maxCache = 80;
  static final _cache = <String, Uint8List>{};

  Uint8List? _bytes;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _VideoThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
  }

  Future<void> _load() async {
    final cached = _cache[widget.path];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 96,
        quality: 50,
      );
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      if (!_cache.containsKey(widget.path) && _cache.length >= _maxCache) {
        _cache.remove(_cache.keys.first);
      }
      _cache[widget.path] = bytes;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(widget.fallback);
    final bytes = _bytes;
    return _Tile(
      fill: style.fill,
      accent: style.accent,
      child: bytes == null || _failed
          ? Icon(style.icon, size: 24, color: style.accent)
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              width: kFileExplorerIconSize,
              height: kFileExplorerIconSize,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
            ),
    );
  }
}
