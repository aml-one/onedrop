import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/photo_picker_filter.dart';

void main() {
  test('Camera roll is Gallery, Recents is not', () {
    expect(
      classifyAlbum(name: 'Camera'),
      PhotoPickerAlbumKind.camera,
    );
    expect(
      classifyAlbum(name: 'DCIM', relativePath: 'DCIM/Camera'),
      PhotoPickerAlbumKind.camera,
    );
    expect(
      classifyAlbum(name: 'Recent', isAll: true),
      PhotoPickerAlbumKind.other,
    );
    expect(
      classifyAlbum(name: 'WhatsApp Images'),
      PhotoPickerAlbumKind.other,
    );
  });

  test('Screenshots and chat folders are Other, not Gallery', () {
    expect(
      classifyAlbum(name: 'Screenshots'),
      PhotoPickerAlbumKind.screenshot,
    );
    expect(
      classifyAlbum(name: 'Pictures', relativePath: 'Pictures/Screenshots'),
      PhotoPickerAlbumKind.screenshot,
    );
    expect(
      classifyAlbum(name: 'Download'),
      PhotoPickerAlbumKind.other,
    );
    expect(
      classifyAlbum(name: 'Screen Recorder'),
      isNot(PhotoPickerAlbumKind.screenshot),
    );
  });

  test('Favorites album names classify as favorite', () {
    expect(classifyAlbum(name: 'Favorites'), PhotoPickerAlbumKind.favorite);
    expect(classifyAlbum(name: 'Kedvencek'), PhotoPickerAlbumKind.favorite);
    expect(classifyAlbum(name: 'Favourites'), PhotoPickerAlbumKind.favorite);
    expect(classifyAlbum(name: '收藏'), PhotoPickerAlbumKind.favorite);
  });

  test('Favorites chip is not the camera roll', () {
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.galleryFavorites,
        kind: PhotoPickerAlbumKind.favorite,
      ),
      isTrue,
    );
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.galleryFavorites,
        kind: PhotoPickerAlbumKind.camera,
      ),
      isFalse,
    );
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.galleryAll,
        kind: PhotoPickerAlbumKind.favorite,
      ),
      isFalse,
    );
  });

  test('Favorites keep Gallery Loved plus the phone flag', () {
    expect(
      keepPickerFavorite(
        id: 'a',
        osFavorite: false,
        fromFavoriteAlbum: false,
        loved: {'a'},
        unloved: {},
      ),
      isTrue,
    );
    expect(
      keepPickerFavorite(
        id: 'a',
        osFavorite: true,
        fromFavoriteAlbum: false,
        loved: {},
        unloved: {'a'},
      ),
      isFalse,
    );
    expect(
      keepPickerFavorite(
        id: 'a',
        osFavorite: false,
        fromFavoriteAlbum: false,
        loved: {},
        unloved: {},
        mediaStore: {'a'},
      ),
      isTrue,
    );
    expect(
      keepPickerFavorite(
        id: 'a',
        osFavorite: false,
        fromFavoriteAlbum: true,
        loved: {},
        unloved: {},
      ),
      isTrue,
    );
    expect(
      keepPickerFavorite(
        id: 'a',
        osFavorite: false,
        fromFavoriteAlbum: false,
        loved: {},
        unloved: {},
      ),
      isFalse,
    );
  });

  test('Chip rows pick camera vs other vs screenshots', () {
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.galleryAll,
        kind: PhotoPickerAlbumKind.camera,
      ),
      isTrue,
    );
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.galleryAll,
        kind: PhotoPickerAlbumKind.screenshot,
      ),
      isFalse,
    );
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.otherAll,
        kind: PhotoPickerAlbumKind.screenshot,
      ),
      isTrue,
    );
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.otherScreenshots,
        kind: PhotoPickerAlbumKind.other,
      ),
      isFalse,
    );
    expect(
      includeAlbumForChip(
        chip: PhotoPickerChip.galleryAll,
        kind: PhotoPickerAlbumKind.camera,
        isAll: true,
      ),
      isFalse,
    );
  });

  test('Newest photos sort first', () {
    final old = DateTime(2024, 1, 1);
    final mid = DateTime(2026, 8, 1);
    final newest = DateTime(2026, 9, 7);
    final ids = ['old', 'new', 'mid'];
    final creates = [old, newest, mid];
    final modified = [old, mid, mid];
    final order = List<int>.generate(3, (i) => i)
      ..sort(
        (a, b) => comparePhotoRecency(
          aCreate: creates[a],
          aModified: modified[a],
          bCreate: creates[b],
          bModified: modified[b],
        ),
      );
    expect(ids[order[0]], 'new');
    expect(ids[order[1]], 'mid');
    expect(ids[order[2]], 'old');
  });

  test('Broken create dates fall back to modified time', () {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final taken = DateTime(2026, 9, 7);
    expect(photoRecency(epoch, taken), taken);
  });

  test('Chip labels match the picker title', () {
    expect(PhotoPickerChip.galleryAll.label, 'All');
    expect(PhotoPickerChip.galleryPhotos.label, 'Photos');
    expect(PhotoPickerChip.galleryVideos.label, 'Videos');
    expect(PhotoPickerChip.galleryFavorites.label, 'Favorites');
    expect(PhotoPickerChip.otherScreenshots.label, 'Screenshots');
    expect(PhotoPickerChip.otherAll.label, PhotoPickerChip.galleryAll.label);
  });
}
