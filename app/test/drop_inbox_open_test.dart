import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/drop_prefs.dart';
import 'package:onedrop/core/host.dart';
import 'package:onedrop/services/drop_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<String> opened;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DropPrefs.resetForTest();
    await DropPrefs.ensure();
    DropInbox.resetOpenGateForTest();
    opened = <String>[];
    openFolderInExplorer = (path) async {
      opened.add(path);
    };
  });

  tearDown(() {
    openFolderInExplorer = defaultOpenFolderInExplorer;
    DropInbox.resetOpenGateForTest();
  });

  test('a batch of files in one folder reveals that folder once', () {
    const inbox = r'C:\Users\x\Downloads\OneDrop';
    expect(
      dropRevealFolder(
        [
          r'C:\Users\x\Downloads\OneDrop\a.pdf',
          r'C:\Users\x\Downloads\OneDrop\b.pdf',
          r'C:\Users\x\Downloads\OneDrop\c.jpg',
        ],
        inbox: inbox,
      ),
      inbox,
    );
  });

  test('mixed inbox and pictures folders prefer the inbox', () {
    const inbox = r'C:\Users\x\Downloads\OneDrop';
    expect(
      dropRevealFolder(
        [
          r'C:\Users\x\Downloads\OneDrop\notes.pdf',
          r'C:\Users\x\Pictures\OneDrop\shot.jpg',
        ],
        inbox: inbox,
      ),
      inbox,
    );
  });

  test('empty paths fall back to the inbox', () {
    const inbox = r'C:\Temp\OneDropInbox';
    expect(dropRevealFolder(const [], inbox: inbox), inbox);
  });

  test('openReceived starts one explorer for many files', () async {
    final root = Directory.systemTemp.createTempSync('onedrop-open');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await DropInbox.openReceived([
      p.join(root.path, 'a.pdf'),
      p.join(root.path, 'b.pdf'),
      p.join(root.path, 'c.jpg'),
    ]);
    expect(opened, [root.path]);
  });

  test('openOnce ignores a second open of the same folder', () async {
    final root = Directory.systemTemp.createTempSync('onedrop-once');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await DropInbox.openOnce(root.path);
    await DropInbox.openOnce(root.path);
    expect(opened, [root.path]);
  });

  test('revealReceivedBatch stays quiet when the setting is off', () async {
    await DropPrefs.setOpenExplorerOnReceive(false);
    expect(DropPrefs.openExplorerOnReceive, isFalse);
    await revealReceivedBatch(
      DropReceivedBatch(
        message: 'Received 3 files from Liv',
        paths: const ['a.pdf', 'b.pdf', 'c.pdf'],
        peerName: 'Liv',
      ),
    );
    expect(opened, isEmpty);
  });

  test('revealReceivedBatch opens once when the setting is on', () async {
    await DropPrefs.setOpenExplorerOnReceive(true);
    final root = Directory.systemTemp.createTempSync('onedrop-recv');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await revealReceivedBatch(
      DropReceivedBatch(
        message: 'Received 3 files from Liv',
        paths: [
          p.join(root.path, 'a.pdf'),
          p.join(root.path, 'b.pdf'),
          p.join(root.path, 'c.pdf'),
        ],
        peerName: 'Liv',
      ),
    );
    if (isDesktopTray) {
      expect(opened, [root.path]);
    } else {
      expect(opened, isEmpty);
    }
  });

  test('AirGrab receive does not open File Explorer', () async {
    await DropPrefs.setOpenExplorerOnReceive(true);
    final root = Directory.systemTemp.createTempSync('onedrop-air');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await revealReceivedBatch(
      DropReceivedBatch(
        message: 'Received 2 photos from Liv',
        paths: [
          p.join(root.path, 'a.jpg'),
          p.join(root.path, 'b.jpg'),
        ],
        peerName: 'Liv',
        airGrab: true,
      ),
    );
    expect(opened, isEmpty);
  });
}
