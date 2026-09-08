import 'dart:convert';
import 'dart:io';

import 'package:drop_p2p/drop_p2p.dart';

import '../core/app_version.dart';
import '../core/drop_prefs.dart';
import 'drop_service.dart';

const kOneDropDebugUploadUrl = 'https://aml.one/api/onedrop/debug';

Future<Map<String, Object?>> oneDropDebugSnapshot() async {
  final radio = await DropP2p.debugStatus();
  final svc = DropService.instance;
  return {
    'v': 1,
    'app': 'onedrop',
    'version': kAppVersion,
    'at': DateTime.now().toUtc().toIso8601String(),
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
    'log': svc.debugLog,
  };
}

String oneDropDebugText(Map<String, Object?> snapshot) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(snapshot);
}

Future<String> uploadOneDropDebug() async {
  final payload = utf8.encode(jsonEncode(await oneDropDebugSnapshot()));
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(kOneDropDebugUploadUrl));
    request.headers.contentType = ContentType.json;
    request.add(payload);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Upload failed (${response.statusCode})');
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
