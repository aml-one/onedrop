import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../core/labels.dart';
import '../services/drop_service.dart';

/// OneDrop (files) vs Gallery (photos) under a discovered name.
class DropAppCaption extends StatelessWidget {
  const DropAppCaption({
    super.key,
    required this.peer,
    this.known = false,
    this.compact = false,
    this.fontSize = 10,
    this.center = false,
  });

  final DropPeer peer;
  final bool known;
  final bool compact;
  final double fontSize;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final files = peer.acceptsFiles;
    final color = files ? AmlTheme.sky : AmlTheme.pink;
    final icon = files ? Icons.folder_rounded : Icons.photo_rounded;
    final mark = DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(icon, size: fontSize + 1, color: color),
      ),
    );
    final label = Text(
      dropPeerAppLine(peer, known: known, compact: compact),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        height: 1.1,
        color: color,
      ),
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        mark,
        const SizedBox(width: 2),
        if (center) label else Flexible(child: label),
      ],
    );
    if (center) return Center(child: row);
    return row;
  }
}
