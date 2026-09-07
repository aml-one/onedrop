import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'host.dart';

class PanelWindow {
  PanelWindow._();

  static const Size size = Size(370, 425);
  static const Size beaconSize = Size(960, 960);
  static const Color panelColor = Color(0xFFF7F5FC);

  /// Chroma-key fill for the catch fog. Must match native
  /// `SetLayeredWindowAttributes` in `air_grab_plugin.cpp`. Not black —
  /// Flutter's clear pixels are not keyed, which left the white plate.
  static const Color beaconPunch = Color(0xFF010001);
  static const _airGrab = MethodChannel('one.aml.onedrop/air_grab');
  static bool busy = false;
  static bool _ready = false;
  static bool _visible = false;
  static bool _beacon = false;
  static bool _previewing = false;
  static Size _previewWindowSize = size;
  static final ValueNotifier<bool> beaconListenable = ValueNotifier(false);
  static VoidCallback? onVisibilityChanged;

  static bool get visible => _visible;
  static bool get beacon => _beacon;
  static bool get previewing => _previewing;
  static Size get activeSize => _previewing ? _previewWindowSize : size;

  static bool get _desktop => !kIsWeb && isDesktopTray;

  static Future<void> ensure() async {
    if (!_desktop || _ready) return;
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: size,
        minimumSize: size,
        maximumSize: size,
        center: false,
        backgroundColor: panelColor,
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
        title: 'One Drop',
      ),
      () async {
        await windowManager.setAsFrameless();
        await windowManager.setHasShadow(true);
        await windowManager.setPreventClose(true);
        await windowManager.setAlwaysOnTop(true);
        await dockToClock();
        await windowManager.hide();
        _visible = false;
      },
    );
    _ready = true;
  }

  static Future<Size> screenVisibleSize() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      return display.visibleSize ?? display.size;
    } catch (_) {
      return const Size(1920, 1080);
    }
  }

  static Future<void> dockToClock() async {
    if (!_desktop || _previewing) return;
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visible = display.visibleSize ?? display.size;
      final origin = display.visiblePosition ?? Offset.zero;
      const margin = 10.0;
      final panel = size;
      final x = origin.dx + visible.width - panel.width - margin;
      // Linux trays are often bottom-right (GNOME/KDE) or top-right.
      // Prefer the bottom when the work area already clears a top bar,
      // otherwise tuck under a top panel.
      final preferBottom = Platform.isLinux || origin.dy <= 28;
      final y = preferBottom
          ? origin.dy + visible.height - panel.height - margin
          : origin.dy + margin;
      await windowManager.setBounds(
        Rect.fromLTWH(x, y, panel.width, panel.height),
      );
    } catch (_) {}
  }

  /// Click-through for the catch glow. On Windows this must not go through
  /// window_manager's setIgnoreMouseEvents — that ORs WS_EX_LAYERED without
  /// attributes and the beacon vanishes. Native click-through uses
  /// WS_EX_TRANSPARENT plus DWM glass, never a black color-key.
  static Future<void> _setClickThrough(bool ignore) async {
    if (Platform.isWindows) {
      try {
        await _airGrab.invokeMethod<void>('setClickThrough', {
          'ignore': ignore,
        });
        return;
      } catch (error, stack) {
        debugPrint('AIRGRAB click-through failed $error\n$stack');
      }
    }
    await windowManager.setIgnoreMouseEvents(ignore);
  }

  static Future<void> showBeacon({bool locked = false}) async {
    if (!_desktop) return;
    if (_previewing) {
      await endPreview(hideWindow: false);
    }
    _beacon = true;
    busy = true;
    if (Platform.isWindows) {
      // Flutter's GPU view cannot chroma-key. A native layered HWND
      // paints the fog. Park the tray HWND off-screen — do not hide()
      // it, or Windows pauses the isolate and catch/send die.
      try {
        await windowManager.setMinimumSize(const Size(64, 64));
        await windowManager.setMaximumSize(const Size(64, 64));
        await windowManager.setBounds(
          const Rect.fromLTWH(-32000, -32000, 64, 64),
        );
        _visible = true;
        await _airGrab.invokeMethod<void>('showCatchFog', {
          'locked': locked,
        });
      } catch (error, stack) {
        debugPrint('AIRGRAB beacon show failed $error\n$stack');
      }
      onVisibilityChanged?.call();
      return;
    }
    beaconListenable.value = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await windowManager.setBackgroundColor(beaconPunch);
      await windowManager.setMinimumSize(const Size(64, 64));
      await windowManager.setMaximumSize(const Size(4000, 4000));
      await windowManager.setHasShadow(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await _placeBeacon();
      await windowManager.setHasShadow(false);
      await _setClickThrough(true);
      await windowManager.show();
      _visible = true;
    } catch (error, stack) {
      debugPrint('AIRGRAB beacon show failed $error\n$stack');
      try {
        await windowManager.show();
        _visible = true;
      } catch (_) {}
    }
    onVisibilityChanged?.call();
  }

  static Future<void> _placeBeacon() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visible = display.visibleSize ?? display.size;
      final origin = display.visiblePosition ?? Offset.zero;
      final side = (visible.shortestSide * 0.72).clamp(420.0, 960.0).toDouble();
      final x = origin.dx + (visible.width - side) / 2;
      final y = origin.dy + (visible.height - side) / 2;
      await windowManager.setBounds(Rect.fromLTWH(x, y, side, side));
    } catch (_) {
      await windowManager.setSize(const Size(720, 720));
      await windowManager.center();
    }
  }

  static Future<void> hideBeacon({bool hideWindow = true}) async {
    if (!_desktop || !_beacon) return;
    _beacon = false;
    try {
      if (Platform.isWindows) {
        await _airGrab.invokeMethod<void>('hideCatchFog');
      } else {
        await _setClickThrough(false);
      }
      await windowManager.setBackgroundColor(panelColor);
      await windowManager.setHasShadow(true);
      await windowManager.setMinimumSize(size);
      await windowManager.setMaximumSize(size);
      await dockToClock();
    } catch (_) {}
    busy = false;
    beaconListenable.value = false;
    onVisibilityChanged?.call();
    if (hideWindow) {
      await hide(force: true);
    }
  }

  /// Centered media preview window. [windowSize] is the outer HWND size
  /// (already capped to ≤70% of the screen by the caller).
  static Future<void> showCenteredPreview(Size windowSize) async {
    if (!_desktop) return;
    if (_beacon) {
      await hideBeacon(hideWindow: false);
    }
    _previewing = true;
    _previewWindowSize = Size(
      windowSize.width.clamp(280, 10000).toDouble(),
      windowSize.height.clamp(200, 10000).toDouble(),
    );
    busy = true;
    try {
      await windowManager.setMinimumSize(const Size(280, 200));
      await windowManager.setMaximumSize(const Size(10000, 10000));
      await _placeCentered(_previewWindowSize);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
      _visible = true;
    } catch (_) {}
    onVisibilityChanged?.call();
  }

  static Future<void> resizeCenteredPreview(Size windowSize) async {
    if (!_desktop || !_previewing) return;
    _previewWindowSize = Size(
      windowSize.width.clamp(280, 10000).toDouble(),
      windowSize.height.clamp(200, 10000).toDouble(),
    );
    try {
      await _placeCentered(_previewWindowSize);
    } catch (_) {}
  }

  static Future<void> _placeCentered(Size panel) async {
    final display = await screenRetriever.getPrimaryDisplay();
    final visible = display.visibleSize ?? display.size;
    final origin = display.visiblePosition ?? Offset.zero;
    final x = origin.dx + (visible.width - panel.width) / 2;
    final y = origin.dy + (visible.height - panel.height) / 2;
    await windowManager.setBounds(
      Rect.fromLTWH(x, y, panel.width, panel.height),
    );
  }

  /// Leave preview mode, restore the docked tray size, then optionally hide.
  static Future<void> endPreview({bool hideWindow = true}) async {
    if (!_desktop) return;
    _previewing = false;
    _previewWindowSize = size;
    try {
      await windowManager.setMinimumSize(size);
      await windowManager.setMaximumSize(size);
      await dockToClock();
    } catch (_) {}
    if (hideWindow) {
      await hide(force: true);
    }
    onVisibilityChanged?.call();
  }

  static Future<void> show({bool force = false}) async {
    if (!_desktop) return;
    if (_beacon) {
      await hideBeacon(hideWindow: false);
    }
    if (_previewing) {
      // Preview owns placement — do not snap back to the clock corner.
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
      _visible = true;
      onVisibilityChanged?.call();
      return;
    }
    await dockToClock();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
    _visible = true;
    onVisibilityChanged?.call();
  }

  static Future<void> hide({bool force = false}) async {
    if (!_desktop) return;
    if (_beacon) return;
    if (busy && !force) return;
    if (_previewing && !force) return;
    await windowManager.hide();
    _visible = false;
    onVisibilityChanged?.call();
  }

  static Future<void> toggle() async {
    if (_visible) {
      await hide();
    } else {
      await show();
    }
  }
}
