import 'package:drop_p2p/drop_p2p.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing kind still means image', () {
    expect(normalizeDropKind(null), dropKindImage);
    expect(normalizeDropKind(''), dropKindImage);
    expect(normalizeDropKind('IMAGE'), dropKindImage);
    expect(dropKindIsMedia(null), isTrue);
    expect(dropKindIsFile(null), isFalse);
  });

  test('file kind is distinct from media', () {
    expect(normalizeDropKind('file'), dropKindFile);
    expect(dropKindIsFile('file'), isTrue);
    expect(dropKindIsMedia('file'), isFalse);
    expect(dropKindIsMedia('video'), isTrue);
  });

  test('Gallery rejects any offer that includes a file', () {
    expect(galleryShouldRejectOffer(['image', 'video']), isFalse);
    expect(galleryShouldRejectOffer(['image', 'file']), isTrue);
    expect(galleryShouldRejectOffer(['file']), isTrue);
  });

  test('OneDrop owns listen when it is installed', () {
    expect(oneDropOwnsListen(oneDropInstalled: true), isTrue);
    expect(galleryShouldOwnListen(oneDropInstalled: true), isFalse);
    expect(galleryShouldOwnListen(oneDropInstalled: false), isTrue);
  });

  test('mixed offer splits media vs files', () {
    final split = splitOfferIndexes(['image', 'file', 'video']);
    expect(split.media, [0, 2]);
    expect(split.files, [1]);
  });

  test('per-file cap is about 7 GB', () {
    expect(dropMaxFileBytes, 7 * 1024 * 1024 * 1024);
    expect(dropTooLargeMessage(), contains('7 GB'));
    expect(dropMaxFileBytes > 512 * 1024 * 1024, isTrue);
  });
}
