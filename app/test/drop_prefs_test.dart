import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/device_name.dart';
import 'package:onedrop/core/drop_prefs.dart';
import 'package:onedrop/core/host.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DropPrefs.resetForTest();
    await DropPrefs.ensure();
  });

  test('Known auto-accepts remembered peers only', () async {
    await DropPrefs.setDropAcceptMode(DropAcceptMode.known);
    expect(DropPrefs.autoAccepts('peer-a'), isFalse);
    await DropPrefs.rememberPeer(
      DropKnownPeer(id: 'peer-a', name: 'Kitchen', lastAt: DateTime.now()),
    );
    expect(DropPrefs.autoAccepts('peer-a'), isTrue);
    expect(DropPrefs.autoAccepts('peer-b'), isFalse);
  });

  test('Everyone auto-accepts', () async {
    await DropPrefs.setDropAcceptMode(DropAcceptMode.everyone);
    expect(DropPrefs.autoAccepts('anyone'), isTrue);
  });

  test('Amazon Fire board codes are not advertised as this device', () {
    expect(isJunkDisplayName('KFTUWI'), isTrue);
    expect(isJunkDisplayName('Fire Tablet'), isFalse);
    expect(isJunkDisplayName('Mi17'), isFalse);
  });

  test('localhost is not advertised as this device', () async {
    expect(isJunkDisplayName('localhost'), isTrue);
    expect(isJunkDisplayName('Studio-PC'), isFalse);
    await DropPrefs.setDropDisplayName('localhost');
    expect(DropPrefs.dropDisplayName, isNot(equals('localhost')));
    await DropPrefs.adoptSystemDisplayName();
    expect(isJunkDisplayName(DropPrefs.dropDisplayName), isFalse);
  });

  test('inbox defaults to a OneDrop folder and can be changed', () async {
    expect(DropPrefs.inboxPath.contains('OneDrop'), isTrue);
    await DropPrefs.setInboxPath(r'C:\Temp\OneDropInbox');
    expect(DropPrefs.inboxPath, r'C:\Temp\OneDropInbox');
    expect(DropPrefs.inboxShortLabel, contains('OneDropInbox'));
  });

  test('photos go to the camera roll or the OneDrop folder', () async {
    expect(
      DropPrefs.androidCameraRollPath,
      '/storage/emulated/0/DCIM/Camera',
    );
    if (Platform.isAndroid) {
      expect(DropPrefs.imagesToCameraRoll, isTrue);
      expect(DropPrefs.mediaSavePath, DropPrefs.cameraRollPath);
      await DropPrefs.setImagesToCameraRoll(false);
      expect(DropPrefs.mediaSavePath, DropPrefs.mediaInboxPath);
      expect(DropPrefs.mediaInboxPath.contains('OneDrop'), isTrue);
      return;
    }
    expect(DropPrefs.mediaSavePath, DropPrefs.inboxPath);
    await DropPrefs.setInboxPath(r'C:\Users\ambru\OneDrive\Pictures\OneDrop');
    expect(
      DropPrefs.mediaSavePath,
      r'C:\Users\ambru\OneDrive\Pictures\OneDrop',
    );
  });

  test('opening File Explorer on receive defaults on for the desk', () async {
    expect(DropPrefs.openExplorerOnReceive, isDesktopTray);
    await DropPrefs.setOpenExplorerOnReceive(false);
    expect(DropPrefs.openExplorerOnReceive, isFalse);
    await DropPrefs.setOpenExplorerOnReceive(true);
    expect(DropPrefs.openExplorerOnReceive, isTrue);
  });

  test('Air grab auto-accepts even in Ask; on by default on Windows/macOS', () async {
    expect(DropPrefs.airGrabEnabled, DropPrefs.airGrabAvailable);
    if (!DropPrefs.airGrabEnabled) {
      expect(
        DropPrefs.shouldAutoAccept(peerId: 'pc', airGrab: true),
        isFalse,
      );
      await DropPrefs.setAirGrabEnabled(true);
    }
    expect(
      DropPrefs.shouldAutoAccept(peerId: 'pc', airGrab: true),
      isTrue,
    );
    expect(
      DropPrefs.shouldAutoAccept(peerId: 'pc', airGrab: false),
      isFalse,
    );
  });

  test('remembers LAN IPs so Ethernet can unicast after ARP expires', () async {
    expect(DropPrefs.rememberedLanIpv4, isEmpty);
    await DropPrefs.rememberLanIpv4(InternetAddress('192.168.31.44'));
    await DropPrefs.rememberLanIpv4(InternetAddress('192.168.31.101'));
    await DropPrefs.rememberLanIpv4(InternetAddress.anyIPv4);
    expect(
      DropPrefs.rememberedLanIpv4.map((a) => a.address).toList(),
      ['192.168.31.101', '192.168.31.44'],
    );
  });
}
