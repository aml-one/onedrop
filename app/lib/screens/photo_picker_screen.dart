import 'dart:async';
import 'dart:typed_data';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/device_channel.dart';
import '../core/photo_picker_filter.dart';
import '../core/picker_thumb_loader.dart';
import '../widgets/video_duration_badge.dart';

/// In-app Recents picker. Does not launch the Gallery APK.
Future<List<String>?> pickPhotos(BuildContext context) {
  return Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const PhotoPickerScreen(),
    ),
  );
}

FilterOptionGroup _newestFirstFilter() {
  return FilterOptionGroup(
    containsPathModified: false,
    createTimeCond: DateTimeCond(
      min: DateTime.fromMillisecondsSinceEpoch(0),
      max: DateTime.now().add(const Duration(days: 365)),
      ignore: true,
    ),
    orders: const [
      OrderOption(type: OrderOptionType.createDate, asc: false),
    ],
  );
}

class PhotoPickerScreen extends StatefulWidget {
  const PhotoPickerScreen({super.key});

  @override
  State<PhotoPickerScreen> createState() => _PhotoPickerScreenState();
}

class _PhotoPickerScreenState extends State<PhotoPickerScreen> {
  static const _pageCap = 400;
  static const _perAlbum = 250;
  static const _maxAlbums = 12;

  final _selected = <String, String>{};
  List<AssetEntity> _assets = const [];
  PhotoPickerChip _chip = PhotoPickerChip.galleryAll;
  bool _loading = true;
  String? _error;
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  RequestType get _requestType {
    if (_chip.photosOnly) return RequestType.image;
    if (_chip.videosOnly) return RequestType.video;
    return RequestType.common;
  }

  Future<void> _selectChip(PhotoPickerChip chip) async {
    if (chip == _chip) return;
    setState(() => _chip = chip);
    await _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    final perm = await PhotoManager.requestPermissionExtend();
    if (gen != _loadGen || !mounted) return;
    if (!perm.isAuth && !perm.hasAccess) {
      setState(() {
        _loading = false;
        _error = 'Photo access is needed to send pictures and videos.';
      });
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: _requestType,
      onlyAll: false,
      filterOption: _newestFirstFilter(),
    );
    if (gen != _loadGen || !mounted) return;
    final merged = <String, AssetEntity>{};
    final albumIds = <String>{};
    PhotoPickerFavoriteSets favorites = const PhotoPickerFavoriteSets();
    if (_chip.favoritesOnly) {
      favorites = await DeviceChannel.listFavoriteSources();
      if (gen != _loadGen || !mounted) return;
    }
    final albums = await _albumsForChip(paths, _chip);
    if (gen != _loadGen || !mounted) return;
    final pageSize = _chip.favoritesOnly ? _pageCap : _perAlbum;
    for (final album in albums.take(_maxAlbums)) {
      final page = await album.getAssetListPaged(page: 0, size: pageSize);
      if (gen != _loadGen || !mounted) return;
      for (final asset in page) {
        merged[asset.id] = asset;
        if (_chip.favoritesOnly) albumIds.add(asset.id);
      }
      if (merged.length >= _pageCap * 2) break;
    }
    if (_chip.favoritesOnly) {
      await _mergeFavoriteIds(
        merged: merged,
        ids: {
          ...favorites.mediaStore,
          ...favorites.loved,
        },
      );
      if (gen != _loadGen || !mounted) return;
    }
    var list = merged.values.toList();
    if (_chip.favoritesOnly) {
      list = [
        for (final asset in list)
          if (keepPickerFavorite(
            id: asset.id,
            osFavorite: asset.isFavorite,
            fromFavoriteAlbum: albumIds.contains(asset.id),
            loved: favorites.loved,
            unloved: favorites.unloved,
            mediaStore: favorites.mediaStore,
          ))
            asset,
      ];
    }
    list.sort(
      (a, b) => comparePhotoRecency(
        aCreate: a.createDateTime,
        aModified: a.modifiedDateTime,
        bCreate: b.createDateTime,
        bModified: b.modifiedDateTime,
      ),
    );
    if (list.length > _pageCap) {
      list = list.sublist(0, _pageCap);
    }
    if (gen != _loadGen || !mounted) return;
    setState(() {
      _assets = list;
      _loading = false;
    });
  }

