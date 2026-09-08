import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_version.dart';
import 'core/autostart.dart';
import 'core/drop_controller.dart';
import 'core/drop_prefs.dart';
import 'core/host.dart';
import 'core/labels.dart';
import 'core/nearby_motion.dart';
import 'core/panel_window.dart';
import 'screens/file_explorer_screen.dart';
import 'screens/photo_picker_screen.dart';
import 'services/air_grab_session.dart';
import 'services/drop_service.dart';
import 'widgets/air_grab_overlay.dart';
import 'widgets/media_quick_preview.dart';
import 'widgets/phone_home.dart';
import 'widgets/phone_settings.dart';

class OneDropPanel extends StatelessWidget {
  const OneDropPanel({
    super.key,
    required this.controller,
    this.onQuit,
    this.versionLabel,
  });

  final DropController controller;
  final Future<void> Function()? onQuit;
  final String? versionLabel;

  @override
  Widget build(BuildContext context) {
    // PopScope must sit *outside* the controller rebuild. Closing Settings
    // notifyListeners() used to recreate it mid-back-swipe, and HyperOS
    // finished the activity instead of returning to Home.
    return _trapPhoneBack(
      controller,
      AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: kSettingsPageBackground,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: kSettingsPageBackground,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return DropTarget(
            onDragDone: (detail) {
              final paths = [
                for (final file in detail.files)
                  if (file.path.isNotEmpty) file.path,
              ];
              controller.queue(outgoingFromPaths(paths));
            },
            child: Material(
            color: controller.previewPaths != null
                ? const Color(0xFF0C0A14)
                : kSettingsPageBackground,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (controller.previewPaths != null)
                  MediaQuickPreview(
                    paths: controller.previewPaths!,
                    title: controller.previewTitle,
                    onClose: controller.closePreview,
                  )
                else ...[
                  const RepaintBoundary(child: SettingsAmbientBackground()),
                  ColoredBox(
                    color: kSettingsPageBackground.withValues(alpha: 0.88),
                    child: isPhoneSurface
                          ? SafeArea(
                              child: Column(
                                children: [
                                  if (_showSharedHeader(controller))
                                    _Header(controller: controller),
                                  Expanded(
                                    child: _Body(
                                      controller: controller,
                                      onQuit: onQuit,
                                      versionLabel: versionLabel,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Column(
                              children: [
                                _Header(controller: controller),
                                Expanded(
                                  child: _Body(
                                    controller: controller,
                                    onQuit: onQuit,
                                    versionLabel: versionLabel,
                                  ),
                                ),
                              ],
                            ),
                  ),
                  const AirGrabOverlay(),
                ],
                if (controller.toast != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: _Toast(message: controller.toast!),
                  ),
              ],
            ),
          ),
          );
        },
      ),
      ),
    );
  }
}

bool _showSharedHeader(DropController controller) {
  return controller.incoming != null ||
      controller.receiveProgress != null ||
      controller.progress != null ||
      controller.outcome != null;
}

