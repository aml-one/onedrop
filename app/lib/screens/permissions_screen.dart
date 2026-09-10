import 'dart:async';
import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../core/device_channel.dart';
import '../services/drop_debug_log.dart';
import '../services/drop_service.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  List<DropPermissionRow> _rows = const [];
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reload());
  }

  Future<void> _reload() async {
    final rows = await DeviceChannel.listPermissions();
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _tap(DropPermissionRow row) async {
    if (_busy || row.action == 'none') return;
    setState(() {
      _busy = true;
      _status = null;
    });
    DropDebugLog.event('perm', row.id);
    try {
      if (row.action == 'ask' ||
          row.id == 'location' ||
          row.id == 'bluetooth' ||
          row.id == 'overlay' ||
          row.id == 'battery') {
        await DeviceChannel.requestPermission(row.id);
      } else {
        await DeviceChannel.openAppSettings();
      }
      if (row.id == 'nearby' || row.id == 'all') {
        unawaited(DropService.instance.restartRadio());
      }
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _allowMissing() async {
    if (_busy) return;
    final missing = _rows.where((row) => row.canAsk).toList();
    if (missing.isEmpty) {
      setState(() => _status = 'Nothing left to ask here. Use system Settings.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    DropDebugLog.event('perm', 'all');
    try {
      await DeviceChannel.requestPermission('all');
      unawaited(DropService.instance.restartRadio());
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData _icon(String id) {
    return switch (id) {
      'nearby' => Icons.bluetooth_searching_rounded,
      'location' => Icons.location_on_rounded,
      'bluetooth' => Icons.bluetooth_rounded,
      'camera' => Icons.photo_camera_rounded,
      'photos' => Icons.photo_library_rounded,
      'notifications' => Icons.notifications_rounded,
      'overlay' => Icons.layers_rounded,
      'battery' => Icons.battery_charging_full_rounded,
      _ => Icons.shield_rounded,
    };
  }

  String _trailing(DropPermissionRow row) {
    if (row.granted) return 'On';
    if (row.canAsk) return 'Allow';
    return 'Settings';
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return Scaffold(
      backgroundColor: AmlTheme.isDark(context)
          ? AmlTheme.darkBg
          : kSettingsPageBackground,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      'Permissions',
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
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                children: [
                  Text(
                    Platform.isAndroid
                        ? 'Nearby needs Bluetooth (and Location on Android 11). Tap a row to ask again, or open system Settings if the sheet no longer appears.'
                        : 'This computer does not need extra Nearby permissions.',
                    style: AmlTheme.ui(
                      TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        height: 1.35,
                        color: muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_rows.isEmpty)
                    SettingsSurface(
                      borderRadius: 24,
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        Platform.isAndroid
                            ? 'Reading permissions…'
                            : 'Nothing to allow on this device.',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: muted,
                        ),
                      ),
                    )
                  else
                    SettingsCard(
                      children: [
                        for (final row in _rows)
                          SettingsNavTile(
                            icon: _icon(row.id),
                            title: row.title,
                            subtitle: '${row.subtitle} · ${_trailing(row)}',
                            showChevron: row.action != 'none',
                            onTap: row.action == 'none'
                                ? null
                                : () => unawaited(_tap(row)),
                          ),
                      ],
                    ),
                  if (_rows.any((row) => row.canAsk)) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _allowMissing,
                      child: Text(_busy ? 'Asking…' : 'Allow missing'),
                    ),
                  ],
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _status!,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