  Future<void> _mergeFavoriteIds({
    required Map<String, AssetEntity> merged,
    required Set<String> ids,
  }) async {
    final missing = [
      for (final id in ids)
        if (!merged.containsKey(id)) id,
    ];
    final room = _pageCap - merged.length;
    if (room <= 0) return;
    final take = missing.length > room ? missing.sublist(0, room) : missing;
    const chunk = 24;
    for (var i = 0; i < take.length; i += chunk) {
      final end = i + chunk > take.length ? take.length : i + chunk;
      final batch = await Future.wait([
        for (final id in take.sublist(i, end)) AssetEntity.fromId(id),
      ]);
      for (final asset in batch) {
        if (asset != null) merged[asset.id] = asset;
      }
    }
  }

  Future<List<AssetPathEntity>> _albumsForChip(
    List<AssetPathEntity> paths,
    PhotoPickerChip chip,
  ) async {
    final matched = <AssetPathEntity>[];
    final ranks = <String, int>{};
    for (final path in paths) {
      var kind = classifyAlbum(name: path.name, isAll: path.isAll);
      if (kind == PhotoPickerAlbumKind.other &&
          !path.isAll &&
          albumNameNeedsRelativePath(path.name)) {
        final rel = await path.relativePathAsync;
        kind = classifyAlbum(
          name: path.name,
          relativePath: rel,
          isAll: path.isAll,
        );
      }
      if (!includeAlbumForChip(chip: chip, kind: kind, isAll: path.isAll)) {
        continue;
      }
      matched.add(path);
      ranks[path.id] = otherAlbumLoadRank(kind, path.name);
    }
    matched.sort((a, b) => (ranks[a.id] ?? 10).compareTo(ranks[b.id] ?? 10));
    return matched;
  }