Widget _trapPhoneBack(DropController controller, Widget child) {
  if (!isPhoneSurface) return child;
  return PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      controller.handleSystemBack();
    },
    child: child,
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final DropController controller;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final phone = isPhoneSurface;
    final named = DropPrefs.dropDisplayName;
    final actions = [
      if (controller.pending.isNotEmpty && DropPrefs.airGrabEnabled)
        _IconHit(
          tooltip: 'Arm air grab',
          icon: Icons.front_hand_rounded,
          size: phone ? 48 : 28,
          onTap: controller.armAirGrab,
        ),
      _IconHit(
        tooltip: controller.settingsOpen ? 'Nearby' : 'Settings',
        icon: controller.settingsOpen
            ? Icons.near_me_rounded
            : Icons.settings_rounded,
        size: phone ? 48 : 28,
        onTap: () {
          if (controller.settingsOpen) {
            controller.closeSettings();
          } else {
            controller.openSettings();
          }
        },
      ),
    ];
    if (!phone) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 0),
        child: Row(children: [const Spacer(), ...actions]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 8),
      child: Row(
        children: [
          const _Mark(size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'One Drop',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    height: 1.05,
                    letterSpacing: -0.4,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  named,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: muted,
                  ),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _DeskBrand extends StatelessWidget {
  const _DeskBrand({this.versionLabel});

  final String? versionLabel;

  @override
  Widget build(BuildContext context) {
    final raw = (versionLabel == null || versionLabel!.isEmpty)
        ? kAppVersion
        : versionLabel!;
    final version = raw.startsWith('v') ? raw : 'v$raw';
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
      child: Column(
        children: [
          const _Mark(size: 40),
          const SizedBox(height: 10),
          Text(
            'OneDrop',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 1.1,
              letterSpacing: -0.3,
              color: ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            version,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size >= 48 ? 16.0 : 9.0;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: AmlTheme.sky.withValues(alpha: 0.28),
              blurRadius: size >= 48 ? 16 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.asset(
            'assets/icon/app_icon.png',
            width: size,
            height: size,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => ColoredBox(
              color: const Color(0xFFB4E0F4),
              child: Icon(
                Icons.water_drop_rounded,
                color: Colors.white,
                size: size * 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconHit extends StatelessWidget {
  const _IconHit({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.size = 28,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.82),
        shape: const CircleBorder(),
        elevation: size >= 44 ? 1 : 0,
        shadowColor: AmlTheme.violet.withValues(alpha: 0.18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: size >= 44 ? 22 : 15,
              color: AmlTheme.inkOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    this.onQuit,
    this.versionLabel,
  });

  final DropController controller;
  final Future<void> Function()? onQuit;
  final String? versionLabel;

  @override
  Widget build(BuildContext context) {
    final incoming = controller.incoming;
    if (incoming != null) {
      return _OfferView(controller: controller, offer: incoming);
    }
    if (controller.receiveProgress != null) {
      return _ReceiveView(
        controller: controller,
        progress: controller.receiveProgress!,
      );
    }
    if (controller.progress != null || controller.outcome != null) {
      return _SendView(controller: controller);
    }
    if (controller.settingsOpen) {
      if (isPhoneSurface) {
        return PhoneSettingsView(
          controller: controller,
          versionLabel: versionLabel,
        );
      }
      return _SettingsView(
        controller: controller,
        onQuit: onQuit,
        versionLabel: versionLabel,
      );
    }
    if (isPhoneSurface) {
      return PhoneNearbyStage(controller: controller);
    }
    return _NearbyView(controller: controller);
  }
}

class _NearbyView extends StatelessWidget {
  const _NearbyView({required this.controller});

  final DropController controller;

  Future<void> _queue(BuildContext context, Future<List<String>?> Function(BuildContext) pick) async {
    controller.picking = true;
    PanelWindow.busy = true;
    try {
      final paths = await pick(context);
      if (paths == null || paths.isEmpty) return;
      controller.queue(outgoingFromPaths(paths));
    } finally {
      controller.picking = false;
      PanelWindow.busy =
          controller.incoming != null || controller.transferring;
    }
  }

  Future<void> _pickPhotos(BuildContext context) =>
      _queue(context, pickPhotos);

  Future<void> _pickFiles(BuildContext context) =>
      _queue(context, (ctx) => pickFileExplorerFiles(ctx, allowMultiple: true));

  @override
  Widget build(BuildContext context) {
    final pending = controller.pending;
    final peers = controller.peers;
    final phone = isPhoneSurface;
    return Column(
      children: [
        if (pending.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(phone ? 20 : 16, 0, phone ? 20 : 16, 8),
            child: _QueuedBanner(
              files: pending,
              onClear: controller.clearSend,
              onArm: DropPrefs.airGrabEnabled ? controller.armAirGrab : null,
              onPreview: controller.previewPending,
            ),
          ),
        Expanded(
          child: DropService.instance.lastError != null
              ? const _ListenError()
              : peers.isEmpty
                  ? const _Searching()
                  : _PeerList(
                  peers: peers,
                  onTap: (peer) {
                    if (pending.isEmpty) {
                      unawaited(_pickPhotos(context).then((_) {
                        if (controller.pending.isNotEmpty) {
                          unawaited(controller.sendTo(peer));
                        }
                      }));
                    } else {
                      unawaited(controller.sendTo(peer));
                    }
                  },
                ),
        ),
        Padding(
          padding: phone
              ? const EdgeInsets.fromLTRB(20, 8, 20, 16)
              : const EdgeInsets.fromLTRB(14, 4, 14, 14),
          child: pending.isEmpty
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _SendButton(
                            label: 'Photos',
                            icon: Icons.photo_library_rounded,
                            pastelKey: 'photos',
                            onTap: () => unawaited(_pickPhotos(context)),
                          ),
                        ),
                        SizedBox(width: phone ? 12 : 8),
                        Expanded(
                          child: _SendButton(
                            label: 'Files',
                            icon: Icons.folder_rounded,
                            pastelKey: 'files',
                            onTap: () => unawaited(_pickFiles(context)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      height: 32,
                      child: OutlinedButton.icon(
                        onPressed: () => unawaited(DropInbox.open()),
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('Open folder'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AmlTheme.inkOf(context),
                          side: BorderSide(color: AmlTheme.strokeOf(context)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : _SendButton(
                  label: 'Choose a device',
                  icon: Icons.near_me_rounded,
                  pastelKey: 'choose',
                  onTap: null,
                ),
        ),
      ],
    );
  }
}

class _QueuedBanner extends StatelessWidget {
  const _QueuedBanner({
    required this.files,
    required this.onClear,
    this.onArm,
    this.onPreview,
  });

  final List<DropOutgoing> files;
  final VoidCallback onClear;
  final VoidCallback? onArm;
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final payload = dropOutgoingPayload(files);
    return SettingsSurface(
      borderRadius: 12,
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onPreview,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Icon(Icons.collections_rounded, size: 16, color: AmlTheme.pink),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Send $payload',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: AmlTheme.inkOf(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (onArm != null)
            IconButton(
              tooltip: 'Arm air grab',
              onPressed: onArm,
              icon: Icon(
                Icons.front_hand_rounded,
                size: 18,
                color: AmlTheme.violet,
              ),
            ),
          IconButton(
            tooltip: 'Clear',
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ListenError extends StatelessWidget {
  const _ListenError();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: 36, color: AmlTheme.pink),
          const SizedBox(height: 12),
          Text(
            'One Drop couldn’t open on this Wi‑Fi',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: AmlTheme.inkOf(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Close another OneDrop on this device, then restart.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              height: 1.35,
              color: AmlTheme.mutedOf(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    final phone = isPhoneSurface;
    return Column(
      children: [
        const Spacer(),
        _Radar(size: phone ? 168 : 88, bird: phone ? 56 : 32),
        SizedBox(height: phone ? 18 : 8),
        Text(
          'Looking nearby',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: phone ? 22 : 14,
            letterSpacing: -0.3,
            color: AmlTheme.inkOf(context),
          ),
        ),
        SizedBox(height: phone ? 8 : 4),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: phone ? 36 : 28),
          child: Text(
            phone
                ? 'Keep OneDrop open on the other phone or PC. Bluetooth finds it even without the same Wi‑Fi.'
                : 'Open OneDrop on the other device. Bluetooth finds it even without the same Wi‑Fi. Drop files here or tap Photos or Files.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: phone ? 15 : 12,
              height: 1.4,
              color: AmlTheme.mutedOf(context),
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }
}

class _Radar extends StatefulWidget {
  const _Radar({this.size = 88, this.bird = 32});

  final double size;
  final double bird;

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cheap = cheapNearbyMotion(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            return CustomPaint(
              painter: _RadarPainter(
                t: cheap ? (_pulse.value * 12).floor() / 12 : _pulse.value,
                cheap: cheap,
              ),
              child: child,
            );
          },
          child: Center(child: BirdLoader(size: widget.bird)),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.t, required this.cheap});

  final double t;
  final bool cheap;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.shortestSide / 2;
    final rings = cheap ? 2 : 3;
    final step = cheap ? (t * 12).floor() / 12 : t;
    for (var i = 0; i < rings; i++) {
      final local = (step + i / rings) % 1.0;
      final radius = 22 + local * (maxR - 22);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = cheap ? 1.4 : 2
        ..color = AmlTheme.sky.withValues(alpha: (1 - local) * 0.42);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.cheap != cheap;
}

class _PeerList extends StatelessWidget {
  const _PeerList({required this.peers, required this.onTap});

  final List<DropPeer> peers;
  final ValueChanged<DropPeer> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        isPhoneSurface ? 20 : 14,
        isPhoneSurface ? 8 : 0,
        isPhoneSurface ? 20 : 14,
        8,
      ),
      itemCount: peers.length,
      separatorBuilder: (_, _) => SizedBox(height: isPhoneSurface ? 12 : 6),
      itemBuilder: (context, index) {
        final peer = peers[index];
        return _PeerRow(
          peer: peer,
          known: DropPrefs.isKnownPeer(peer.id),
          onTap: () => onTap(peer),
        );
      },
    );
  }
}

class _PeerRow extends StatelessWidget {
  const _PeerRow({
    required this.peer,
    required this.known,
    required this.onTap,
  });

  final DropPeer peer;
  final bool known;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const accents = [
      AmlTheme.sky,
      AmlTheme.mint,
      AmlTheme.pink,
      AmlTheme.violet,
      AmlTheme.amber,
    ];
    final accent = accents[peer.id.hashCode.abs() % accents.length];
    final phone = isPhoneSurface;
    final avatar = phone ? 52.0 : 28.0;
    return Material(
      color: Colors.white.withValues(alpha: phone ? 0.94 : 0.82),
      elevation: phone ? 2 : 0,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(phone ? 22 : 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            phone ? 14 : 8,
            phone ? 14 : 6,
            phone ? 16 : 10,
            phone ? 14 : 6,
          ),
          child: Row(
            children: [
              SizedBox(
                width: avatar,
                height: avatar,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(Colors.white, accent, 0.25)!,
                        accent,
                      ],
                    ),
                    boxShadow: phone
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.28),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : const [],
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: phone ? 10 : 5,
                      vertical: phone ? 14 : 7,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        dropDeviceTypeLabel(peer),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: phone ? 12 : 10,
                          height: 1,
                          letterSpacing: 0.2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: phone ? 14 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: phone ? 18 : 13,
                        letterSpacing: -0.2,
                        color: AmlTheme.inkOf(context),
                      ),
                    ),
                    SizedBox(height: phone ? 3 : 0),
                    Text(
                      known ? 'Known' : (peer.viaRadio ? 'Nearby' : 'Wi‑Fi'),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: phone ? 13 : 11,
                        color: AmlTheme.mutedOf(context),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.north_east_rounded,
                size: phone ? 22 : 16,
                color: accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.label,
    required this.icon,
    required this.pastelKey,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final String pastelKey;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (isPhoneSurface) {
      return SettingsSurface(
        borderRadius: 22,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              height: 96,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  settingsPastelIcon(icon, pastelKey),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: onTap == null
                          ? AmlTheme.mutedOf(context)
                          : AmlTheme.inkOf(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: onTap == null
              ? [
                  AmlTheme.sky.withValues(alpha: 0.35),
                  AmlTheme.violet.withValues(alpha: 0.28),
                ]
              : const [Color(0xFF9ED4F0), AmlTheme.sky],
        ),
        boxShadow: [
          BoxShadow(
            color: AmlTheme.sky.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 34,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReceiveView extends StatelessWidget {
  const _ReceiveView({required this.controller, required this.progress});

  final DropController controller;
  final DropReceiveProgress progress;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final done = progress.done;
    final total = dropBytesLabel(progress.totalBytes);
    final got = dropBytesLabel(progress.receivedBytes);
    var subtitle = 'Photos and videos are on the way';
    if (got.isEmpty) {
      if (total.isNotEmpty) subtitle = total;
    } else {
      subtitle = '$got of $total';
    }
    final phone = isPhoneSurface;
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 24 : 16, 8, phone ? 24 : 16, 16),
      child: Column(
        children: [
          const Spacer(),
          if (done)
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AmlTheme.mint.withValues(alpha: 0.18),
              ),
              child: SizedBox(
                width: phone ? 96 : 72,
                height: phone ? 96 : 72,
                child: Icon(
                  Icons.check_rounded,
                  size: phone ? 44 : 32,
                  color: AmlTheme.mint,
                ),
              ),
            )
          else
            _ReceiveRing(fraction: progress.fraction, size: phone ? 96 : 72),
          SizedBox(height: phone ? 18 : 14),
          Text(
            done ? 'Received' : 'Receiving from ${progress.peerName}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: phone ? 22 : 15,
              height: 1.15,
              color: ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 1.35,
              color: muted,
            ),
          ),
          const Spacer(),
          if (done)
            FilledButton(
              onPressed: controller.clearReceive,
              style: FilledButton.styleFrom(
                backgroundColor: AmlTheme.mint,
                foregroundColor: Colors.white,
                minimumSize: Size.fromHeight(phone ? 52 : 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(phone ? 16 : 10),
                ),
              ),
              child: const Text('Done'),
            )
          else
            OutlinedButton(
              onPressed: controller.abortReceive,
              style: OutlinedButton.styleFrom(
                foregroundColor: ink,
                side: BorderSide(color: AmlTheme.strokeOf(context)),
                minimumSize: Size.fromHeight(phone ? 52 : 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(phone ? 16 : 10),
                ),
              ),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }
}

class _ReceiveRing extends StatelessWidget {
  const _ReceiveRing({required this.fraction, this.size = 72});

  final double fraction;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = fraction <= 0 ? 0.02 : fraction.clamp(0.02, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: size >= 90 ? 7 : 5,
              strokeCap: StrokeCap.round,
              backgroundColor: AmlTheme.fieldOf(context),
              color: AmlTheme.sky,
            ),
          ),
          Text(
            '${(fraction.clamp(0.0, 1.0) * 100).round()}%',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: size >= 90 ? 20 : 15,
              letterSpacing: -0.4,
              color: AmlTheme.sky,
            ),
          ),
        ],
      ),
    );
  }
}

class _OfferView extends StatelessWidget {
  const _OfferView({required this.controller, required this.offer});

  final DropController controller;
  final DropOffer offer;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final phone = isPhoneSurface;
    final avatar = phone ? 88.0 : 52.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 24 : 16, 4, phone ? 24 : 16, 16),
      child: Column(
        children: [
          const Spacer(),
          SizedBox(
            width: avatar,
            height: avatar,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(Colors.white, AmlTheme.pink, 0.2)!,
                    AmlTheme.sky,
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AmlTheme.sky.withValues(alpha: 0.32),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  dropInitial(offer.peerName),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: phone ? 32 : 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: phone ? 18 : 14),
          Text(
            '${offer.peerName} wants to send',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: phone ? 22 : 15,
              height: 1.15,
              color: ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            dropOfferSummary(offer),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: phone ? 16 : 13,
              color: muted,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => controller.decideIncoming(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ink,
                    side: BorderSide(color: AmlTheme.strokeOf(context)),
                    minimumSize: Size.fromHeight(phone ? 52 : 32),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(phone ? 16 : 10),
                    ),
                  ),
                  child: const Text('Decline'),
                ),
              ),
              SizedBox(width: phone ? 12 : 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => controller.decideIncoming(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AmlTheme.sky,
                    foregroundColor: Colors.white,
                    minimumSize: Size.fromHeight(phone ? 52 : 32),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(phone ? 16 : 10),
                    ),
                  ),
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SendView extends StatelessWidget {
  const _SendView({required this.controller});

  final DropController controller;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final outcome = controller.outcome;
    final progress = controller.progress;
    final waiting = outcome == null && progress?.phase != DropSendPhase.sending;
    final title = switch (outcome) {
      SendOutcome.ok => 'Sent',
      SendOutcome.declined => 'Declined',
      SendOutcome.failed => 'Couldn’t send',
      null => waiting
          ? 'Waiting for ${progress?.peerName ?? 'them'}'
          : (progress?.label ?? 'Sending'),
    };
    final failedCopy = outcome == SendOutcome.failed
        ? dropSendErrorCopy(controller.error)
        : null;
    final subtitle = switch (outcome) {
      SendOutcome.ok => progress?.label ?? 'On its way',
      SendOutcome.declined => 'They declined this One Drop',
      SendOutcome.failed => failedCopy!.message,
      null => waiting
          ? 'They need to accept on their device'
          : dropPayloadLabel(
              photos: controller.pending
                  .where((file) => file.kind != 'video')
                  .length,
              videos:
                  controller.pending.where((file) => file.kind == 'video').length,
            ),
    };
    final phone = isPhoneSurface;
    final detail = failedCopy?.detail;
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 24 : 16, 8, phone ? 24 : 16, 16),
      child: Column(
        children: [
          const Spacer(),
          _SendHero(outcome: outcome),
          SizedBox(height: phone ? 16 : 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: phone ? 22 : 15,
              color: ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: phone ? 16 : 13,
              height: 1.35,
              color: muted,
            ),
          ),
          if (outcome == null && progress?.phase == DropSendPhase.sending) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (progress?.fraction ?? 0) <= 0
                    ? 0.02
                    : progress!.fraction.clamp(0.02, 1),
                minHeight: phone ? 8 : 5,
                backgroundColor: Colors.white,
                color: AmlTheme.sky,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${((progress?.fraction ?? 0) * 100).round()}%',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: AmlTheme.sky,
              ),
            ),
          ],
          const Spacer(),
          if (outcome == null)
            OutlinedButton(
              onPressed: controller.abortSend,
              style: OutlinedButton.styleFrom(
                foregroundColor: ink,
                side: BorderSide(color: AmlTheme.strokeOf(context)),
                minimumSize: Size.fromHeight(phone ? 52 : 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(phone ? 16 : 10),
                ),
              ),
              child: const Text('Cancel'),
            )
          else ...[
            if (detail != null) ...[
              Text(
                detail,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: phone ? 11 : 10,
                  height: 1.3,
                  color: muted.withValues(alpha: 0.72),
                ),
              ),
              SizedBox(height: phone ? 10 : 8),
            ],
            FilledButton(
              onPressed: controller.clearSend,
              style: FilledButton.styleFrom(
                backgroundColor:
                    outcome == SendOutcome.ok ? AmlTheme.mint : AmlTheme.sky,
                foregroundColor: Colors.white,
                minimumSize: Size.fromHeight(phone ? 52 : 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(phone ? 16 : 10),
                ),
              ),
              child: Text(outcome == SendOutcome.ok ? 'Done' : 'Close'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SendHero extends StatelessWidget {
  const _SendHero({required this.outcome});

  final SendOutcome? outcome;

  @override
  Widget build(BuildContext context) {
    final phone = isPhoneSurface;
    final size = phone ? 72.0 : 48.0;
    final icon = phone ? 36.0 : 24.0;
    if (outcome == SendOutcome.ok) {
      return DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AmlTheme.mint.withValues(alpha: 0.18),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.check_rounded, size: icon, color: AmlTheme.mint),
        ),
      );
    }
    if (outcome == SendOutcome.declined || outcome == SendOutcome.failed) {
      return DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFE24B4A).withValues(alpha: 0.14),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.close_rounded, size: icon, color: const Color(0xFFE24B4A)),
        ),
      );
    }
    return BirdLoader(size: phone ? 56 : 40);
  }
}

class _SettingsView extends StatefulWidget {
  const _SettingsView({
    required this.controller,
    this.onQuit,
    this.versionLabel,
  });

  final DropController controller;
  final Future<void> Function()? onQuit;
  final String? versionLabel;

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  late DropAcceptMode _mode;
  late final TextEditingController _name;
  bool _launch = false;
  bool _airGrab = false;
  bool _openExplorer = false;

  @override
  void initState() {
    super.initState();
    _mode = DropPrefs.dropAcceptMode;
    _name = TextEditingController(text: DropPrefs.dropDisplayName);
    _airGrab = DropPrefs.airGrabEnabled;
    _openExplorer = DropPrefs.openExplorerOnReceive;
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

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: [
        _DeskBrand(versionLabel: widget.versionLabel),
        const SizedBox(height: 12),
        SettingsSurface(
          borderRadius: 12,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: ink,
                ),
                textInputAction: TextInputAction.done,
                maxLength: 32,
                onSubmitted: _saveName,
                onEditingComplete: () => _saveName(_name.text),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'This device',
                  labelStyle: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    color: muted,
                  ),
                  counterText: '',
                  filled: true,
                  fillColor: AmlTheme.fieldOf(context),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _DeskSegmented<DropAcceptMode>(
                selected: _mode,
                onSelected: (value) async {
                  await DropPrefs.setDropAcceptMode(value);
                  setState(() => _mode = value);
                },
                items: const [
                  (
                    value: DropAcceptMode.ask,
                    label: 'Ask',
                    icon: Icons.front_hand_rounded,
                  ),
                  (
                    value: DropAcceptMode.known,
                    label: 'Known',
                    icon: Icons.people_alt_rounded,
                  ),
                  (
                    value: DropAcceptMode.everyone,
                    label: 'Everyone',
                    icon: Icons.public_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _mode == DropAcceptMode.everyone
                    ? 'Anyone nearby can send into this folder.'
                    : _mode == DropAcceptMode.known
                        ? 'Auto-accept from devices you have already received.'
                        : 'Confirm every incoming One Drop.',
                style: TextStyle(
                  color: muted,
                  fontSize: 11,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              if (DropPrefs.airGrabAvailable) ...[
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      Icon(
                        Icons.front_hand_rounded,
                        size: 16,
                        color: AmlTheme.violet,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Use AirGrab for transfer…',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            color: ink,
                          ),
                        ),
                      ),
                      Transform.scale(
                        scale: 0.78,
                        child: Switch(
                          value: _airGrab,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (value) async {
                            await AirGrabSession.instance.setEnabled(value);
                            setState(() => _airGrab = value);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Turn on to grab toward this PC. A white glow marks the screen that can receive.',
                  style: TextStyle(
                    color: muted,
                    fontSize: 11,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ] else ...[
                Text(
                  'Same Wi-Fi send and receive. AirGrab camera catch is not on Linux yet.',
                  style: TextStyle(
                    color: muted,
                    fontSize: 11,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        SettingsSurface(
          borderRadius: 12,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: Column(
            children: [
              SizedBox(
                height: 32,
                child: Row(
                  children: [
                    Icon(
                      Icons.power_settings_new_rounded,
                      size: 16,
                      color: AmlTheme.mint,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Start with the system',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: ink,
                        ),
                      ),
                    ),
                    Transform.scale(
                      scale: 0.78,
                      child: Switch(
                        value: _launch,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (value) async {
                          await Autostart.setEnabled(value);
                          setState(() => _launch = value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 10,
                color: AmlTheme.strokeOf(context).withValues(alpha: 0.6),
              ),
              Row(
                children: [
                  Icon(
                    Icons.folder_rounded,
                    size: 16,
                    color: AmlTheme.amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Receive to',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            color: ink,
                          ),
                        ),
                        Text(
                          DropPrefs.inboxShortLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _DeskLink(label: 'Choose', onTap: _chooseInbox),
                  const SizedBox(width: 4),
                  _DeskLink(
                    label: 'Open',
                    onTap: () => unawaited(DropInbox.open()),
                  ),
                ],
              ),
              Divider(
                height: 10,
                color: AmlTheme.strokeOf(context).withValues(alpha: 0.6),
              ),
              Row(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: 16,
                    color: AmlTheme.sky,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Open File Explorer when receiving',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: ink,
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: 0.78,
                    child: Switch(
                      value: _openExplorer,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (value) async {
                        await DropPrefs.setOpenExplorerOnReceive(value);
                        setState(() => _openExplorer = value);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Opens once per drop, even if several files arrive.',
                style: TextStyle(
                  color: muted,
                  fontSize: 11,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.center,
          child: TextButton(
            onPressed: widget.onQuit == null
                ? null
                : () => unawaited(widget.onQuit!()),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Quit One Drop',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11.5,
                color: muted,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseInbox() async {
    PanelWindow.busy = true;
    try {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Receive files here',
        initialDirectory: DropPrefs.inboxPath,
      );
      if (picked == null || picked.trim().isEmpty) return;
      await DropPrefs.setInboxPath(picked);
      if (mounted) setState(() {});
    } finally {
      PanelWindow.busy =
          widget.controller.incoming != null || widget.controller.transferring;
    }
  }
}

class _DeskSegmented<T> extends StatelessWidget {
  const _DeskSegmented({
    required this.selected,
    required this.onSelected,
    required this.items,
  });

  final T selected;
  final ValueChanged<T> onSelected;
  final List<({T value, String label, IconData icon})> items;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AmlTheme.fieldOf(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            for (final item in items)
              Expanded(
                child: _DeskSegmentChip(
                  selected: item.value == selected,
                  label: item.label,
                  icon: item.icon,
                  onTap: () => onSelected(item.value),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeskSegmentChip extends StatelessWidget {
  const _DeskSegmentChip({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 28,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13,
                color: selected ? AmlTheme.sky : AmlTheme.mutedOf(context),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: selected ? ink : AmlTheme.mutedOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeskLink extends StatelessWidget {
  const _DeskLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
          color: AmlTheme.sky,
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.94),
      elevation: 8,
      shadowColor: AmlTheme.mint.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: AmlTheme.mint, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AmlTheme.inkOf(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
