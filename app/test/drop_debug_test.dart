import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/drop_prefs.dart';
import 'package:onedrop/services/drop_debug.dart';
import 'package:onedrop/services/drop_debug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DropPrefs.resetForTest();
    DropDebugLog.resetForTest();
    await DropPrefs.ensure();
  });

  test('debug snapshot is v2 with permissions and events', () async {
    DropDebugLog.event('radio', 'scan_failed_2');
    final snap = await oneDropDebugSnapshot(trigger: 'test');
    expect(snap['v'], 2);
    expect(snap['app'], 'onedrop');
    expect(snap['trigger'], 'test');
    expect(snap['optIn'], isFalse);
    expect(snap['permissions'], isA<List>());
    expect(snap['events'], isNotEmpty);
    expect(snap['extras'], isA<Map>());
  });

  test('debug payload trims log to stay under the live size gate', () {
    final huge = <String, Object?>{
      'v': 2,
      'app': 'onedrop',
      'log': List<String>.filled(400, 'x' * 200),
      'events': List<Map<String, String>>.filled(200, {'k': 'n', 'd': 'y' * 80}),
      'peers': [
        for (var i = 0; i < 40; i++) {'id': 'p$i', 'name': 'n$i'},
      ],
    };
    final capped = capOneDropDebugPayload(huge);
    final encoded = utf8.encode(jsonEncode(capped));
    expect(encoded.length, lessThanOrEqualTo(kOneDropDebugMaxBytes));
    expect((capped['log'] as List).length, lessThan(400));
  });

  test('debug upload opt-in is off until turned on and gets a session id', () async {
    expect(DropPrefs.debugUploadOptIn, isFalse);
    expect(DropPrefs.debugUploadSession, isEmpty);
    await DropPrefs.setDebugUploadOptIn(true);
    expect(DropPrefs.debugUploadOptIn, isTrue);
    expect(DropPrefs.debugUploadSession, isNotEmpty);
    final seq = await DropPrefs.bumpDebugUploadSeq();
    expect(seq, 1);
    await DropPrefs.setDebugUploadOptIn(false);
    expect(DropPrefs.debugUploadOptIn, isFalse);
    expect(DropPrefs.debugUploadSession, isEmpty);
  });
}
