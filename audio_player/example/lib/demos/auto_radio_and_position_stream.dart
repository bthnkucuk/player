import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Combined demo for two Faz Q additions:
///
/// 1. [CorePlayer.positionDataStream] — single combined record stream of
///    `(position, duration)`. The scrubber below subscribes exclusively
///    to that stream rather than fanning out [CorePlayer.positionStream]
///    + [CorePlayer.durationStream] separately.
///
/// 2. [CorePlayerConfiguration.onQueueExhausted] — wrapper-level hook the
///    app uses to grow the queue when the active queue empties. This
///    demo's implementation appends one new track per invocation (up to 5
///    total) so the auto-radio behaviour is observable end-to-end without
///    pulling in a real recommendation engine.
///
/// The two features ship together because position-stream consumers and
/// auto-radio consumers are typically the same product surface
/// (continuous-listening UIs with a scrubber).
class AutoRadioAndPositionStreamDemo extends StatefulWidget {
  const AutoRadioAndPositionStreamDemo({super.key});

  @override
  State<AutoRadioAndPositionStreamDemo> createState() =>
      _AutoRadioAndPositionStreamDemoState();
}

class _AutoRadioAndPositionStreamDemoState
    extends State<AutoRadioAndPositionStreamDemo> {
  /// Pool of tracks the auto-radio callback hands out, one at a time.
  /// Kept short so the demo terminates predictably after 5 extensions.
  static const int _maxAutoExtensions = 5;

  late final CorePlayer _player;

  /// Auto-radio counter; the callback bumps this on every invocation.
  int _autoRadioCount = 0;

  /// Track index inside [_autoRadioPool] the callback will hand out
  /// next. Rolls over so the same set of tracks cycles if the user lets
  /// the demo run longer than the pool.
  int _autoRadioCursor = 0;

  /// Pool the auto-radio callback returns from. Different tracks than the
  /// seed queue so the user can hear the transition.
  late final List<CorePlayerAudioSource> _autoRadioPool = <CorePlayerAudioSource>[
    SampleTracks.soundHelix2,
    SampleTracks.soundHelix3,
    SampleTracks.scienceFridaySegment,
    SampleTracks.soundHelix1,
    SampleTracks.scienceFridayEpisode,
  ];

  /// The configuration we hand to ensureInitialized. Captured here so we
  /// can re-install it on dispose if needed.
  late final CorePlayerConfiguration _demoConfig;

  /// Live snapshot of the wrapper's queue (for the queue list UI).
  CorePlayerQueue _liveQueue = const CorePlayerQueue.empty();
  StreamSubscription<CorePlayerQueue>? _queueSub;

  @override
  void initState() {
    super.initState();

    _demoConfig = CorePlayerConfiguration(
      androidNotificationChannelId: 'com.example.audio_player_example.audio',
      androidNotificationChannelName: 'audio_player example playback',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
      onQueueExhausted: _onQueueExhausted,
    );

    // Re-install configuration so the wrapper sees our onQueueExhausted
    // hook. ensureInitialized is idempotent for the static state it owns
    // (MediaKit + factory + bridge registration); the configuration
    // override is the per-demo bit.
    CorePlayerMediaKit.ensureInitialized(configuration: _demoConfig);

    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);

    _queueSub = _player.queueStream.listen((q) {
      if (!mounted) return;
      setState(() => _liveQueue = q);
    });

    // Seed with a single short-ish track so the auto-radio kicks in
    // quickly even if the user doesn't seek. SoundHelix track 1 is ~6
    // minutes — long enough to verify the scrubber tracks position
    // smoothly, short enough that the auto-radio takes effect in a
    // single demo session.
    unawaited(
      _player.loadAndPlay(SampleTracks.soundHelix1).catchError((Object _) {}),
    );
  }

  /// onQueueExhausted body. Returning null/empty stops naturally;
  /// returning a non-empty list lets the wrapper append and continue.
  Future<List<CorePlayerAudioSource>>? _onQueueExhausted() {
    // Bump synchronously so the UI counter reflects the firing event
    // even before the (async) recommendation resolves.
    if (mounted) {
      setState(() => _autoRadioCount++);
    } else {
      _autoRadioCount++;
    }

    if (_autoRadioCount > _maxAutoExtensions) {
      // After the cap, behave like a real radio that's out of suggestions
      // — return null and let the wrapper stop naturally.
      return null;
    }

    final next = _autoRadioPool[_autoRadioCursor % _autoRadioPool.length];
    _autoRadioCursor++;
    return Future<List<CorePlayerAudioSource>>.value(<CorePlayerAudioSource>[next]);
  }

  @override
  void dispose() {
    _queueSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-radio + position stream')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _WhatThisDemosCard(),
            const SizedBox(height: 12),
            _PlayPauseRow(player: _player),
            const SizedBox(height: 8),
            // The scrubber binds EXCLUSIVELY to positionDataStream — this
            // is the whole point of demo (1). If a future refactor adds
            // back a separate positionStream subscription, the demo's
            // claim breaks and reviewers can spot it here.
            StreamBuilder<CorePlayerPositionData>(
              stream: _player.positionDataStream,
              initialData: _player.positionDataStream.value,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<CorePlayerPositionData> snap,
                  ) {
                    final CorePlayerPositionData data =
                        snap.data ??
                        (position: Duration.zero, duration: Duration.zero);
                    return SeekBar(
                      duration: data.duration,
                      position: data.position,
                      bufferedPosition: Duration.zero,
                      onSeek: _player.seek,
                    );
                  },
            ),
            const SizedBox(height: 12),
            _AutoRadioCounter(
              count: _autoRadioCount,
              cap: _maxAutoExtensions,
              theme: theme,
            ),
            const SizedBox(height: 12),
            Text('Queue', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            _LiveQueueList(queue: _liveQueue),
            const SizedBox(height: 16),
            _ExpectedResultCard(),
          ],
        ),
      ),
    );
  }
}

