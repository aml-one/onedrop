import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

import 'drop_prefs.dart';

class Autostart {
  Autostart._();

  static bool get available =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<void> setup() async {
    if (!available) return;
    launchAtStartup.setup(
      appName: 'One Drop',
      appPath: Platform.resolvedExecutable,
    );
  }

  static Future<bool> isEnabled() async {
    if (!available) return DropPrefs.launchAtStartup;
    try {
      return await launchAtStartup.isEnabled();
    } catch (_) {
      return DropPrefs.launchAtStartup;
    }
  }

  static Future<void> setEnabled(bool value) async {
    await DropPrefs.setLaunchAtStartup(value);
    if (!available) return;
    try {
      if (value) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (_) {}
  }
}
