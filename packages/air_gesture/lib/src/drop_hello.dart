import 'air_drop_target.dart';

AirPeerRole parseAirRole(Object? raw) {
  switch ('$raw') {
    case 'desktop':
      return AirPeerRole.desktop;
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

String airRoleWire(AirPeerRole role) =>
    role == AirPeerRole.desktop ? 'desktop' : 'phone';

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
