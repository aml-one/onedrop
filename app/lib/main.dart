import 'dart:async';
import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_version.dart';
import 'core/autostart.dart';
import 'core/device_channel.dart';
import 'core/drop_controller.dart';
import 'core/drop_prefs.dart';
import 'core/host.dart';
import 'core/panel_window.dart';
import 'core/tray_host.dart';
import 'panel.dart';
import 'services/air_grab_session.dart';
import 'services/drop_service.dart';
import 'widgets/air_grab_target_glow.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DropPrefs.ensure();
  await DropPrefs.adoptSystemDisplayName();
  final testing = Platform.environment['FLUTTER_TEST'] == 'true';
  if (!testing) {
    if (isDesktopTray) {
      await Autostart.setup();
      await DropService.instance.start();
      await PanelWindow.ensure();
      await AirGrabSession.instance.attach();
      await TrayHost.instance.ensure();
    } else {
      if (!Platform.isAndroid) await Autostart.setup();
      await DropService.instance.start();
      if (Platform.isAndroid) {
        await DeviceChannel.ensureFirstRunPermissions();
        await DeviceChannel.startOneDropListen();
      }
      await AirGrabSession.instance.attach();
    }
  }
  final controller = DropController();
  TrayHost.instance.onOpenSettings = controller.openSettings;
  TrayHost.instance.onArmAirGrab = controller.armAirGrab;
  TrayHost.instance.onQuit = quitOneDrop;
  runApp(OneDropApp(controller: controller));
}

Future<void> quitOneDrop() async {
  await AirGrabSession.instance.disarm();
  await DropService.instance.stop();
  try {
    await TrayHost.instance.dispose();
  } catch (_) {}
  if (isDesktopTray) {
    try {
      await windowManager.destroy();
    } catch (_) {}
    if (!kIsWeb) exit(0);
  }
}

class OneDropApp extends StatefulWidget {
  const OneDropApp({super.key, required this.controller});

  final DropController controller;

  @override
  State<OneDropApp> createState() => _OneDropAppState();
}

class _OneDropAppState extends State<OneDropApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_ingestShares());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_ingestShares());
    }
  }

  @override
  Future<bool> didPopRoute() async {
    if (!isPhoneSurface) return super.didPopRoute();
    // Never consume here — pushed routes (Photos, Files) must still pop.
    // Home/Settings back is trapped by PopScope + native MainActivity,
    // which never finishes the activity.
    return false;
  }

  Future<void> _ingestShares() async {
    final paths = await DeviceChannel.takePendingShares();
    if (paths.isEmpty) return;
    widget.controller.queue(outgoingFromPaths(paths));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        PanelWindow.beaconListenable,
        AirGrabSession.instance,
      ]),
      builder: (context, _) {
        final beacon = PanelWindow.beaconListenable.value;
        final light = AmlTheme.light(pageAnimations: false);
        final dark = AmlTheme.dark(pageAnimations: false);
        const punch = PanelWindow.beaconPunch;
        return MaterialApp(
          title: 'OneDrop',
          debugShowCheckedModeBanner: false,
          color: beacon ? punch : kSettingsPageBackground,
          theme: beacon
              ? light.copyWith(
                  scaffoldBackgroundColor: punch,
                  canvasColor: punch,
                )
              : light,
          darkTheme: beacon
              ? dark.copyWith(
                  scaffoldBackgroundColor: punch,
                  canvasColor: punch,
                )
              : dark,
          builder: (context, child) {
            final page = child ?? const SizedBox.shrink();
            if (!isPhoneSurface) return page;
            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                widget.controller.handleSystemBack();
              },
              child: page,
            );
          },
          home: beacon
              ? ColoredBox(
                  color: PanelWindow.beaconPunch,
                  child: AirGrabTargetGlow(
                    locked: AirGrabSession.instance.catchLocked,
                  ),
                )
              : Scaffold(
                  backgroundColor: kSettingsPageBackground,
                  body: OneDropPanel(
                    controller: widget.controller,
                    onQuit: isDesktopTray ? quitOneDrop : null,
                    versionLabel: kAppVersion,
                  ),
                ),
        );
      },
    );
  }
}
