import 'dart:io';

/// OS host strings that must never be advertised as this device.
bool isJunkDisplayName(String raw) {
  final n = raw.trim().toLowerCase();
  if (n.isEmpty) return true;
  const junk = {
    'localhost',
    'localhost.localdomain',
    'loopback',
    '127.0.0.1',
    '::1',
    'unknown',
    'android',
    'this pc',
    'this mac',
    'this linux pc',
    'this phone',
    'name this pc',
    'name this computer',
  };
  if (junk.contains(n)) return true;
  if (n.startsWith('localhost')) return true;
  return false;
}

String cleanDisplayName(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'\.localdomain$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'\.local$', caseSensitive: false), '');
  if (s.length > 32) s = s.substring(0, 32).trimRight();
  return s;
}

String fallbackDisplayName() {
  if (Platform.isAndroid) return 'This phone';
  if (Platform.isMacOS) return 'This Mac';
  if (Platform.isLinux) return 'This Linux PC';
  return 'This PC';
}

/// Computer name / hostname without waiting on native channels.
String localComputerName() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final fromEnv = cleanDisplayName(env['COMPUTERNAME'] ?? '');
    if (!isJunkDisplayName(fromEnv)) return fromEnv;
  }
  final hostEnv = cleanDisplayName(env['HOSTNAME'] ?? env['HOST'] ?? '');
  if (!isJunkDisplayName(hostEnv)) return hostEnv;
  try {
    final fromOs = cleanDisplayName(Platform.localHostname);
    if (!isJunkDisplayName(fromOs)) return fromOs;
  } catch (_) {}
  return fallbackDisplayName();
}
