import 'dart:async';
import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/autostart.dart';
import '../core/drop_controller.dart';
import '../core/drop_prefs.dart';
import '../core/panel_window.dart';
import '../screens/file_explorer_screen.dart';
import '../screens/nearby_debug_screen.dart';
import '../services/air_grab_session.dart';
import '../services/drop_service.dart';
import '../services/file_explorer_service.dart';

class PhoneSettingsView extends StatefulWidget {
  const PhoneSettingsView({
    super.key,
    required this.controller,
    this.versionLabel,
  });

  final DropController controller;
  final String? versionLabel;

  @override
  State<PhoneSettingsView> createState() => _PhoneSettingsViewState();
}

class _PhoneSettingsViewState extends State<PhoneSettingsView> {
  late DropAcceptMode _mode;
  late final TextEditingController _name;
  bool _launch = false;
  bool _airGrab = false;
  bool _imagesToCameraRoll = true;

  @override
  void initState() {
    super.initState();
    _mode = DropPrefs.dropAcceptMode;
    _name = TextEditingController(text: DropPrefs.dropDisplayName);
    _airGrab = DropPrefs.airGrabEnabled;
    _imagesToCameraRoll = DropPrefs.imagesToCameraRoll;
    unawaited(_loadLaunch());
  }

  Future<void> _loadLaunch() async {
    final enabled = await Autostart.isEnabled();
    if (!mounted) return;
    setState(() => _launch = enabled);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _saveName(String value) async {
    await DropPrefs.setDropDisplayName(value);
    DropService.instance.announceNow();
    widget.controller.refresh();
  }

  Future<void> _chooseInbox() async {
    PanelWindow.busy = true;
    try {
      String? picked;
      if (fileExplorerSupported) {
        picked = await pickFileExplorerFolder(
          context,
          title: 'Folder for files',
          initialPath: DropPrefs.inboxPath,
        );
      } else {
        picked = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Folder for files',
          initialDirectory: DropPrefs.inboxPath,
        );
      }
      if (picked == null || picked.trim().isEmpty) return;
      await DropPrefs.setInboxPath(picked);
      if (mounted) setState(() {});
    } finally {
      PanelWindow.busy =
          widget.controller.incoming != null || widget.controller.transferring;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Nearby',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                onPressed: widget.controller.closeSettings,
              ),
              Expanded(
                child: Text(
                  'Settings',
                  style: AmlTheme.ui(
                    TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                      letterSpacing: -0.4,
                      color: ink,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            children: [
              SettingsAboutHero(
                productName: 'OneDrop',
                versionLabel: widget.versionLabel ?? '',
                semanticsLabel: 'OneDrop',
              ),
              const SizedBox(height: 20),
              SettingsSection(
                title: 'This device',
                child: SettingsSurface(
                  borderRadius: 24,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: TextField(
                    controller: _name,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: ink,
                    ),
                    textInputAction: TextInputAction.done,
                    maxLength: 32,
                    onSubmitted: _saveName,
                    onEditingComplete: () => _saveName(_name.text),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: 'Name nearby devices see',
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AmlTheme.mutedOf(context),
                      ),
                      counterText: '',
                      filled: true,
                      fillColor: AmlTheme.fieldOf(context),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              SettingsSection(
                title: 'Who can send',
                child: SettingsChoicePicker<DropAcceptMode>(
                  accent: AmlTheme.sky,
                  selected: _mode,
                  onSelected: (value) async {
                    await DropPrefs.setDropAcceptMode(value);
                    setState(() => _mode = value);
                  },
                  choices: const [
                    SettingsChoice(
                      value: DropAcceptMode.ask,
                      label: 'Ask',
                      icon: Icons.front_hand_rounded,
                    ),
                    SettingsChoice(
                      value: DropAcceptMode.known,
                      label: 'Known',
                      icon: Icons.people_alt_rounded,
                    ),
                    SettingsChoice(
                      value: DropAcceptMode.everyone,
                      label: 'Everyone',
                      icon: Icons.public_rounded,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _mode == DropAcceptMode.everyone
                    ? 'Anyone nearby can send into this folder.'
                    : _mode == DropAcceptMode.known
                        ? 'Auto-accept from devices you have already received.'
                        : 'Confirm every incoming One Drop.',
                style: TextStyle(
                  color: AmlTheme.mutedOf(context),
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 22),
              if (DropPrefs.airGrabAvailable)
                SettingsSection(
                  title: 'AirGrab',
                  child: SettingsCard(
                    children: [
                      SettingsSwitchTile(
                        secondary: settingsPastelIcon(
                          Icons.front_hand_rounded,
                          'airgrab',
                        ),
                        title: const Text('Grab toward this screen'),
                        subtitle:
                            'A white glow marks the surface that can receive.',
                        value: _airGrab,
                        onChanged: (value) async {
                          await AirGrabSession.instance.setEnabled(value);
                          setState(() => _airGrab = value);
                        },
                      ),
                    ],
                  ),
                )
              else
                SettingsSection(
                  title: 'How it finds devices',
                  child: SettingsSurface(
                    borderRadius: 24,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        settingsPastelIcon(Icons.bluetooth_rounded, 'radio'),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Bluetooth finds nearby phones and computers even when they are not on the same Wi‑Fi.',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              height: 1.4,
                              color: AmlTheme.inkOf(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (Autostart.available) ...[
                const SizedBox(height: 22),
                SettingsSection(
                  title: 'Startup',
                  child: SettingsCard(
                    children: [
                      SettingsSwitchTile(
                        secondary: settingsPastelIcon(
                          Icons.power_settings_new_rounded,
                          'launch',
                        ),
                        title: const Text('Start with the system'),
                        subtitle: 'Open OneDrop when you sign in.',
                        value: _launch,
                        onChanged: (value) async {
                          await Autostart.setEnabled(value);
                          setState(() => _launch = value);
                        },
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              SettingsSection(
                title: 'Received files',
                child: SettingsCard(
                  children: [
                    SettingsNavTile(
                      icon: Icons.folder_rounded,
                      title: 'Folder for files',
                      subtitle: DropPrefs.inboxShortLabel,
                      showChevron: true,
                      onTap: _chooseInbox,
                    ),
                    SettingsNavTile(
                      icon: Icons.bluetooth_searching_rounded,
                      title: 'Nearby debug',
                      subtitle: 'Bluetooth, Wi‑Fi, and why a device is missing',
                      showChevron: true,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const NearbyDebugScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 22),
                SettingsSection(
                  title: 'Incoming photos and videos',
                  child: SettingsChoicePicker<bool>(
                    accent: AmlTheme.sky,
                    selected: _imagesToCameraRoll,
                    onSelected: (value) async {
                      await DropPrefs.setImagesToCameraRoll(value);
                      setState(() => _imagesToCameraRoll = value);
                    },
                    choices: const [
                      SettingsChoice(
                        value: false,
                        label: 'OneDrop folder',
                        icon: Icons.folder_rounded,
                      ),
                      SettingsChoice(
                        value: true,
                        label: 'Camera roll',
                        icon: Icons.photo_camera_rounded,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _imagesToCameraRoll
                      ? 'Same folder as photos you take with this phone.'
                      : 'Incoming pictures go in Pictures/OneDrop.',
                  style: TextStyle(
                    color: AmlTheme.mutedOf(context),
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
