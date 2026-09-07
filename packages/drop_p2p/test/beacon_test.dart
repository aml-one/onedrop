import 'package:drop_p2p/drop_p2p.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('beacon round-trips peer id, port, and desktop/windows flags', () {
    final bytes = encodeDropP2pBeacon(
      peerId: '18f2abc99',
      port: 40711,
      role: 'desktop',
      os: 'windows',
    );
    expect(bytes.length, 22);
    expect(bytes[0], 0x4F);
    expect(bytes[1], 0x44);
    final decoded = decodeDropP2pBeacon(bytes, name: 'Studio PC');
    expect(decoded?.peerId, '18f2abc99');
    expect(decoded?.port, 40711);
    expect(decoded?.role, 'desktop');
    expect(decoded?.os, 'windows');
    expect(decoded?.name, 'Studio PC');
  });

  test('truncated peer ids still decode', () {
    final bytes = encodeDropP2pBeacon(
      peerId: 'short',
      port: 80,
      role: 'phone',
      os: 'android',
    );
    final decoded = decodeDropP2pBeacon(bytes);
    expect(decoded?.peerId, 'short');
    expect(decoded?.role, 'phone');
    expect(decoded?.os, 'android');
  });

  test('wrong magic is ignored', () {
    final bytes = encodeDropP2pBeacon(
      peerId: 'x',
      port: 1,
      role: 'phone',
      os: 'android',
    );
    bytes[0] = 0x00;
    expect(decodeDropP2pBeacon(bytes), isNull);
  });

  test('name encoder keeps twenty-two utf8 bytes', () {
    final bytes = encodeDropP2pName('  Honor  ');
    expect(decodeDropP2pName(bytes), 'Honor');
  });
}
