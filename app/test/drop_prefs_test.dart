import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/device_name.dart';
import 'package:onedrop/core/drop_prefs.dart';
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
    expect(DropPrefs.imagesToCameraRoll, isTrue);
    expect(DropPrefs.mediaSavePath, DropPrefs.cameraRollPath);
    expect(
      DropPrefs.androidCameraRollPath,
      '/storage/emulated/0/DCIM/Camera',
    );
    await DropPrefs.setImagesToCameraRoll(false);
    expect(DropPrefs.imagesToCameraRoll, isFalse);
    expect(DropPrefs.mediaSavePath, DropPrefs.mediaInboxPath);
    expect(DropPrefs.mediaInboxPath.contains('OneDrop'), isTrue);
  });

  test('opening File Explorer on receive is off until turned on', () async {
    expect(DropPrefs.openExplorerOnReceive, isFalse);
    await DropPrefs.setOpenExplorerOnReceive(true);
    expect(DropPrefs.openExplorerOnReceive, isTrue);
    await DropPrefs.setOpenExplorerOnReceive(false);
    expect(DropPrefs.openExplorerOnReceive, isFalse);
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
}
