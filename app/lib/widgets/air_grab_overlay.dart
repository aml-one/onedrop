import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../services/air_grab_session.dart';

class AirGrabOverlay extends StatelessWidget {
  const AirGrabOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AirGrabSession.instance,
      builder: (context, _) {
        final session = AirGrabSession.instance;
        if (session.hud == AirGrabHud.hidden ||
            session.hud == AirGrabHud.catchPrompt) {
          return const SizedBox.shrink();
        }
        return Positioned(
          left: 12,
          right: 12,
          top: 48,
          child: _Card(session: session),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.session});

  final AirGrabSession session;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return Material(
      color: Colors.white.withValues(alpha: 0.96),
      elevation: 6,
      shadowColor: AmlTheme.violet.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              session.hud == AirGrabHud.holding
                  ? Icons.back_hand_rounded
                  : Icons.front_hand_rounded,
              size: 22,
              color: session.hud == AirGrabHud.holding
                  ? AmlTheme.violet
                  : AmlTheme.sky,
            ),
            const SizedBox(height: 4),
            Text(
              _title(session),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: ink,
              ),
            ),
            if (session.hud == AirGrabHud.holding) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: session.cancelGrab,
                style: TextButton.styleFrom(
                  minimumSize: const Size(72, 36),
                  foregroundColor: muted,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ],
            if (session.hud == AirGrabHud.sending) ...[
              if (session.sendProgress != null) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: session.sendProgress!.fraction,
                  color: AmlTheme.sky,
                ),
              ],
              TextButton(
                onPressed: session.cancelGrab,
                style: TextButton.styleFrom(
                  minimumSize: const Size(72, 36),
                  foregroundColor: muted,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
            ],
            if (session.hud == AirGrabHud.pick) ...[
              const SizedBox(height: 8),
              for (final peer in session.pickPeers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: const Color(0xFFE8F2FE),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () => session.pick(peer),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.devices_rounded,
                              size: 16,
                              color: AmlTheme.sky,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                peer.name,
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
                  ),
                ),
              TextButton(
                onPressed: session.cancelGrab,
                child: Text(
                  'Cancel',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _title(AirGrabSession session) {
    switch (session.hud) {
      case AirGrabHud.palm:
        return 'Close your hand to grab';
      case AirGrabHud.holding:
        final n = session.queue.length;
        final hold = n == 1 ? 'Holding 1 file' : 'Holding $n files';
        if (session.facingName.isEmpty) {
          return '$hold — open your palm here to cancel';
        }
        if (session.facingCatch) {
          return '$hold — open toward ${session.facingName}, or palm here to cancel';
        }
        return '$hold — leave the camera to send to ${session.facingName}, or palm here to cancel';
      case AirGrabHud.catchPrompt:
        return '';
      case AirGrabHud.pick:
        return 'Drop to';
      case AirGrabHud.sending:
        return session.status;
      case AirGrabHud.hidden:
        return '';
    }
  }
}
