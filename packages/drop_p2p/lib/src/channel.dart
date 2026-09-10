import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'beacon.dart';

const _methods = MethodChannel('one.aml.onedrop/p2p');
const _events = EventChannel('one.aml.onedrop/p2p-peers');

class DropP2pLink {
  const DropP2pLink({required this.host, required this.port});

  final String host;
  final int port;
}

class DropP2pSighting {
  const DropP2pSighting({
    required this.peerId,
    required this.name,
    required this.port,
    required this.role,
    required this.os,
    this.files = false,
  });

  final String peerId;
  final String name;
  final int port;
  final String role;
  final String os;
  final bool files;

  static DropP2pSighting? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['peerId'] ?? ''}'.trim();
    final port = (raw['port'] as num?)?.toInt() ?? 0;
    if (id.isEmpty || port <= 0) return null;
    return DropP2pSighting(
      peerId: id,
      name: '${raw['name'] ?? ''}'.trim().isEmpty
          ? 'One Drop'
          : '${raw['name']}'.trim(),
      port: port,
      role: '${raw['role'] ?? 'phone'}',
      os: '${raw['os'] ?? 'other'}',
      files: raw['files'] == true,
    );
  }
}

class DropP2p {
  DropP2p._();

  static Stream<DropP2pSighting>? _sightings;
  static bool _started = false;
  static String? lastError;

  static bool get supported {
    if (kIsWeb) return false;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return false;
    return Platform.isAndroid || Platform.isWindows;
  }

  static Stream<DropP2pSighting> get sightings {
    return _sightings ??= _events
        .receiveBroadcastStream()
        .map(DropP2pSighting.fromMap)
        .where((row) => row != null)
        .cast<DropP2pSighting>();
  }

  static Future<void> start({
    required String peerId,
    required String name,
    required int port,
    required String role,
    required String os,
    bool files = false,
  }) async {
    if (!supported) return;
    lastError = null;
    try {
      final ok = await _methods.invokeMethod<bool>('start', {
        'peerId': peerId,
        'name': name,
        'port': port,
        'role': role,
        'os': os,
        'beacon': encodeDropP2pBeacon(
          peerId: peerId,
          port: port,
          role: role,
          os: os,
          files: files,
        ),
        'nameBytes': encodeDropP2pName(name),
      });
      _started = ok != false;
      if (ok == false) {
        final status = await debugStatus();
        final skip = '${status['skip'] ?? ''}'.trim();
        lastError = skip.isEmpty
            ? 'nearby permissions missing or radio did not start'
            : skip;
      } else {
        lastError = null;
      }
    } catch (error) {
      lastError = '$error';
    }
  }

  static Future<Map<String, Object?>> debugStatus() async {
    if (!supported) {
      return {'supported': false, 'lastError': lastError};
    }
    try {
      final raw = await _methods.invokeMethod<dynamic>('debugStatus');
      if (raw is Map) {
        final skip = '${raw['skip'] ?? ''}'.trim();
        final radioUp = raw['scanStarted'] == true ||
            raw['advertiseStarted'] == true;
        if (radioUp && skip.isEmpty) {
          lastError = null;
        } else if (skip.isNotEmpty) {
          lastError = skip;
        }
        return {
          'supported': true,
          'lastError': lastError,
          for (final entry in raw.entries) '${entry.key}': entry.value,
        };
      }
    } catch (error) {
      return {'supported': true, 'error': '$error', 'lastError': lastError};
    }
    return {'supported': true, 'lastError': lastError};
  }

  static Future<void> setScanHard(bool hard) async {
    if (!supported) return;
    try {
      await _methods.invokeMethod<void>('setScanHard', {'hard': hard});
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!supported && !_started) return;
    _started = false;
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<DropP2pLink> connect(String peerId) async {
    if (!supported) {
      throw StateError('Nearby radio is not on this device');
    }
    try {
      final raw = await _methods.invokeMethod<dynamic>('connect', {
        'peerId': peerId,
      });
      if (raw is! Map) {
        throw StateError('Could not open a private Wi-Fi link');
      }
      final host = '${raw['host'] ?? ''}'.trim();
      final port = (raw['port'] as num?)?.toInt() ?? 0;
      if (host.isEmpty || port <= 0) {
        throw StateError('Could not open a private Wi-Fi link');
      }
      return DropP2pLink(host: host, port: port);
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Could not reach them nearby');
    }
  }

  static Future<void> teardown() async {
    if (!supported) return;
    try {
      await _methods.invokeMethod<void>('teardown');
    } catch (_) {}
  }
}
