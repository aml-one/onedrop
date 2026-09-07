/// Offer item kinds on the One Drop v1 HTTP payload.
/// Missing kind still means image so older peers keep working.
const dropKindImage = 'image';
const dropKindVideo = 'video';
const dropKindFile = 'file';

String normalizeDropKind(String? kind) {
  final k = (kind ?? '').trim().toLowerCase();
  if (k == dropKindVideo) return dropKindVideo;
  if (k == dropKindFile) return dropKindFile;
  return dropKindImage;
}

bool dropKindIsMedia(String? kind) {
  final k = normalizeDropKind(kind);
  return k == dropKindImage || k == dropKindVideo;
}

bool dropKindIsFile(String? kind) => normalizeDropKind(kind) == dropKindFile;
