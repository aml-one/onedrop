/// Camera-roll vs other-folder classification for the in-app photo picker.
///
/// Camera roll = pictures the user took (DCIM/Camera). Other = remaining albums,
/// with a dedicated Screenshots chip. Recents / All is never a Camera roll source.
///
/// Favorites matches AmL Gallery Loved: MediaStore IS_FAVORITE, Gallery's
/// local loved ids, and OEM favorite albums — not a camera-roll filter.
library;

enum PhotoPickerAlbumKind { camera, screenshot, favorite, other }

enum PhotoPickerChip {
  galleryAll,
  galleryPhotos,
  galleryVideos,
  galleryFavorites,
  otherAll,
  otherPhotos,
  otherVideos,
  otherScreenshots,
}

extension PhotoPickerChipX on PhotoPickerChip {
  bool get isGallery => index <= PhotoPickerChip.galleryFavorites.index;

  bool get photosOnly =>
      this == PhotoPickerChip.galleryPhotos || this == PhotoPickerChip.otherPhotos;

  bool get videosOnly =>
      this == PhotoPickerChip.galleryVideos || this == PhotoPickerChip.otherVideos;

  bool get favoritesOnly => this == PhotoPickerChip.galleryFavorites;

  String get label => switch (this) {
        PhotoPickerChip.galleryAll || PhotoPickerChip.otherAll => 'All',
        PhotoPickerChip.galleryPhotos ||
        PhotoPickerChip.otherPhotos =>
          'Photos',
        PhotoPickerChip.galleryVideos ||
        PhotoPickerChip.otherVideos =>
          'Videos',
        PhotoPickerChip.galleryFavorites => 'Favorites',
        PhotoPickerChip.otherScreenshots => 'Screenshots',
      };
}

/// Ids Gallery Loved uses: OS flag, local loved, local unloved.
class PhotoPickerFavoriteSets {
  const PhotoPickerFavoriteSets({
    this.mediaStore = const {},
    this.loved = const {},
    this.unloved = const {},
  });

  final Set<String> mediaStore;
  final Set<String> loved;
  final Set<String> unloved;
}

/// Same resolve order as Gallery [FavoriteStore.resolve], plus OEM favorite
/// albums that often skip the MediaStore flag (HyperOS Kedvencek).
bool keepPickerFavorite({
  required String id,
  required bool osFavorite,
  required bool fromFavoriteAlbum,
  required Set<String> loved,
  required Set<String> unloved,
  Set<String> mediaStore = const {},
}) {
  if (unloved.contains(id)) return false;
  if (loved.contains(id)) return true;
  if (osFavorite || mediaStore.contains(id)) return true;
  return fromFavoriteAlbum;
}

/// Names that are not enough to classify without a relative path.
bool albumNameNeedsRelativePath(String name) {
  final n = name.toLowerCase().trim();
  return n == 'dcim' || n == 'pictures' || n == 'picture' || n == 'img';
}

PhotoPickerAlbumKind classifyAlbum({
  required String name,
  String? relativePath,
  bool isAll = false,
}) {
  if (isAll) return PhotoPickerAlbumKind.other;
  final n = name.toLowerCase().trim();
  final p = (relativePath ?? '').toLowerCase().replaceAll('\\', '/');
  if (_isFavoriteName(n) || _isFavoritePath(p)) {
    return PhotoPickerAlbumKind.favorite;
  }
  if (_isScreenshot(n, p)) return PhotoPickerAlbumKind.screenshot;
  if (_isCamera(n, p)) return PhotoPickerAlbumKind.camera;
  return PhotoPickerAlbumKind.other;
}

bool includeAlbumForChip({
  required PhotoPickerChip chip,
  required PhotoPickerAlbumKind kind,
  bool isAll = false,
}) {
  if (isAll) return false;
  return switch (chip) {
    PhotoPickerChip.galleryAll ||
    PhotoPickerChip.galleryPhotos ||
    PhotoPickerChip.galleryVideos =>
      kind == PhotoPickerAlbumKind.camera,
    PhotoPickerChip.galleryFavorites => kind == PhotoPickerAlbumKind.favorite,
    PhotoPickerChip.otherAll ||
    PhotoPickerChip.otherPhotos ||
    PhotoPickerChip.otherVideos =>
      kind == PhotoPickerAlbumKind.other || kind == PhotoPickerAlbumKind.screenshot,
    PhotoPickerChip.otherScreenshots => kind == PhotoPickerAlbumKind.screenshot,
  };
}

/// Lower is loaded first when merging Other albums.
int otherAlbumLoadRank(PhotoPickerAlbumKind kind, String name) {
  if (kind == PhotoPickerAlbumKind.screenshot) return 0;
  final n = name.toLowerCase();
  if (n.contains('download')) return 1;
  if (n.contains('picture')) return 2;
  return 10;
}

DateTime photoRecency(DateTime create, DateTime modified) {
  if (create.year < 1990) return modified;
  if (modified.year < 1990) return create;
  return modified.isAfter(create) ? modified : create;
}

int comparePhotoRecency({
  required DateTime aCreate,
  required DateTime aModified,
  required DateTime bCreate,
  required DateTime bModified,
}) {
  return photoRecency(bCreate, bModified).compareTo(photoRecency(aCreate, aModified));
}

bool _isFavoriteName(String n) {
  if (n.contains('收藏') || n.contains('最爱') || n.contains('最愛')) {
    return true;
  }
  const tokens = [
    'favorite',
    'favourite',
    'kedvenc',
    'favorit',
    'favoris',
    'preferiti',
    'избранн',
    'ulubione',
    'oblíben',
    'suosikit',
    'loved',
    'starred',
    'liked',
  ];
  for (final token in tokens) {
    if (n.contains(token)) return true;
  }
  return false;
}

bool _isFavoritePath(String p) {
  if (p.isEmpty) return false;
  return p.contains('/favorite') ||
      p.contains('/favourite') ||
      p.contains('/kedvenc') ||
      p.contains('收藏');
}

bool _isScreenshot(String n, String p) {
  if (n.contains('screen record') ||
      n.contains('screenrecord') ||
      n.contains('screen-record') ||
      p.contains('screenrecord') ||
      p.contains('screen_record')) {
    return false;
  }
  return n.contains('screenshot') ||
      n.contains('screen shot') ||
      n.contains('screen-shot') ||
      n.contains('截屏') ||
      n.contains('截圖') ||
      n.contains('截图') ||
      p.contains('screenshot');
}

bool _isCamera(String n, String p) {
  if (_isChatOrDownload(n, p)) return false;
  if (p.contains('screenshot')) return false;
  const exact = {
    'camera',
    'dcim',
    'camera roll',
    '相机',
    '相機',
    '相机胶卷',
    '相機膠卷',
    '100media',
    '100andro',
  };
  if (exact.contains(n)) return true;
  if (p.contains('dcim/camera') ||
      p.contains('dcim/100') ||
      p.endsWith('/camera') ||
      p.endsWith('/camera/')) {
    return true;
  }
  return false;
}

bool _isChatOrDownload(String n, String p) {
  return n.contains('whatsapp') ||
      n.contains('telegram') ||
      n.contains('weixin') ||
      n.contains('wechat') ||
      n.contains('download') ||
      p.contains('whatsapp') ||
      p.contains('telegram') ||
      p.contains('download');
}
