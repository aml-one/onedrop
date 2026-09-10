import 'dart:convert';
import 'dart:io';

import 'package:drop_p2p/drop_p2p.dart';

import '../core/app_version.dart';
import '../core/device_channel.dart';
import '../core/drop_prefs.dart';
import 'drop_debug_log.dart';
import 'drop_service.dart';

const kOneDropDebugUploadUrl = 'https://aml.one/api/onedrop/debug';

/// Stay under the aml.one 96 KB ingest gate.
const kOneDropDebugMaxBytes = 80_000;

Future<Map<String, Object?>> oneDropDebugSnapshot({
  String trigger = 'manual',
  int? seq,
}) async {
  final radio = await DropP2p.debugStatus();
  final extras = await DeviceChannel.debugExtras();
  final permissions = await DeviceChannel.listPermissions();
  final svc = DropService.instance;
  final session = DropPrefs.debugUploadSession;
  return {
    'v': 2,
    'app': 'onedrop',
    'kind': DropPrefs.debugUploadOptIn ? 'session' : 'snapshot',
    'trigger': trigger,
    'version': kAppVersion,
    'at': DateTime.now().toUtc().toIso8601String(),
    if (session.isNotEmpty) 'sessionId': session,
    'seq': ?seq,
    'optIn': DropPrefs.debugUploadOptIn,
    'peerId': svc.peerId,
    'name': DropPrefs.dropDisplayName,
    'running': svc.running,
    'lastError': svc.lastError,
    'udpPort': DropService.udpPort,
    'httpPort': svc.debugHttpPort,
    'ipv4': svc.debugIpv4,
    'radioSupported': DropP2p.supported,
    'radioStartError': DropP2p.lastError,
    'radio': radio,
    'extras': extras,
    'permissions': [for (final row in permissions) row.toJson()],
    'peers': [
      for (final peer in svc.peerList)
        {
          'id': peer.id,
          'name': peer.name,
          'via': peer.viaRadio ? 'ble' : 'wifi',
          'host': peer.host.address,
          'port': peer.port,
        },
    ],
    'events': DropDebugLog.events,
    'log': svc.debugLog,
  };
}

String oneDropDebugText(Map<String, Object?> snapshot) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(snapshot);
}

Map<String, Object?> capOneDropDebugPayload(Map<String, Object?> snapshot) {
  var body = Map<String, Object?>.from(snapshot);
  var encoded = utf8.encode(jsonEncode(body));
  if (encoded.length <= kOneDropDebugMaxBytes) return body;

  List<dynamic> trim(List<dynamic> rows, int keep) {
    if (rows.length <= keep) return rows;
    return rows.sublist(rows.length - keep);
  }

  for (final keep in const [80, 40, 20, 8, 0]) {
    body = Map<String, Object?>.from(body);
    body['log'] = trim(List<dynamic>.from(body['log'] as List? ?? const []), keep);
    body['events'] =
        trim(List<dynamic>.from(body['events'] as List? ?? const []), keep);
    if (keep == 0) {
      body.remove('peers');
    }
    encoded = utf8.encode(jsonEncode(body));
    if (encoded.length <= kOneDropDebugMaxBytes) return body;
  }
  body['truncated'] = true;
  return body;
}

Future<String> uploadOneDropDebug({String trigger = 'manual'}) async {
  final seq = DropPrefs.debugUploadOptIn
      ? await DropPrefs.bumpDebugUploadSeq()
      : null;
  final snapshot = capOneDropDebugPayload(
    await oneDropDebugSnapshot(trigger: trigger, seq: seq),
  );
  final payload = utf8.encode(jsonEncode(snapshot));
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(kOneDropDebugUploadUrl));
    request.headers.contentType = ContentType.json;
    request.add(payload);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['id'] is String) {
      return decoded['id'] as String;
    }
    return 'ok';
  } finally {
    client.close(force: true);
  }
}
