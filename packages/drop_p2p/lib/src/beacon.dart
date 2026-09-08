import 'dart:convert';
import 'dart:typed_data';

/// BLE manufacturer id for the One Drop beacon (adv).
const dropP2pCompanyId = 0x0A11;

/// BLE manufacturer id for the UTF-8 display name (scan response).
const dropP2pNameCompanyId = 0x0A12;

const dropP2pVersion = 1;

/// GATT service + characteristics. Keep in sync with Kotlin and C++.
const dropP2pServiceUuid = 'a11d0d01-6d65-4f6e-6472-6f70426c6531';
const dropP2pInfoUuid = 'a11d0d01-6d65-4f6e-6472-6f70426c6532';
const dropP2pLinkUuid = 'a11d0d01-6d65-4f6e-6472-6f70426c6533';

const dropRadioPeerTtl = Duration(seconds: 30);

class DropP2pBeacon {
  const DropP2pBeacon({
    required this.peerId,
    required this.port,
    required this.role,
    required this.os,
    this.name = '',
  });

  final String peerId;
  final int port;
  final String role;
  final String os;
  final String name;
}

int packDropP2pFlags({required String role, required String os}) {
  final roleBits = role == 'desktop' ? 1 : 0;
  final osBits = switch (os) {
    'android' => 1,
    'windows' => 2,
    'linux' => 3,
    'macos' => 4,
    _ => 0,
  };
  return roleBits | (osBits << 2);
}

({String role, String os}) unpackDropP2pFlags(int flags) {
  final role = (flags & 0x03) == 1 ? 'desktop' : 'phone';
  final os = switch ((flags >> 2) & 0x07) {
    1 => 'android',
    2 => 'windows',
    3 => 'linux',
    4 => 'macos',
    _ => 'other',
  };
  return (role: role, os: os);
}

Uint8List encodeDropP2pBeacon({
  required String peerId,
  required int port,
  required String role,
  required String os,
}) {
  final bytes = Uint8List(22);
  bytes[0] = 0x4F; // O
  bytes[1] = 0x44; // D
  bytes[2] = dropP2pVersion;
  bytes[3] = packDropP2pFlags(role: role, os: os);
  bytes[4] = (port >> 8) & 0xFF;
  bytes[5] = port & 0xFF;
  final id = utf8.encode(peerId);
  final n = id.length > 16 ? 16 : id.length;
  bytes.setRange(6, 6 + n, id.take(n));
  return bytes;
}

DropP2pBeacon? decodeDropP2pBeacon(Uint8List data, {String name = ''}) {
  if (data.length < 22) return null;
  if (data[0] != 0x4F || data[1] != 0x44) return null;
  if (data[2] != dropP2pVersion) return null;
  final port = (data[4] << 8) | data[5];
  if (port <= 0 || port > 65535) return null;
  var end = 22;
  while (end > 6 && data[end - 1] == 0) {
    end--;
  }
  final peerId = utf8.decode(data.sublist(6, end), allowMalformed: true).trim();
  if (peerId.isEmpty) return null;
  final flags = unpackDropP2pFlags(data[3]);
  return DropP2pBeacon(
    peerId: peerId,
    port: port,
    role: flags.role,
    os: flags.os,
    name: name,
  );
}

Uint8List encodeDropP2pName(String name) {
  final trimmed = name.trim();
  final raw = utf8.encode(trimmed.isEmpty ? 'One Drop' : trimmed);
  final n = raw.length > 22 ? 22 : raw.length;
  return Uint8List.fromList(raw.take(n).toList());
}

String decodeDropP2pName(Uint8List data) {
  final text = utf8.decode(data, allowMalformed: true).trim();
  return text.isEmpty ? 'One Drop' : text;
}
