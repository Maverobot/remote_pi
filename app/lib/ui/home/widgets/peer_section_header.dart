import 'package:app/pairing/storage.dart';
import 'package:app/ui/app_theme.dart';
import 'package:flutter/material.dart';

/// Per-pairing section header on the Home list (one per Pi). Shows the device
/// label (nickname → sessionName → epk prefix). The old `via <harness>`
/// subtitle was dropped as redundant.
class PeerSectionHeader extends StatelessWidget {
  final PeerRecord peer;
  const PeerSectionHeader({super.key, required this.peer});

  @override
  Widget build(BuildContext context) {
    final label = (peer.nickname?.isNotEmpty ?? false)
        ? peer.nickname!
        : peer.sessionName.isNotEmpty
            ? peer.sessionName
            : peer.remoteEpk.substring(0, 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: kMono,
          fontSize: 11,
          color: kMuted,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