  Future<void> _toggle(AssetEntity asset) async {
    if (_selected.containsKey(asset.id)) {
      setState(() => _selected.remove(asset.id));
      return;
    }
    final file = await asset.originFile ?? await asset.file;
    if (file == null || !mounted) return;
    setState(() => _selected[asset.id] = file.path);
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    return Scaffold(
      backgroundColor: kSettingsPageBackground,
      appBar: AppBar(
        title: Text(_chip.label),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, _selected.values.toList()),
            child: Text(
              _selected.isEmpty ? 'Send' : 'Send (${_selected.length})',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: _FilterGroups(
              selected: _chip,
              onSelected: (chip) => unawaited(_selectChip(chip)),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: BirdLoader(size: 72))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, style: TextStyle(color: ink)),
                        ),
                      )
                    : _assets.isEmpty
                        ? Center(
                            child: Text(
                              'Nothing here yet',
                              style: TextStyle(color: AmlTheme.mutedOf(context)),
                            ),
                          )
                        : GridView.builder(
                            cacheExtent: 120,
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 4,
                              crossAxisSpacing: 4,
                            ),
                            itemCount: _assets.length,
                            itemBuilder: (context, index) {
                              final asset = _assets[index];
                              return RepaintBoundary(
                                child: _Thumb(
                                  key: ValueKey(asset.id),
                                  asset: asset,
                                  selected: _selected.containsKey(asset.id),
                                  onTap: () => unawaited(_toggle(asset)),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

class _FilterChipSpec {
  const _FilterChipSpec({
    required this.value,
    required this.accent,
  });

  final PhotoPickerChip value;
  final Color accent;
}

class _FilterGroups extends StatelessWidget {
  const _FilterGroups({
    required this.selected,
    required this.onSelected,
  });

  final PhotoPickerChip selected;
  final ValueChanged<PhotoPickerChip> onSelected;

  static const _gallery = [
    _FilterChipSpec(
      value: PhotoPickerChip.galleryAll,
      accent: AmlTheme.violet,
    ),
    _FilterChipSpec(
      value: PhotoPickerChip.galleryPhotos,
      accent: AmlTheme.sky,
    ),
    _FilterChipSpec(
      value: PhotoPickerChip.galleryVideos,
      accent: AmlTheme.mint,
    ),
    _FilterChipSpec(
      value: PhotoPickerChip.galleryFavorites,
      accent: AmlTheme.pink,
    ),
  ];

  static const _other = [
    _FilterChipSpec(
      value: PhotoPickerChip.otherAll,
      accent: AmlTheme.violet,
    ),
    _FilterChipSpec(
      value: PhotoPickerChip.otherPhotos,
      accent: AmlTheme.sky,
    ),
    _FilterChipSpec(
      value: PhotoPickerChip.otherVideos,
      accent: AmlTheme.mint,
    ),
    _FilterChipSpec(
      value: PhotoPickerChip.otherScreenshots,
      accent: AmlTheme.amber,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChipRow(
          label: 'Camera roll',
          selected: selected,
          onSelected: onSelected,
          chips: _gallery,
        ),
        const SizedBox(height: 10),
        _ChipRow(
          label: 'Other',
          selected: selected,
          onSelected: onSelected,
          chips: _other,
        ),
      ],
    );
  }
}

/// Pastel pills like App Builder chat usage chips. The row sizes to the
/// labels, then FittedBox scales the whole set down on a tight Oppo width.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.label,
    required this.chips,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final List<_FilterChipSpec> chips;
  final PhotoPickerChip selected;
  final ValueChanged<PhotoPickerChip> onSelected;

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: TextStyle(
              color: muted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              fontFamily: AmlTheme.platformUiFontFamily(),
              fontFamilyFallback: AmlTheme.uiFontFamilyFallback,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < chips.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _PastelFilterChip(
                    spec: chips[i],
                    selected: chips[i].value == selected,
                    onTap: () => onSelected(chips[i].value),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PastelFilterChip extends StatelessWidget {
  const _PastelFilterChip({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _FilterChipSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final fill = selected ? 0.28 : 0.16;
    final stroke = selected ? 0.52 : 0.34;
    return Material(
      color: Color.alphaBlend(
        spec.accent.withValues(alpha: fill),
        surface,
      ),
      shape: StadiumBorder(
        side: BorderSide(
          color: spec.accent.withValues(alpha: stroke),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Text(
            spec.value.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            ),
            style: TextStyle(
              color: spec.accent,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              height: 1.15,
              fontFamily: AmlTheme.platformUiFontFamily(),
              fontFamilyFallback: AmlTheme.uiFontFamilyFallback,
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({
    super.key,
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  PickerThumbTicket? _ticket;
  Uint8List? _bytes;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(covariant _Thumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _ticket?.cancel();
      _bytes = null;
      _request();
    }
  }

  @override
  void dispose() {
    _ticket?.cancel();
    super.dispose();
  }

  void _request() {
    _ticket?.cancel();
    _ticket = null;
    final cached = PickerThumbLoader.instance.peek(widget.asset.id);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    final gen = ++_gen;
    final ticket = PickerThumbLoader.instance.load(
      id: widget.asset.id,
      decode: () => widget.asset.thumbnailDataWithSize(
        const ThumbnailSize.square(256),
      ),
    );
    _ticket = ticket;
    unawaited(ticket.future.then((bytes) {
      if (!mounted || gen != _gen || bytes == null) return;
      setState(() => _bytes = bytes);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Material(
      color: const Color(0xFFEDE9FF),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (bytes != null)
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 256,
              )
            else
              const ColoredBox(color: Color(0xFFEDE9FF)),
            if (widget.asset.type == AssetType.video &&
                widget.asset.duration > 0)
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: VideoDurationBadge(seconds: widget.asset.duration),
                ),
              ),
            if (widget.selected)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFF7C6FF0),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
