import 'package:air_gesture/air_gesture.dart';
import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../services/drop_service.dart';

/// Gold — AOW OS desktop only.
const Color kAowOsGoldTop = Color(0xFFF6D36B);
const Color kAowOsGoldBot = Color(0xFFD4A84B);

/// Mid pastel blue — AOW Mobile OS (not pink).
const Color kAowMobileBlueTop = Color(0xFFB8D8F4);
const Color kAowMobileBlueBot = Color(0xFF7AAFE0);

bool dropPeerIsAow(DropPeer peer) {
  if (peer.os == AirPeerOs.linux) return true;
  final n = peer.name.toLowerCase();
  return n.contains('aow os') || n.contains('aow-os');
}

bool dropPeerIsAowMobile(DropPeer peer) {
  return dropPeerIsAow(peer) &&
      (peer.role == AirPeerRole.phone || peer.role == AirPeerRole.tablet);
}

String dropPeerDisplayName(DropPeer peer) {
  final stripped = peer.name
      .replaceAll(
        RegExp(r'\s*\(AOW OS(?: Mobile)?\)\s*', caseSensitive: false),
        '',
      )
      .trim();
  return stripped.isEmpty ? peer.name : stripped;
}

List<Color> dropPeerBubbleColors(DropPeer peer) {
  if (dropPeerIsAowMobile(peer)) {
    return const [kAowMobileBlueTop, kAowMobileBlueBot];
  }
  if (dropPeerIsAow(peer)) {
    return const [kAowOsGoldTop, kAowOsGoldBot];
  }
  const desk = [AmlTheme.violet, AmlTheme.mint];
  final accent = desk[peer.id.hashCode.abs() % 2];
  return [Color.lerp(Colors.white, accent, 0.22)!, accent];
}

Color dropPeerAccent(DropPeer peer) => dropPeerBubbleColors(peer).last;
