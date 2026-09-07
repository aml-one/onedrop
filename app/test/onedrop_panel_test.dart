import 'dart:io';

import 'package:air_gesture/air_gesture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/drop_controller.dart';
import 'package:onedrop/core/drop_prefs.dart';
import 'package:onedrop/core/labels.dart';
import 'package:onedrop/panel.dart';
import 'package:onedrop/services/drop_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DropPrefs.resetForTest();
    await DropPrefs.ensure();
  });

  test('payload labels match Gallery One Drop copy', () {
    expect(dropPayloadLabel(photos: 1, videos: 0), '1 photo');
    expect(dropPayloadLabel(photos: 2, videos: 3), '2 photos · 3 videos');
    expect(dropPayloadLabel(photos: 0, videos: 0, files: 1), '1 file');
    expect(isVideoPath(r'C:\clip.MP4'), isTrue);
    expect(isVideoPath('sunset.jpg'), isFalse);
    expect(kindForPath('report.pdf'), 'file');
    expect(formatVideoDuration(5), '0:05');
    expect(formatVideoDuration(75), '1:15');
    expect(formatVideoDuration(3600), '60:00');
  });

  test('nearby avatars use the device type', () {
    DropPeer peer({
      required AirPeerRole role,
      required AirPeerOs os,
    }) {
      return DropPeer(
        id: 'p',
        name: 'Liv',
        host: InternetAddress.loopbackIPv4,
        port: 4071,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
        role: role,
        os: os,
      );
    }

    expect(
      dropDeviceTypeLabel(
        peer(role: AirPeerRole.phone, os: AirPeerOs.android),
      ),
      'Phone',
    );
    expect(
      dropDeviceTypeLabel(
        peer(role: AirPeerRole.desktop, os: AirPeerOs.windows),
      ),
      'PC',
    );
    expect(
      dropDeviceTypeLabel(
        peer(role: AirPeerRole.desktop, os: AirPeerOs.macos),
      ),
      'Mac',
    );
    expect(
      dropDeviceTypeLabel(
        peer(role: AirPeerRole.desktop, os: AirPeerOs.linux),
      ),
      'Linux',
    );
  });

  test('declined copy names One Drop', () {
    expect(DropDeclined().toString(), 'They declined this One Drop');
  });

  test('Ask never auto-accepts', () async {
    await DropPrefs.setDropAcceptMode(DropAcceptMode.ask);
    expect(DropPrefs.autoAccepts('peer-a'), isFalse);
  });

  testWidgets('panel skips the name prompt', (tester) async {
    final controller = DropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 370,
            height: 425,
            child: OneDropPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('Name this computer'), findsNothing);
    expect(find.text('Name this PC'), findsNothing);
    expect(find.text('Looking nearby'), findsOneWidget);
  });

  testWidgets('panel shows the send buttons without a header title', (tester) async {
    await DropPrefs.setDropDisplayName('Studio PC');
    final controller = DropController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 370,
            height: 425,
            child: OneDropPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('One Drop'), findsNothing);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Open folder'), findsOneWidget);
    expect(find.text('Looking nearby'), findsOneWidget);
  });

  testWidgets('settings offers a receive folder', (tester) async {
    await DropPrefs.setDropDisplayName('Studio PC');
    final controller = DropController();
    addTearDown(controller.dispose);
    controller.openSettings();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 370,
            height: 425,
            child: OneDropPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('Receive to'), findsOneWidget);
    expect(find.text('Choose'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Open File Explorer when receiving'), findsOneWidget);
    expect(find.text('Opens once per drop, even if several files arrive.'), findsOneWidget);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Known'), findsOneWidget);
    expect(find.text('Use AirGrab for transfer…'), findsOneWidget);
    expect(find.text('OneDrop'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(find.text('One Drop'), findsNothing);
  });

  test('system back closes settings and stays in the panel', () {
    final controller = DropController();
    addTearDown(controller.dispose);
    controller.settingsOpen = true;
    expect(controller.handleSystemBack(), isTrue);
    expect(controller.settingsOpen, isFalse);
    controller.outcome = SendOutcome.ok;
    expect(controller.handleSystemBack(), isTrue);
    expect(controller.outcome, isNull);
    expect(controller.handleSystemBack(), isFalse);
  });

  test('send wait Cancel dismisses immediately', () async {
    final controller = DropController();
    addTearDown(controller.dispose);
    final token = DropSendCancelToken();
    controller.cancel = token;
    controller.progress = const DropSendProgress(
      phase: DropSendPhase.waiting,
      peerName: 'Mi 11 Ultra',
      fraction: 0,
      label: 'Waiting for Mi 11 Ultra to accept',
    );
    controller.abortSend();
    expect(controller.progress, isNull);
    expect(controller.cancel, isNull);
    expect(controller.transferring, isFalse);
    expect(token.isCancelled, isTrue);
    await token.whenCancelled;
  });

  test('system back aborts a waiting send', () {
    final controller = DropController();
    addTearDown(controller.dispose);
    controller.cancel = DropSendCancelToken();
    controller.progress = const DropSendProgress(
      phase: DropSendPhase.waiting,
      peerName: 'Mi 11 Ultra',
      fraction: 0,
      label: 'Waiting for Mi 11 Ultra to accept',
    );
    controller.handleSystemBack();
    expect(controller.progress, isNull);
    expect(controller.transferring, isFalse);
  });

  testWidgets('panel shows a circular receive ring', (tester) async {
    await DropPrefs.setDropDisplayName('Studio PC');
    final controller = DropController();
    addTearDown(controller.dispose);
    controller.receiveProgress = const DropReceiveProgress(
      offerId: 'o',
      peerName: 'Kitchen',
      receivedBytes: 4 * 1024 * 1024,
      totalBytes: 10 * 1024 * 1024,
      fileIndex: 0,
      fileCount: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 370,
            height: 425,
            child: OneDropPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('Receiving from Kitchen'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(controller.receiveProgress, isNull);
    expect(find.text('Receiving from Kitchen'), findsNothing);
  });

  testWidgets('send wait Cancel leaves the waiting screen', (tester) async {
    await DropPrefs.setDropDisplayName('Mi17');
    final controller = DropController();
    addTearDown(controller.dispose);
    controller.cancel = DropSendCancelToken();
    controller.progress = const DropSendProgress(
      phase: DropSendPhase.waiting,
      peerName: 'Mi 11 Ultra',
      fraction: 0,
      label: 'Waiting for Mi 11 Ultra to accept',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 370,
            height: 425,
            child: OneDropPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('Waiting for Mi 11 Ultra'), findsOneWidget);
    expect(find.text('They need to accept on their device'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(controller.progress, isNull);
    expect(find.text('Waiting for Mi 11 Ultra'), findsNothing);
  });

  test('send errors map to a plain reason and keep the raw detail', () {
    final reset = dropSendErrorCopy(
      'HttpException: Connection reset by peer, uri = http://192.168.31.199:57939/drop/offer',
    );
    expect(
      reset.message,
      'They didn’t accept, and the connection dropped',
    );
    expect(reset.detail, contains('Connection reset by peer'));

    expect(
      dropSendErrorCopy('SocketException: Connection reset by peer').message,
      'They dropped the connection',
    );
    expect(
      dropSendErrorCopy('SocketException: Connection refused').message,
      'Couldn’t reach them. They may have closed OneDrop.',
    );
    expect(
      dropSendErrorCopy('File too large for One Drop (max 7 GB)').detail,
      isNull,
    );
  });

  testWidgets('failed send shows a friendly reason above Close', (tester) async {
    await DropPrefs.setDropDisplayName('Mi17');
    final controller = DropController();
    addTearDown(controller.dispose);
    controller.outcome = SendOutcome.failed;
    controller.error =
        'HttpException: Connection reset by peer, uri = http://192.168.31.199:57939/drop/offer';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 370,
            height: 425,
            child: OneDropPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('Couldn’t send'), findsOneWidget);
    expect(
      find.text('They didn’t accept, and the connection dropped'),
      findsOneWidget,
    );
    expect(find.textContaining('HttpException: Connection reset by peer'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });
}
