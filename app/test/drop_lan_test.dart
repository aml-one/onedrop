import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/services/drop_lan.dart';

void main() {
  test('loopback has no subnet broadcast', () {
    expect(subnetBroadcast24(InternetAddress.loopbackIPv4), isNull);
  });

  test('/24 directed broadcast from a LAN address', () {
    final dest = subnetBroadcast24(InternetAddress('192.168.1.42'));
    expect(dest?.address, '192.168.1.255');
  });

  test('a LAN peer stays only on the same /24', () {
    final wifi = [InternetAddress('192.168.1.20')];
    expect(
      dropHostOnLocalLan(InternetAddress('192.168.1.10'), wifi),
      isTrue,
    );
    expect(
      dropHostOnLocalLan(InternetAddress('192.168.2.10'), wifi),
      isFalse,
    );
  });

  test('this phone is not a nearby peer, even with a Gallery hello', () {
    final wifi = [InternetAddress('192.168.1.20')];
    expect(dropHostIsSelf(InternetAddress('192.168.1.20'), wifi), isTrue);
    expect(dropHostIsSelf(InternetAddress('192.168.1.10'), wifi), isFalse);
    expect(
      dropPeerStillHere(
        host: InternetAddress('192.168.1.20'),
        lastSeen: DateTime.now(),
        now: DateTime.now(),
        local: wifi,
      ),
      isFalse,
    );
  });

  test('cellular-only addresses do not keep a previous Wi-Fi peer', () {
    final mobile = [InternetAddress('10.64.0.2')];
    expect(
      dropPeerStillHere(
        host: InternetAddress('192.168.1.10'),
        lastSeen: DateTime.now(),
        now: DateTime.now(),
        local: mobile,
      ),
      isFalse,
    );
  });

  test('empty local IPv4 keeps a fresh peer until TTL', () {
    final seen = DateTime.now();
    expect(
      dropPeerStillHere(
        host: InternetAddress('192.168.1.10'),
        lastSeen: seen,
        now: seen,
        local: const [],
      ),
      isTrue,
    );
    expect(
      dropPeerStillHere(
        host: InternetAddress('192.168.1.10'),
        lastSeen: seen,
        now: seen.add(const Duration(seconds: 25)),
        local: const [],
      ),
      isFalse,
    );
  });

  test('a 24 second silent hello expires even on the same LAN', () {
    final wifi = [InternetAddress('192.168.1.20')];
    final seen = DateTime.utc(2026, 8, 31, 10, 0, 0);
    expect(
      dropPeerStillHere(
        host: InternetAddress('192.168.1.10'),
        lastSeen: seen,
        now: seen.add(const Duration(seconds: 25)),
        local: wifi,
      ),
      isFalse,
    );
    expect(
      dropPeerStillHere(
        host: InternetAddress('192.168.1.10'),
        lastSeen: seen,
        now: seen.add(const Duration(seconds: 10)),
        local: wifi,
      ),
      isTrue,
    );
  });
}
