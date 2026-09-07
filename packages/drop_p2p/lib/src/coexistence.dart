import 'kind.dart';

/// OneDrop owns UDP 4071 + BLE when it is installed so Gallery does not bind
/// the same listen socket.
bool oneDropOwnsListen({required bool oneDropInstalled}) => oneDropInstalled;

bool galleryShouldOwnListen({required bool oneDropInstalled}) =>
    !oneDropInstalled;

/// Gallery never accepts `kind: file` (PDF, zip, and the rest).
bool galleryShouldRejectOffer(Iterable<String?> kinds) =>
    kinds.any(dropKindIsFile);

({List<int> media, List<int> files}) splitOfferIndexes(List<String?> kinds) {
  final media = <int>[];
  final files = <int>[];
  for (var i = 0; i < kinds.length; i++) {
    if (dropKindIsFile(kinds[i])) {
      files.add(i);
    } else {
      media.add(i);
    }
  }
  return (media: media, files: files);
}
