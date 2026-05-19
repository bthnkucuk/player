import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../widgets/capability_banner.dart';

/// Read-only demo that surfaces [CorePlayer.capabilities] as a row of chips.
///
/// The point is API discoverability: consumers should feature-gate UI by
/// reading these flags, NOT by sniffing the engine type. Hard-coded
/// feature toggles become silent bugs the moment the engine swaps under
/// you (e.g. a future AVPlayer backend with different cast support).
class CapabilitiesDemo extends StatefulWidget {
  const CapabilitiesDemo({super.key});

  @override
  State<CapabilitiesDemo> createState() => _CapabilitiesDemoState();
}

class _CapabilitiesDemoState extends State<CapabilitiesDemo> {
  late final CorePlayer _player;

  @override
  void initState() {
    super.initState();
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Player capabilities')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'What this demos',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Reads player.capabilities and renders a chip per flag. '
                      'Apps should use this to feature-gate UI — e.g. hide a '
                      '"Cast" button when !capabilities.supportsCast — instead '
                      'of conditional imports or engine-type sniffing.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Capabilities',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    CapabilityBanner(player: _player),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Expected result',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Expected result on the media_kit engine:\n'
                      '- HLS: supported (green)\n'
                      '- Live source: supported (green)\n'
                      '- Crossfade: not supported (red — deferred, see ROADMAP)\n'
                      '- Cast: not supported (red — engine non-support)\n'
                      '- DRM: not supported (red — engine non-support)\n'
                      '- Equalizer: not supported (red — not yet wired through the wrapper)\n'
                      '\n'
                      'Apps should read these at startup and gate UI accordingly. '
                      'Hard-coded feature toggles are footguns when the engine '
                      'swaps under you.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
