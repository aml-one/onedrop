import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'drop_prefs.dart';
import 'panel_window.dart';

class TrayHost with TrayListener, WindowListener {
  TrayHost._();
  static final instance = TrayHost._();

  bool _wired = false;
  VoidCallback? onOpenSettings;
  VoidCallback? onArmAirGrab;
  Future<void> Function()? onQuit;

  static bool get _desktop =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> ensure() async {
    if (!_desktop || _wired) return;
    trayManager.addListener(this);
    windowManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/icon/tray.ico' : 'assets/icon/tray.png',
    );
    await trayManager.setToolTip('One Drop');
    final items = <MenuItem>[
      MenuItem(key: 'show', label: 'Open One Drop'),
      if (DropPrefs.airGrabAvailable)
        MenuItem(key: 'air_grab', label: 'Arm air grab'),
      MenuItem(key: 'settings', label: 'Settings'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit One Drop'),
    ];
    await trayManager.setContextMenu(Menu(items: items));
    _wired = true;
  }

  Future<void> dispose() async {
    if (!_wired) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    _wired = false;
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(PanelWindow.toggle());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(PanelWindow.show());
      case 'air_grab':
        onArmAirGrab?.call();
      case 'settings':
        onOpenSettings?.call();
        unawaited(PanelWindow.show());
      case 'quit':
        unawaited(onQuit?.call());
    }
  }

  @override
  void onWindowBlur() {
    if (PanelWindow.busy || PanelWindow.beacon) return;
    unawaited(PanelWindow.hide());
  }

  @override
  void onWindowClose() {
    unawaited(PanelWindow.hide());
  }
}
