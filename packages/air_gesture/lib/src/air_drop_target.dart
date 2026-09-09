import 'gaze_observation.dart';

enum AirPeerRole { phone, desktop, tablet }

enum AirPeerOs { android, windows, macos, linux, other }

class AirDropPeer {
  const AirDropPeer({
    required this.id,
    required this.name,
    required this.role,
    required this.os,
    required this.camera,
    this.attention = 0,
    this.seesHand = false,
  });

  final String id;
  final String name;
  final AirPeerRole role;
  final AirPeerOs os;
  final bool camera;

  /// 0–1, how strongly this peer's camera currently sees the user facing it.
  final double attention;

  /// This camera currently sees the sender's fist / hand.
  final bool seesHand;

  bool get isDesktop => role == AirPeerRole.desktop;

  bool get isWinMacDesktop =>
      isDesktop && (os == AirPeerOs.windows || os == AirPeerOs.macos);

  bool get noCameraDesktop => isDesktop && !camera;

  bool get canCatchDesktop => isDesktop && camera;
}

enum LeftFrameAction { none, autoSend, waitCatch, pickNoCamera, pickAllDesktops }

class LeftFrameDecision {
  const LeftFrameDecision({
    required this.action,
    this.target,
    this.choices = const [],
  });

  final LeftFrameAction action;
  final AirDropPeer? target;
  final List<AirDropPeer> choices;

  bool get dropsOnLeave =>
      action == LeftFrameAction.autoSend ||
      action == LeftFrameAction.pickNoCamera;
}

/// After the fist leaves the sender, keep advertising the hold so a
/// nearby camera can see the hand and catch.
const leftFrameHandoverWait = Duration(seconds: 3);

/// Fist left the sender camera.
///
/// A nearby camera that sees the fist is the lock — send there. Other
/// cameras stay possible targets until one of them sees the hand. If any
/// camera exists that is not the sender, computers without a camera are
/// not targets. Only a world with no other cameras auto-sends to a
/// headless PC.
LeftFrameDecision resolveLeftFrame({
  required List<AirDropPeer> nearby,
  required bool holdTimedOut,
}) {
  final cameras = nearby.where((p) => p.camera).toList()
    ..sort((a, b) => b.attention.compareTo(a.attention));
  final hands = cameras.where((p) => p.seesHand).toList();

  if (cameras.isNotEmpty) {
    if (hands.isNotEmpty) {
      return LeftFrameDecision(
        action: LeftFrameAction.autoSend,
        target: _leadPeer(hands),
      );
    }
    final looking = cameras
        .where((p) => p.attention >= kLookingAttention)
        .toList();
    AirDropPeer? hint;
    if (looking.isNotEmpty) {
      hint = _leadPeer(looking);
    } else if (cameras.length == 1) {
      hint = cameras.first;
    }
    // Timeout must not dump the photos on the only camera. Sitting in
    // front of Honor then typing is not a catch.
    return LeftFrameDecision(
      action: LeftFrameAction.waitCatch,
      target: hint,
    );
  }

  final noCam = nearby.where((p) => p.noCameraDesktop).toList();
  if (noCam.length == 1) {
    return LeftFrameDecision(
      action: LeftFrameAction.autoSend,
      target: noCam.first,
    );
  }
  if (noCam.length > 1) {
    return LeftFrameDecision(
      action: LeftFrameAction.pickNoCamera,
      choices: noCam,
    );
  }
  return const LeftFrameDecision(action: LeftFrameAction.none);
}

AirDropPeer _leadPeer(List<AirDropPeer> peers) {
  if (peers.length == 1) return peers.first;
  final sorted = [...peers]..sort((a, b) => b.attention.compareTo(a.attention));
  final lead = sorted[0];
  final next = sorted[1];
  if (lead.attention >= next.attention + kAttentionLead) return lead;
  return lead;
}

double attentionFromWire(Object? raw) {
  if (raw is num) {
    if (raw <= 1) return raw.toDouble().clamp(0, 1);
    return (raw / 100).clamp(0, 1);
  }
  return 0;
}

int attentionToWire(double attention) =>
    (attention.clamp(0, 1) * 100).round();
