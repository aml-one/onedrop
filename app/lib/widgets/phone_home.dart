import 'dart:async';
import 'dart:math' as math;

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../core/drop_controller.dart';
import '../core/drop_prefs.dart';
import '../core/labels.dart';
import '../core/panel_window.dart';
import '../screens/file_explorer_screen.dart';
import '../screens/photo_picker_screen.dart';
import '../services/drop_service.dart';

/// Full-screen nearby stage for the phone — a drop well with orbiting peers.
class PhoneNearbyStage extends StatelessWidget {
  const PhoneNearbyStage({super.key, required this.controller});

  final DropController controller;

  Future<void> _queue(
    BuildContext context,
    Future<List<String>?> Function(BuildContext) pick,
  ) async {
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

  Future<void> _sendOrPick(BuildContext context, DropPeer peer) async {
    if (controller.pending.isEmpty) {
      await _pickPhotos(context);
      if (controller.pending.isNotEmpty) {
        unawaited(controller.sendTo(peer));
      }
      return;
    }
    unawaited(controller.sendTo(peer));
  }

  @override
  Widget build(BuildContext context) {
    final pending = controller.pending;
    final peers = controller.peers;
    final error = DropService.instance.lastError != null;
    return Column(
      children: [
        _PhoneTopBar(controller: controller),
        Expanded(
          child: error
              ? const _PhoneListenError()
              : _DropConstellation(
                  peers: peers,
                  pending: pending.isNotEmpty,
                  onPeer: (peer) => unawaited(_sendOrPick(context, peer)),
                  onWellTap: pending.isEmpty
                      ? () => unawaited(_pickPhotos(context))
                      : null,
                ),
        ),
        if (pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: _ReadyChip(
              files: pending,
              onClear: controller.clearSend,
              onPreview: controller.previewPending,
              onArm: DropPrefs.airGrabEnabled ? controller.armAirGrab : null,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: pending.isEmpty
              ? Row(
                  children: [
                    Expanded(
                      child: _DockTile(
                        label: 'Media files',
                        hint: 'Camera roll',
                        icon: Icons.photo_library_rounded,
                        pastelKey: 'photos',
                        accent: AmlTheme.pink,
                        onTap: () => unawaited(_pickPhotos(context)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _DockTile(
                        label: 'Files',
                        hint: 'Any document',
                        icon: Icons.folder_rounded,
                        pastelKey: 'files',
                        accent: AmlTheme.amber,
                        onTap: () => unawaited(_pickFiles(context)),
                      ),
                    ),
                  ],
                )
              : _DockTile(
                  label: 'Tap a device above',
                  hint: dropOutgoingPayload(pending),
                  icon: Icons.near_me_rounded,
                  pastelKey: 'choose',
                  accent: AmlTheme.sky,
                  onTap: null,
                ),
        ),
      ],
    );
  }
}

class _PhoneTopBar extends StatelessWidget {
  const _PhoneTopBar({required this.controller});

  final DropController controller;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
      child: Row(
        children: [
          const _DropMark(size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'One Drop',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    height: 1.05,
                    letterSpacing: -0.5,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const _LiveDot(),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        DropPrefs.dropDisplayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (controller.pending.isNotEmpty && DropPrefs.airGrabEnabled)
            _RoundHit(
              tooltip: 'Arm air grab',
              icon: Icons.front_hand_rounded,
              onTap: controller.armAirGrab,
            ),
          _RoundHit(
            tooltip: 'Settings',
            icon: Icons.settings_rounded,
            onTap: controller.openSettings,
          ),
        ],
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AmlTheme.mint,
          boxShadow: [
            BoxShadow(
              color: AmlTheme.mint.withValues(alpha: 0.55),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}

class _DropMark extends StatelessWidget {
  const _DropMark({this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AmlTheme.sky.withValues(alpha: 0.32),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
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

class _RoundHit extends StatelessWidget {
  const _RoundHit({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.88),
        shape: const CircleBorder(),
        elevation: 1,
        shadowColor: AmlTheme.violet.withValues(alpha: 0.18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, size: 22, color: AmlTheme.inkOf(context)),
          ),
        ),
      ),
    );
  }
}

class _PhoneListenError extends StatelessWidget {
  const _PhoneListenError();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: 48, color: AmlTheme.pink),
          const SizedBox(height: 16),
          Text(
            'One Drop couldn’t open on this Wi‑Fi',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: AmlTheme.inkOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Close another OneDrop on this device, then restart.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              height: 1.4,
              color: AmlTheme.mutedOf(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropConstellation extends StatefulWidget {
  const _DropConstellation({
    required this.peers,
    required this.pending,
    required this.onPeer,
    this.onWellTap,
  });

  final List<DropPeer> peers;
  final bool pending;
  final ValueChanged<DropPeer> onPeer;
  final VoidCallback? onWellTap;

  @override
  State<_DropConstellation> createState() => _DropConstellationState();
}

class _DropConstellationState extends State<_DropConstellation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.peers.take(6).toList(growable: false);
    final extra = widget.peers.length - peers.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final cx = w / 2;
        final cy = h * 0.46;
        final ring = math.min(w, h) * 0.36;
        final well = math.min(56.0, math.min(w, h) * 0.16);
        final origin = Offset(cx, cy);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _FieldPainter(
                        t: _pulse.value,
                        origin: origin,
                        well: well,
                      ),
                    );
                  },
                ),
              ),
            ),
            for (var i = 0; i < peers.length; i++)
              _orbitPeer(peers[i], i, peers.length, origin, ring),
            Positioned(
              left: cx - well / 2,
              top: cy - well / 2,
              width: well,
              height: well,
              child: _DropWell(
                size: well,
                searching: peers.isEmpty,
                pending: widget.pending,
                onTap: widget.onWellTap,
              ),
            ),
            if (peers.isEmpty)
              Positioned(
                left: 28,
                right: 28,
                bottom: 8,
                child: Text(
                  'Keep OneDrop open on the other phone or PC. Bluetooth finds it even without the same Wi‑Fi.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    height: 1.4,
                    color: AmlTheme.mutedOf(context),
                  ),
                ),
              )
            else
              Positioned(
                left: 20,
                right: 20,
                bottom: 20,
                child: Text(
                  extra > 0
                      ? '${widget.peers.length} nearby · tap one to send'
                      : widget.pending
                          ? 'Tap a device to send'
                          : 'Tap a device — or tap the droplet to pick media files',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AmlTheme.mutedOf(context),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _orbitPeer(
    DropPeer peer,
    int index,
    int count,
    Offset origin,
    double ring,
  ) {
    final sweep = math.pi * 1.55;
    final start = -math.pi * 0.78 - math.pi / 2;
    final angle =
        start + (count == 1 ? sweep / 2 : index * sweep / (count - 1));
    final x = origin.dx + math.cos(angle) * ring;
    final y = origin.dy + math.sin(angle) * ring;
    return Positioned(
      left: x - 40,
      top: y - 48,
      child: _OrbitPeer(
        peer: peer,
        known: DropPrefs.isKnownPeer(peer.id),
        onTap: () => widget.onPeer(peer),
      ),
    );
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter({
    required this.t,
    required this.origin,
    required this.well,
  });

  final double t;
  final Offset origin;
  final double well;

  static const _wave = Color.fromRGBO(210, 230, 255, 1);

  @override
  void paint(Canvas canvas, Size size) {
    final maxR = math.min(size.width, size.height) * 0.46;
    final inner = well * 0.42;
    canvas.drawCircle(
      origin,
      well * 0.78,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AmlTheme.sky.withValues(alpha: 0.16),
            AmlTheme.sky.withValues(alpha: 0),
          ],
        ).createShader(
          Rect.fromCircle(center: origin, radius: well * 1.1),
        ),
    );
    for (var i = 0; i < 5; i++) {
      final local = (t + i / 5) % 1.0;
      final fade = (1.0 - local).clamp(0.0, 1.0);
      if (fade <= 0) continue;
      final radius = inner + local * (maxR - inner);
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (2.4 - i * 0.25).clamp(1.0, 2.4)
          ..color = _wave.withValues(alpha: fade * 0.55),
      );
    }
    const seeds = [
      (0.12, 0.22, 3.0),
      (0.84, 0.18, 2.4),
      (0.18, 0.72, 2.8),
      (0.78, 0.68, 2.2),
      (0.08, 0.48, 2.0),
      (0.92, 0.42, 2.6),
      (0.32, 0.12, 1.8),
      (0.62, 0.86, 2.1),
    ];
    for (var i = 0; i < seeds.length; i++) {
      final seed = seeds[i];
      final bob = math.sin((t + i * 0.13) * math.pi * 2) * 6;
      final p = Offset(seed.$1 * size.width, seed.$2 * size.height + bob);
      canvas.drawCircle(
        p,
        seed.$3,
        Paint()
          ..color = Color.lerp(
            AmlTheme.sky,
            AmlTheme.violet,
            (i % 3) / 2,
          )!
              .withValues(alpha: 0.28),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FieldPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.origin != origin ||
      oldDelegate.well != well;
}

class _DropWell extends StatelessWidget {
  const _DropWell({
    required this.size,
    required this.searching,
    required this.pending,
    this.onTap,
  });

  final double size;
  final bool searching;
  final bool pending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final glyph = searching
        ? Center(child: BirdLoader(size: size * 0.72))
        : pending
            ? Icon(
                Icons.unarchive_rounded,
                size: size * 0.52,
                color: AmlTheme.sky,
              )
            : CustomPaint(
                size: Size.square(size),
                painter: const _GlassyDropPainter(),
              );
    final child = SizedBox(
      width: size,
      height: size,
      child: glyph,
    );
    if (onTap == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: child,
      ),
    );
  }
}

/// Family teardrop (same cubics as the icon generator) with a glass fill.
class _GlassyDropPainter extends CustomPainter {
  const _GlassyDropPainter();

  static Path _drop(Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.54;
    final s = math.min(size.width, size.height) * 0.36;
    final tip = Offset(cx, cy - s * 1.08);
    final left = Offset(cx - s * 0.70, cy + s * 0.18);
    final bottom = Offset(cx, cy + s * 0.98);
    final right = Offset(cx + s * 0.70, cy + s * 0.18);
    return Path()
      ..moveTo(tip.dx, tip.dy)
      ..cubicTo(
        cx - s * 0.18,
        cy - s * 0.55,
        left.dx,
        left.dy - s * 0.45,
        left.dx,
        left.dy,
      )
      ..cubicTo(
        left.dx - s * 0.04,
        left.dy + s * 0.42,
        cx - s * 0.42,
        bottom.dy,
        bottom.dx,
        bottom.dy,
      )
      ..cubicTo(
        cx + s * 0.42,
        bottom.dy,
        right.dx + s * 0.04,
        right.dy + s * 0.42,
        right.dx,
        right.dy,
      )
      ..cubicTo(
        right.dx,
        right.dy - s * 0.45,
        cx + s * 0.18,
        cy - s * 0.55,
        tip.dx,
        tip.dy,
      )
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    var path = _drop(size);
    final raw = path.getBounds();
    path = path.shift(Offset(size.width / 2, size.height / 2) - raw.center);
    final bounds = path.getBounds();
    canvas.drawPath(
      path,
      Paint()
        ..color = AmlTheme.sky.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xE6FFFFFF),
            Color(0xB38EC8F4),
            Color(0xCC6FB1F0),
            Color(0xD44A8FD4),
          ],
          stops: [0.0, 0.32, 0.62, 1.0],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      Offset(
        bounds.left + bounds.width * 0.34,
        bounds.top + bounds.height * 0.32,
      ),
      bounds.width * 0.28,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.78),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(
          Rect.fromCircle(
            center: Offset(
              bounds.left + bounds.width * 0.34,
              bounds.top + bounds.height * 0.32,
            ),
            radius: bounds.width * 0.28,
          ),
        ),
    );
    canvas.restore();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.62),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _OrbitPeer extends StatelessWidget {
  const _OrbitPeer({
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
    return SizedBox(
      width: 80,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(Colors.white, accent, 0.22)!,
                        accent,
                      ],
                    ),
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.36),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 16,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        dropDeviceTypeLabel(peer),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          height: 1,
                          letterSpacing: 0.2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                peer.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  color: AmlTheme.inkOf(context),
                ),
              ),
              Text(
                known ? 'Known' : (peer.viaRadio ? 'Nearby' : 'Wi‑Fi'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                  color: AmlTheme.mutedOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadyChip extends StatelessWidget {
  const _ReadyChip({
    required this.files,
    required this.onClear,
    this.onPreview,
    this.onArm,
  });

  final List<DropOutgoing> files;
  final VoidCallback onClear;
  final VoidCallback? onPreview;
  final VoidCallback? onArm;

  @override
  Widget build(BuildContext context) {
    final payload = dropOutgoingPayload(files);
    return SettingsSurface(
      borderRadius: 22,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          settingsPastelIcon(Icons.collections_rounded, 'ready'),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onPreview,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ready to send',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AmlTheme.inkOf(context),
                      ),
                    ),
                    Text(
                      payload,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AmlTheme.mutedOf(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onArm != null)
            IconButton(
              tooltip: 'Arm air grab',
              onPressed: onArm,
              icon: Icon(Icons.front_hand_rounded, color: AmlTheme.violet),
            ),
          IconButton(
            tooltip: 'Clear',
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _DockTile extends StatelessWidget {
  const _DockTile({
    required this.label,
    required this.hint,
    required this.icon,
    required this.pastelKey,
    required this.accent,
    this.onTap,
  });

  final String label;
  final String hint;
  final IconData icon;
  final String pastelKey;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SettingsSurface(
      borderRadius: 24,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            height: 108,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  settingsPastelIcon(icon, pastelKey, iconColor: accent),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: onTap == null
                          ? AmlTheme.mutedOf(context)
                          : AmlTheme.inkOf(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: AmlTheme.mutedOf(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
