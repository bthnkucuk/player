import 'dart:async';

import 'package:audio_player/audio_player.dart';
import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/seek_bar.dart';

/// Demonstrates the [NetworkPolicy] hook. The wrapper does NOT detect
/// connectivity itself — the user simulates a connectivity listener with
/// three buttons and observes how the configured policy reacts.
class NetworkPolicyDemo extends StatefulWidget {
  const NetworkPolicyDemo({super.key});

  @override
  State<NetworkPolicyDemo> createState() => _NetworkPolicyDemoState();
}

class _NetworkPolicyDemoState extends State<NetworkPolicyDemo> {
  CorePlayer? _player;
  StreamSubscription<NetworkHint>? _hintSub;

  // Policy is construction-time, so toggling a switch must rebuild the
  // player against a freshly-applied [ensureInitialized] configuration.
  bool _pauseOnOffline = true;
  bool _pauseOnMetered = false;
  bool _resumeWhenBackOnline = false;

  // Most recent 5 hint transitions, newest first.
  final List<_HintEvent> _log = <_HintEvent>[];

  @override
  void initState() {
    super.initState();
    _rebuildPlayer();
  }

  @override
  void dispose() {
    _hintSub?.cancel();
    final p = _player;
    if (p != null) unawaited(p.dispose());
    super.dispose();
  }

  /// Tear down the current player and stand up a new one whose
  /// configuration reflects the latest policy switches. Auto-loads the
  /// sample track so the user can hit Play immediately after a rebuild.
  Future<void> _rebuildPlayer() async {
    await _hintSub?.cancel();
    final prev = _player;
    if (prev != null) {
      await prev.dispose();
    }

    // `ensureInitialized` re-assigns the active configuration. Calling it
    // again with a new policy is the canonical way to change a
    // construction-time config — the next CorePlayer.create() reads from
    // the updated config.
    CorePlayerMediaKit.ensureInitialized(
      configuration: CorePlayerConfiguration(
        networkPolicy: NetworkPolicy(
          pauseOnOffline: _pauseOnOffline,
          pauseOnMetered: _pauseOnMetered,
          resumeWhenBackOnline: _resumeWhenBackOnline,
        ),
      ),
    );

    final next = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _hintSub = next.networkHintStream.listen((hint) {
      if (!mounted) return;
      setState(() {
        _log.insert(0, _HintEvent(hint, DateTime.now()));
        if (_log.length > 5) _log.removeRange(5, _log.length);
      });
    });
    if (mounted) setState(() => _player = next);
    try {
      await next.load(SampleTracks.scienceFridayEpisode);
    } on CorePlayerFailure {
      // Surface via the player's errorStream; nothing else to do here.
    }
  }

  Future<void> _notify(NetworkHint hint) async {
    final p = _player;
    if (p == null) return;
    try {
      await p.notifyNetworkHint(hint);
    } on CorePlayerFailure {
      // Player disposed mid-toggle; the rebuild flow will reset state.
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      appBar: AppBar(title: const Text('Network policy')),
      body: SafeArea(
        child: player == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  const _AboutCard(),
                  const SizedBox(height: 12),
                  _HintBanner(
                    player: player,
                  ),
                  const SizedBox(height: 12),
                  _HintButtons(
                    player: player,
                    onTap: _notify,
                  ),
                  const SizedBox(height: 12),
                  _PolicyEditor(
                    pauseOnOffline: _pauseOnOffline,
                    pauseOnMetered: _pauseOnMetered,
                    resumeWhenBackOnline: _resumeWhenBackOnline,
                    onPauseOnOfflineChanged: (v) {
                      setState(() => _pauseOnOffline = v);
                      _rebuildPlayer();
                    },
                    onPauseOnMeteredChanged: (v) {
                      setState(() => _pauseOnMetered = v);
                      _rebuildPlayer();
                    },
                    onResumeWhenBackOnlineChanged: (v) {
                      setState(() => _resumeWhenBackOnline = v);
                      _rebuildPlayer();
                    },
                  ),
                  const SizedBox(height: 12),
                  _TransportRow(player: player),
                  const SizedBox(height: 12),
                  _HintLog(events: _log),
                  const SizedBox(height: 12),
                  const _ExpectedCard(),
                ],
              ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'What this demos',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'The wrapper does NOT detect connectivity itself. Apps push a\n'
              'NetworkHint when their connectivity changes, and the configured\n'
              'NetworkPolicy decides whether to auto-pause / auto-resume. This\n'
              'demo simulates a connectivity listener with three buttons:\n'
              'Unmetered (Wi-Fi), Metered (cellular), Offline.',
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpectedCard extends StatelessWidget {
  const _ExpectedCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'Expected result',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'Expected result (with default policy: pauseOnOffline=true, others false):\n'
              '- Press Play on the loaded track.\n'
              '- Tap "Offline" → playback pauses immediately. The hint banner shows\n'
              '  "OFFLINE", the policy log records the transition.\n'
              '- Tap "Unmetered" → with resumeWhenBackOnline=false, playback STAYS\n'
              '  paused. You must press Play manually.\n'
              '- Toggle resumeWhenBackOnline on (rebuilds the player; reload the\n'
              '  track), repeat the sequence → now tapping Unmetered after Offline\n'
              '  auto-resumes playback.\n'
              '- Tap "Metered" with default policy → no pause; the hint just\n'
              '  updates. Enable pauseOnMetered → tapping "Metered" pauses.\n'
              '- If you manually pause between Offline and Unmetered, the auto-\n'
              '  resume does NOT fire (a manual pause clears the auto-resume\n'
              '  eligibility).',
            ),
          ],
        ),
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  const _HintBanner({required this.player});

