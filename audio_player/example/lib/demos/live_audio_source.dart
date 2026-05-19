import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';

/// Live audio source demo: segments arrive over time. The wrapper appends
/// each URL to the playlist as it is emitted; media_kit plays gapless
/// across them. This is the building block for streaming-while-generating
/// UX (AI-generated music, on-the-fly TTS, anything where the server emits
/// chunks as they become ready).
///
/// The demo simulates a backend that emits one URL every 12 seconds. In a
/// real app this stream would come from an upstream service (e.g. a
/// websocket carrying segment-ready notifications from a generation
/// pipeline).
class LiveAudioSourceDemo extends StatefulWidget {
  const LiveAudioSourceDemo({super.key});

  @override
  State<LiveAudioSourceDemo> createState() => _LiveAudioSourceDemoState();
}

class _LiveAudioSourceDemoState extends State<LiveAudioSourceDemo> {
  /// Number of segment URLs the simulated backend emits before closing
  /// the stream. Matches the pool size in [SampleTracks.soundHelixUrls].
  static const int _segmentCount = 5;

  /// Spacing between simulated emissions. 12s is long enough for the
  /// demo to feel "live" but short enough for the user to observe all
  /// 5 emissions within a single session.
  static const Duration _emissionInterval = Duration(seconds: 12);

  late final CorePlayer _player;

  /// Driver for the simulated segment stream. In a real app the
  /// controller would be fed by a backend client; here a Timer.periodic
  /// pushes one SoundHelix URL per tick.
  StreamController<Uri>? _segmentController;
  Timer? _emissionTimer;

  /// Counter for the "Segments emitted: X / 5" label.
  int _emitted = 0;

  /// Whether the user has started the live demo. Wired to the "Start"
  /// button's enabled state — the demo is one-shot per page lifetime to
  /// keep the controlled-emission semantics tractable.
  bool _started = false;

  /// Live snapshot of the wrapper's queue, refreshed via queueStream so
  /// the demo's queue UI shows each appended segment as it lands.
  CorePlayerQueue _liveQueue = const CorePlayerQueue.empty();
  StreamSubscription<CorePlayerQueue>? _queueSub;

  @override
  void initState() {
    super.initState();
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _queueSub = _player.queueStream.listen((q) {
      if (!mounted) return;
      setState(() => _liveQueue = q);
    });
  }

  void _start() {
    if (_started) return;
    setState(() => _started = true);

    // Single-subscription controller — the wrapper subscribes exactly
    // once, matching LiveAudioSource's documented contract.
    final controller = StreamController<Uri>();
    _segmentController = controller;

    // The first URL is the initialUrl seed handed to the wrapper at
    // setQueue time; subsequent URLs (segments 2..5) come from the
    // controller over the next 4 ticks. This split mirrors the common
    // "first segment is already known, rest will arrive" pattern.
    final urls = SampleTracks.soundHelixUrls;
    final initial = urls.first;
    final remaining = urls.skip(1).toList();

    final live = LiveAudioSource(
      segmentUrlStream: controller.stream,
      title: 'Generated track',
      artist: 'Live demo',
      initialUrl: initial,
    );
    // Reflect segment 1 (the initial seed) in the counter immediately so
    // the UI starts at 1/5 rather than 0/5 the moment playback begins.
    setState(() => _emitted = 1);

    // Schedule remaining emissions one per interval. Stops the timer and
    // closes the controller after the last emit so the wrapper observes
    // `done` and the queue settles into "stream exhausted" state.
    var cursor = 0;
    _emissionTimer = Timer.periodic(_emissionInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (cursor >= remaining.length) {
        timer.cancel();
        controller.close();
        return;
      }
      controller.add(remaining[cursor]);
      cursor++;
      setState(() => _emitted = cursor + 1);
    });

    // Kick off playback. loadAndPlay routes through the wrapper's
    // setQueue path, which projects the live source's initialUrl into a
    // seed entry and attaches the segment stream subscription.
    unawaited(_player.loadAndPlay(live).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _emissionTimer?.cancel();
    unawaited(_segmentController?.close());
    _queueSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Live audio source (segment stream)')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _WhatThisDemosCard(),
            const SizedBox(height: 12),
            _PlayPauseRow(player: _player),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.play_circle_fill),
              label: const Text('Start live source'),
              onPressed: _started ? null : _start,
            ),
            const SizedBox(height: 12),
            _SegmentCounter(
              emitted: _emitted,
              total: _segmentCount,
              theme: theme,
            ),
            const SizedBox(height: 12),
            Text('Queue (appended segments)', style: theme.textTheme.titleMedium),
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
              'Live audio source: segments arrive over time. The wrapper appends\n'
              "each URL to the playlist as it's emitted; media_kit plays gapless\n"
              'across them. This is the building block for streaming-while-\n'
              'generating UX (AI-generated music, on-the-fly TTS, anything where\n'
              "the server emits chunks as they're ready).",
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
              '- Press "Start live source". Audio begins on segment 1.\n'
              '- Every ~12 seconds, a new segment URL is emitted into the\n'
              '  stream and appears in the queue below.\n'
              '- Playback transitions from segment to segment WITHOUT a pause\n'
              "  or restart (gapless, via media_kit's native Playlist).\n"
              '- After segment 5, the stream closes. The current segment plays\n'
              '  to its end; then the queue is exhausted and playback stops\n'
              '  (or onQueueExhausted fires if you have configured it).',
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
              player: player,
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

class _SegmentCounter extends StatelessWidget {
  const _SegmentCounter({
    required this.emitted,
    required this.total,
    required this.theme,
  });
  final int emitted;
  final int total;
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
          const Icon(Icons.stream),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Segments emitted: $emitted / $total'
              '${emitted >= total ? ' (stream closed)' : ''}',
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
        child: Text(
          '(no segments yet — press "Start live source")',
          style: TextStyle(color: Colors.grey),
        ),
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
