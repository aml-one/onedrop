import 'package:air_gesture/air_gesture.dart';
import 'package:drop_p2p/drop_p2p.dart';

import '../services/drop_service.dart';

String dropPayloadLabel({
  required int photos,
  required int videos,
  int files = 0,
}) {
  final bits = <String>[];
  if (photos > 0) bits.add(photos == 1 ? '1 photo' : '$photos photos');
  if (videos > 0) bits.add(videos == 1 ? '1 video' : '$videos videos');
  if (files > 0) bits.add(files == 1 ? '1 file' : '$files files');
  if (bits.isEmpty) return '0 items';
  return bits.join(' · ');
}

/// Same m:ss label MessageMe uses on chat video thumbs.
String formatVideoDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String dropBytesLabel(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)} MB';
}

String dropOutgoingPayload(Iterable<DropOutgoing> files) {
  final photos =
      files.where((file) => normalizeDropKind(file.kind) == dropKindImage).length;
  final videos =
      files.where((file) => normalizeDropKind(file.kind) == dropKindVideo).length;
  final other = files.where((file) => dropKindIsFile(file.kind)).length;
  return dropPayloadLabel(photos: photos, videos: videos, files: other);
}

String dropOfferSummary(DropOffer offer) {
  final photos = offer.files.where((file) => normalizeDropKind(file.kind) == dropKindImage).length;
  final videos = offer.files.where((file) => normalizeDropKind(file.kind) == dropKindVideo).length;
  final files = offer.files.where((file) => dropKindIsFile(file.kind)).length;
  final size = offer.files.fold<int>(0, (sum, file) => sum + file.size);
  final payload = dropPayloadLabel(photos: photos, videos: videos, files: files);
  final bytes = dropBytesLabel(size);
  return bytes.isEmpty ? payload : '$payload · $bytes';
}

String dropInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.substring(0, 1).toUpperCase();
}

/// Short type for the nearby avatar: Phone, PC, Mac, Linux.
String dropDeviceTypeLabel(DropPeer peer) {
  switch (peer.os) {
    case AirPeerOs.android:
      return 'Phone';
    case AirPeerOs.macos:
      return 'Mac';
    case AirPeerOs.linux:
      return peer.role == AirPeerRole.phone ? 'Phone' : 'Linux';
    case AirPeerOs.windows:
      return 'PC';
    case AirPeerOs.other:
      return peer.role == AirPeerRole.phone ? 'Phone' : 'PC';
  }
}

bool isVideoPath(String path) {
  const video = {
    '.mp4',
    '.mov',
    '.mkv',
    '.webm',
    '.avi',
    '.m4v',
    '.3gp',
    '.mpeg',
    '.mpg',
  };
  return _ext(path, video);
}

bool isImagePath(String path) {
  const image = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.heic',
    '.heif',
    '.bmp',
    '.tif',
    '.tiff',
    '.dng',
  };
  return _ext(path, image);
}

String kindForPath(String path) {
  if (isVideoPath(path)) return dropKindVideo;
  if (isImagePath(path)) return dropKindImage;
  return dropKindFile;
}

bool _ext(String path, Set<String> exts) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return exts.contains(path.substring(dot).toLowerCase());
}

class DropSendErrorCopy {
  const DropSendErrorCopy({required this.message, this.detail});

  final String message;
  final String? detail;
}

/// Maps Dart/HTTP exceptions into a short reason, keeping the raw string
/// as optional debug detail.
DropSendErrorCopy dropSendErrorCopy(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const DropSendErrorCopy(message: 'The transfer failed.');
  }
  final plain = trimmed
      .replaceFirst(RegExp(r'^Bad state:\s*'), '')
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .trim();
  final hay = plain.toLowerCase();
  final technical = _dropErrorLooksTechnical(hay);
  final detail = technical ? plain : null;

  late final String message;
  if (hay.contains('too_large') ||
      hay.contains('too large') ||
      hay.contains('max 7 gb')) {
    message = dropTooLargeMessage();
  } else if (hay.contains('connection reset') ||
      hay.contains('broken pipe') ||
      hay.contains('connection abort') ||
      hay.contains('connection closed')) {
    message = hay.contains('/drop/offer')
        ? 'They didn’t accept, and the connection dropped'
        : 'They dropped the connection';
  } else if (hay.contains('connection refused')) {
    message = 'Couldn’t reach them. They may have closed OneDrop.';
  } else if (hay.contains('timed out') ||
      hay.contains('timeout') ||
      hay.contains('time out')) {
    message = 'They didn’t respond in time';
  } else if (hay.contains('network is unreachable') ||
      hay.contains('no route to host') ||
      hay.contains('failed host lookup') ||
      hay.contains('name or service not known')) {
    message = 'They’re not on this Wi‑Fi anymore';
  } else if (hay.contains('no response from peer')) {
    message = 'They didn’t answer';
  } else if (hay.contains('could not send this file') ||
      hay.contains('bad_offer')) {
    message = 'This file couldn’t be sent';
  } else if (hay.contains('transfer failed on')) {
    message = 'The transfer stopped while sending';
  } else if (hay.contains('httpexception') || hay.contains('socketexception')) {
    message = 'Couldn’t reach the other device';
  } else if (detail == null) {
    message = plain;
  } else {
    message = 'The transfer didn’t finish';
  }

  if (detail == null || detail == message) {
    return DropSendErrorCopy(message: message);
  }
  return DropSendErrorCopy(message: message, detail: detail);
}

bool _dropErrorLooksTechnical(String hay) {
  return hay.contains('exception') ||
      hay.contains('os error') ||
      hay.contains('errno') ||
      hay.contains('uri =') ||
      hay.contains('socket') ||
      hay.contains('handshake') ||
      hay.contains('statuscode');
}
