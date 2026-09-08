import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/drop_debug.dart';

class NearbyDebugScreen extends StatefulWidget {
  const NearbyDebugScreen({super.key});

  @override
  State<NearbyDebugScreen> createState() => _NearbyDebugScreenState();
}

class _NearbyDebugScreenState extends State<NearbyDebugScreen> {
  String _text = 'Collecting…';
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final snapshot = await oneDropDebugSnapshot();
    if (!mounted) return;
    setState(() => _text = oneDropDebugText(snapshot));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    setState(() => _status = 'Copied. Send it from another app if upload fails.');
  }

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final id = await uploadOneDropDebug();
      if (!mounted) return;
      setState(() => _status = 'Uploaded as $id');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Upload failed. Copy the log instead.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    return Scaffold(
      backgroundColor: kSettingsPageBackground,
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
                      'Nearby debug',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                'No file contents. Device names, Bluetooth, and Wi‑Fi only.',
                style: AmlTheme.ui(
                  TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    height: 1.35,
                    color: AmlTheme.mutedOf(context),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SettingsSurface(
                  borderRadius: 20,
                  padding: const EdgeInsets.all(14),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _text,
                      style: AmlTheme.ui(
                        TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Text(
                  _status!,
                  style: AmlTheme.ui(
                    TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AmlTheme.mutedOf(context),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _copy,
                      child: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _upload,
                      child: Text(_busy ? 'Uploading…' : 'Upload'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
