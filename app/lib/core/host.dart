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

/// Phone-style window: Android and Ubuntu Touch.
bool get isPhoneSurface => Platform.isAndroid || isUbuntuTouch;

/// Desktop tray: Windows, macOS, and non-UT Linux.
bool get isDesktopTray {
  if (Platform.isWindows || Platform.isMacOS) return true;
  return Platform.isLinux && !isUbuntuTouch;
}
