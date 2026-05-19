import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

/// Row of chips advertising the engine capabilities of [player]. Reads
/// [CorePlayer.capabilities] once at build time (the value is stable across
/// the player's lifetime). Apps should use this pattern to feature-gate UI
/// instead of conditional imports or runtime engine sniffing.
class CapabilityBanner extends StatelessWidget {
  const CapabilityBanner({super.key, required this.player});

  final CorePlayer player;

  @override
  Widget build(BuildContext context) {
    final caps = player.capabilities;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        _CapabilityChip(label: 'HLS', enabled: caps.supportsHls),
        _CapabilityChip(
          label: 'Live source',
          enabled: caps.supportsLiveSource,
        ),
        _CapabilityChip(label: 'Crossfade', enabled: caps.supportsCrossfade),
        _CapabilityChip(label: 'Cast', enabled: caps.supportsCast),
        _CapabilityChip(label: 'DRM', enabled: caps.supportsDrm),
        _CapabilityChip(label: 'Equalizer', enabled: caps.supportsEqualizer),
      ],
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Color contract: a supported capability reads as green, an unsupported
    // one as red. The chip is decorative — no tap handler — so it doesn't
    // imply the user can toggle the underlying engine feature.
    final color = enabled ? Colors.green : Colors.red;
    return Chip(
      avatar: Icon(
        enabled ? Icons.check_circle : Icons.cancel,
        color: color,
        size: 18,
      ),
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.08),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
    );
  }
}