  final CorePlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NetworkHint>(
      stream: player.networkHintStream,
      initialData: player.currentNetworkHint,
      builder: (context, snap) {
        final hint = snap.data ?? NetworkHint.unmetered;
        final color = switch (hint) {
          NetworkHint.unmetered => Colors.green,
          NetworkHint.metered => Colors.orange,
          NetworkHint.offline => Colors.red,
        };
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.network_check, color: color),
              const SizedBox(width: 8),
              Text(
                'Current hint: ${hint.name.toUpperCase()}',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HintButtons extends StatelessWidget {
  const _HintButtons({required this.player, required this.onTap});

  final CorePlayer player;
  final Future<void> Function(NetworkHint) onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NetworkHint>(
      stream: player.networkHintStream,
      initialData: player.currentNetworkHint,
      builder: (context, snap) {
        final active = snap.data ?? NetworkHint.unmetered;
        return Row(
          children: <Widget>[
            Expanded(
              child: _HintButton(
                label: 'Unmetered\n(Wi-Fi)',
                hint: NetworkHint.unmetered,
                active: active == NetworkHint.unmetered,
                onTap: () => onTap(NetworkHint.unmetered),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _HintButton(
                label: 'Metered\n(cellular)',
                hint: NetworkHint.metered,
                active: active == NetworkHint.metered,
                onTap: () => onTap(NetworkHint.metered),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _HintButton(
                label: 'Offline',
                hint: NetworkHint.offline,
                active: active == NetworkHint.offline,
                onTap: () => onTap(NetworkHint.offline),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HintButton extends StatelessWidget {
  const _HintButton({
    required this.label,
    required this.hint,
    required this.active,
    required this.onTap,
  });

  final String label;
  final NetworkHint hint;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ButtonStyle style = active
        ? FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            padding: const EdgeInsets.symmetric(vertical: 16),
          )
        : FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            padding: const EdgeInsets.symmetric(vertical: 16),
          );
    return FilledButton(
      style: style,
      onPressed: onTap,
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}

class _PolicyEditor extends StatelessWidget {
  const _PolicyEditor({
    required this.pauseOnOffline,
    required this.pauseOnMetered,
    required this.resumeWhenBackOnline,
    required this.onPauseOnOfflineChanged,
    required this.onPauseOnMeteredChanged,
    required this.onResumeWhenBackOnlineChanged,
  });

  final bool pauseOnOffline;
  final bool pauseOnMetered;
  final bool resumeWhenBackOnline;
  final ValueChanged<bool> onPauseOnOfflineChanged;
  final ValueChanged<bool> onPauseOnMeteredChanged;
  final ValueChanged<bool> onResumeWhenBackOnlineChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Policy (toggling rebuilds the player)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('pauseOnOffline'),
              value: pauseOnOffline,
              onChanged: onPauseOnOfflineChanged,
            ),
            SwitchListTile(
              dense: true,
              title: const Text('pauseOnMetered'),
              value: pauseOnMetered,
              onChanged: onPauseOnMeteredChanged,
            ),
            SwitchListTile(
              dense: true,
              title: const Text('resumeWhenBackOnline'),
              value: resumeWhenBackOnline,
              onChanged: onResumeWhenBackOnlineChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.player});

  final CorePlayer player;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        StreamBuilder<bool>(
          stream: player.playingStream,
          initialData: player.isPlaying,
          builder: (context, snap) {
            final isPlaying = snap.data ?? false;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  iconSize: 36,
                  onPressed: isPlaying ? null : () => player.play(),
                ),
                IconButton(
                  icon: const Icon(Icons.pause),
                  iconSize: 36,
                  onPressed: isPlaying ? () => player.pause() : null,
                ),
                IconButton(
                  icon: const Icon(Icons.stop),
                  iconSize: 36,
                  onPressed: () => player.stop(),
                ),
              ],
            );
          },
        ),
        StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position,
          builder: (context, posSnap) {
            return StreamBuilder<Duration>(
              stream: player.durationStream,
              initialData: player.duration,
              builder: (context, durSnap) {
                return SeekBar(
                  duration: durSnap.data ?? Duration.zero,
                  position: posSnap.data ?? Duration.zero,
                  bufferedPosition: Duration.zero,
                  onSeek: player.seek,
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _HintEvent {
  _HintEvent(this.hint, this.at);
  final NetworkHint hint;
  final DateTime at;
}

class _HintLog extends StatelessWidget {
  const _HintLog({required this.events});

  final List<_HintEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('No hint transitions yet — tap a button above.'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Recent hint transitions (newest first)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            for (final ev in events)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${_formatTime(ev.at)}  →  ${ev.hint.name.toUpperCase()}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }
}