class _WhatThisDemosCard extends StatelessWidget {
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
              'Two features:\n\n'
              '1. positionDataStream — the new combined stream of\n'
              '   (position, duration). The scrubber below reads\n'
              '   exclusively from this stream, not from separate\n'
              '   position + duration streams.\n\n'
              '2. onQueueExhausted callback — when the queue ends\n'
              '   naturally, the wrapper calls the configured\n'
              "   callback. This demo's callback returns one new\n"
              '   sample track per invocation (up to 5 total) to\n'
              '   simulate an auto-radio.',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpectedResultCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
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
              'Expected result:\n'
              '- Press play. The current track plays. The scrubber\n'
              '  smoothly tracks position and shows total duration.\n'
              '- When the single track ends, the auto-radio counter\n'
              '  bumps from 0 -> 1 and a new track is appended and\n'
              '  starts playing automatically (no manual tap).\n'
              '- After 5 auto-extensions, the callback returns null\n'
              '  and playback stops naturally.\n\n'
              'If the scrubber stops updating but playback continues,\n'
              'the position stream has a bug. If a NEW track is\n'
              'appended BEFORE the first one ends, the queue-exhaustion\n'
              'detector has a re-entrancy bug.',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayPauseRow extends StatelessWidget {
  const _PlayPauseRow({required this.player});
  final CorePlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CorePlayerState>(
      stream: player.playerStateStream,
      initialData: player.playerState,
      builder: (BuildContext context, AsyncSnapshot<CorePlayerState> stateSnap) {
        final state = stateSnap.data ?? CorePlayerState.idle;
        return StreamBuilder<bool>(
          stream: player.playingStream,
          initialData: player.isPlaying,
          builder: (BuildContext context, AsyncSnapshot<bool> playingSnap) {
            return PlayPauseStopButtons(
              state: state,
              isPlaying: playingSnap.data ?? false,
              onPlay: () => player.play(),
              onPause: () => player.pause(),
              onStop: () => player.stop(),
            );
          },
        );
      },
    );
  }
}

class _AutoRadioCounter extends StatelessWidget {
  const _AutoRadioCounter({
    required this.count,
    required this.cap,
    required this.theme,
  });
  final int count;
  final int cap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.radio),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'onQueueExhausted fired: $count / $cap'
              '${count > cap ? ' (callback now returns null)' : ''}',
              style: theme.textTheme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveQueueList extends StatelessWidget {
  const _LiveQueueList({required this.queue});
  final CorePlayerQueue queue;

  @override
  Widget build(BuildContext context) {
    if (queue.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text('(queue empty)', style: TextStyle(color: Colors.grey)),
      );
    }
    return Column(
      children: <Widget>[
        for (int i = 0; i < queue.length; i++)
          ListTile(
            dense: true,
            leading: i == queue.currentIndex
                ? const Icon(Icons.play_arrow, color: Colors.green)
                : const Icon(Icons.queue_music),
            title: Text(
              queue.sources[i].title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: i == queue.currentIndex
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              queue.sources[i].artist ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
