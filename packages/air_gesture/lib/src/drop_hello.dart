import 'air_drop_target.dart';

AirPeerRole parseAirRole(Object? raw) {
  switch ('$raw') {
    case 'desktop':
      return AirPeerRole.desktop;
    case 'tablet':
      return AirPeerRole.tablet;
    default:
      return AirPeerRole.phone;
  }
}

AirPeerOs parseAirOs(Object? raw) {
  switch ('$raw') {
    case 'android':
      return AirPeerOs.android;
    case 'windows':
      return AirPeerOs.windows;
    case 'macos':
      return AirPeerOs.macos;
    case 'linux':
      return AirPeerOs.linux;
    default:
      return AirPeerOs.other;
  }
}

String airRoleWire(AirPeerRole role) {
  switch (role) {
    case AirPeerRole.desktop:
      return 'desktop';
    case AirPeerRole.tablet:
      return 'tablet';
    case AirPeerRole.phone:
      return 'phone';
  }
}

String airOsWire(AirPeerOs os) {
  switch (os) {
    case AirPeerOs.android:
      return 'android';
    case AirPeerOs.windows:
      return 'windows';
    case AirPeerOs.macos:
      return 'macos';
    case AirPeerOs.linux:
      return 'linux';
    case AirPeerOs.other:
      return 'other';
  }
}

/// Which AmL app is listening. Gallery is photos only; OneDrop takes files too.
enum AirDropApp { gallery, onedrop }

AirDropApp parseAirApp(Object? raw, {bool filesCapable = false}) {
  switch ('$raw'.toLowerCase().trim()) {
    case 'onedrop':
    case 'one drop':
    case 'files':
      return AirDropApp.onedrop;
    case 'gallery':
    case 'photos':
      return AirDropApp.gallery;
    default:
      return filesCapable ? AirDropApp.onedrop : AirDropApp.gallery;
  }
}

String airAppWire(AirDropApp app) {
  return app == AirDropApp.onedrop ? 'onedrop' : 'gallery';
}

/// Hello `app` wins when present. Otherwise a files BLE bit or a known
/// OneDrop peer stays OneDrop, so an old hello cannot hide files support.
AirDropApp mergeAirApp(
  AirDropApp? existing, {
  Object? helloApp,
  bool filesCapable = false,
}) {
  final key = '$helloApp'.toLowerCase().trim();
  if (key == 'onedrop' || key == 'one drop' || key == 'files') {
    return AirDropApp.onedrop;
  }
  if (key == 'gallery' || key == 'photos') {
    return AirDropApp.gallery;
  }
  if (filesCapable || existing == AirDropApp.onedrop) {
    return AirDropApp.onedrop;
  }
  return existing ?? AirDropApp.gallery;
}

class AirHolding {
  const AirHolding({required this.count, this.kind = 'photo'});

  final int count;
  final String kind;

  Map<String, dynamic> toJson() => {'count': count, 'kind': kind};

  static AirHolding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final count = (raw['count'] as num?)?.toInt() ?? 0;
    if (count <= 0) return null;
    return AirHolding(
      count: count,
      kind: raw['kind'] as String? ?? 'photo',
    );
  }
}
