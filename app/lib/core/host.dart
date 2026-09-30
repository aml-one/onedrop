import 'dart:io';

/// True on Ubuntu Touch / UBports (portable Linux, not a desktop tray).
bool get isUbuntuTouch {
  if (!Platform.isLinux) return false;
  if (Platform.environment['CLICK_FRAMEWORK']?.isNotEmpty == true) {
    return true;
  }
  return File('/usr/share/ubports').existsSync() ||
      File('/usr/share/click').existsSync() ||
      Directory('/usr/share/ubports').existsSync();
}

/// Same markers the AOW OS Files OneDrop stage uses: `AOW_FORM`, desktop
/// session, `/etc/os-release` `ID=aow`, or `/etc/aow`.
bool detectAowOs({
  required bool isLinux,
  Map<String, String> env = const {},
  String osRelease = '',
  bool hasAowMarker = false,
}) {
  if (!isLinux) return false;
  if ((env['AOW_FORM'] ?? '').trim().isNotEmpty) return true;
  final desktop = (env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase();
  if (desktop.contains('AOW')) return true;
  final session = (env['XDG_SESSION_DESKTOP'] ?? '').toUpperCase();
  if (session.contains('AOW')) return true;
  if (hasAowMarker) return true;
  final text = osRelease.toLowerCase();
  if (RegExp(r'^id=aow\b', multiLine: true).hasMatch(text)) return true;
  if (text.contains('name="aow os"') || text.contains("name='aow os'")) {
    return true;
  }
  if (text.contains('pretty_name="aow os') ||
      text.contains("pretty_name='aow os")) {
    return true;
  }
  return false;
}

/// Phone/tablet AOW OS (`AOW_FORM=phone` / `FORM_FACTOR=handset`).
bool detectAowOsMobile({
  required bool isLinux,
  Map<String, String> env = const {},
  String osRelease = '',
  bool hasAowMarker = false,
}) {
  if (!detectAowOs(
    isLinux: isLinux,
    env: env,
    osRelease: osRelease,
    hasAowMarker: hasAowMarker,
  )) {
    return false;
  }
  final form = (env['AOW_FORM'] ?? '').trim().toLowerCase();
  if (form == 'phone' || form == 'tablet' || form == 'handset') return true;
  final factor = (env['FORM_FACTOR'] ?? '').trim().toLowerCase();
  return factor == 'handset' || factor == 'phone' || factor == 'tablet';
}

String? _cachedOsRelease;
bool? _cachedAowMarker;

String _linuxOsRelease() {
  _cachedOsRelease ??= () {
    try {
      final file = File('/etc/os-release');
      if (file.existsSync()) return file.readAsStringSync();
    } catch (_) {}
    return '';
  }();
  return _cachedOsRelease!;
}

bool _linuxHasAowMarker() {
  _cachedAowMarker ??= () {
    try {
      return Directory('/etc/aow').existsSync() || File('/etc/aow').existsSync();
    } catch (_) {
      return false;
    }
  }();
  return _cachedAowMarker!;
}

bool get isAowOs => detectAowOs(
      isLinux: Platform.isLinux,
      env: Platform.environment,
      osRelease: Platform.isLinux ? _linuxOsRelease() : '',
      hasAowMarker: Platform.isLinux ? _linuxHasAowMarker() : false,
    );

bool get isAowOsMobile => detectAowOsMobile(
      isLinux: Platform.isLinux,
      env: Platform.environment,
      osRelease: Platform.isLinux ? _linuxOsRelease() : '',
      hasAowMarker: Platform.isLinux ? _linuxHasAowMarker() : false,
    );

/// Phone-style window: Android, Ubuntu Touch, and AOW OS Mobile.
bool get isPhoneSurface =>
    Platform.isAndroid || isUbuntuTouch || isAowOsMobile;

/// Desktop tray: Windows, macOS, and non-phone Linux (including AOW OS).
bool get isDesktopTray {
  if (Platform.isWindows || Platform.isMacOS) return true;
  return Platform.isLinux && !isUbuntuTouch && !isAowOsMobile;
}
