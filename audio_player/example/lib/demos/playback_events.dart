import 'dart:async';

import 'package:audio_player/audio_player.dart';
import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Live demo of [CorePlayer.playbackEventStream]. Subscribes to the typed
/// playback-event stream and renders every event as it fires so a reviewer
/// can correlate user actions (play / skip / stop / seek) with the typed
/// event the wrapper emits.
///
/// The heartbeat toggle flips between `null` (default — no
/// PlaybackHeartbeatEvent emissions) and `Duration(seconds: 2)`. Heartbeat
/// is configuration-time, so toggling rebuilds the player; the demo keeps
/// the queue and starts paused so the reviewer can press play once the
/// rebuild completes.
class PlaybackEventsDemo extends StatefulWidget {
  const PlaybackEventsDemo({super.key});

  @override
  State<PlaybackEventsDemo> createState() => _PlaybackEventsDemoState();
}

class _PlaybackEventsDemoState extends State<PlaybackEventsDemo> {
  /// Cap on the live log so a long session doesn't bloat the widget tree.
  static const int _maxLogLines = 50;

  late CorePlayer _player;
  StreamSubscription<CorePlaybackEvent>? _eventSub;

  /// Most-recent-first event log. Each entry is rendered as a single text
  /// row in the scrollable below.
  final List<_LogLine> _log = <_LogLine>[];

  /// Heartbeat toggle. Off ⇒ no PlaybackHeartbeatEvent; On ⇒ 2 s.
  bool _heartbeatOn = false;

  @override
  void initState() {
    super.initState();
    _spinUpPlayer();
  }

  /// Rebuild the player and re-subscribe to the event stream. Called from
  /// initState and from the heartbeat toggle (heartbeat is config-time, so
  /// a runtime flip requires constructing a fresh CorePlayer).
  void _spinUpPlayer({bool keepLog = false}) {
    CorePlayerMediaKit.ensureInitialized(
      configuration: CorePlayerConfiguration(
        androidNotificationChannelId: 'com.example.audio_player_example.audio',
        androidNotificationChannelName: 'audio_player example playback',
        androidNotificationOngoing: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
        heartbeatInterval: _heartbeatOn ? const Duration(seconds: 2) : null,
      ),
    );
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _eventSub = _player.playbackEventStream.listen(_onEvent);
    unawaited(
      _player
          .setQueue(CorePlayerQueue(SampleTracks.playlist.take(2).toList()))
          .catchError((Object _) {}),
    );
    if (!keepLog) {
      _log.clear();
    }
  }

  void _onEvent(CorePlaybackEvent event) {
    final line = _LogLine(event: event, when: DateTime.now());
    setState(() {
      _log.insert(0, line);
      if (_log.length > _maxLogLines) {
        _log.removeRange(_maxLogLines, _log.length);
      }
    });
  }

  Future<void> _toggleHeartbeat(bool value) async {
    // Heartbeat is read at CorePlayer construction time, so we tear down
    // the current player and bring up a fresh one. Keep the log to make
    // before/after comparison observable on screen.
    final oldPlayer = _player;
    final oldSub = _eventSub;
    setState(() {
      _heartbeatOn = value;
    });
    await oldSub?.cancel();
    await oldPlayer.dispose();
    _spinUpPlayer(keepLog: true);
    setState(() {});
  }

  @override
  void dispose() {
    unawaited(_eventSub?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Playback events')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const _WhatThisDemosCard(),
            const SizedBox(height: 12),
            _PlayPauseRow(player: _player),
            const SizedBox(height: 8),
            StreamBuilder<CorePlayerPositionData>(
              stream: _player.positionDataStream,
              initialData: _player.positionDataStream.value,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<CorePlayerPositionData> snap,
                  ) {
                    final data =
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
            _HeartbeatToggle(value: _heartbeatOn, onChanged: _toggleHeartbeat),
            const SizedBox(height: 12),
            Text('Live event log', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            SizedBox(
              height: 280,
              child: _EventLogView(log: _log),
            ),
            const SizedBox(height: 16),
            const _ExpectedResultCard(),
          ],
        ),
      ),
    );
  }
}

/// Plain-data row rendered in the event log.
class _LogLine {
  _LogLine({required this.event, required this.when});
  final CorePlaybackEvent event;
  final DateTime when;
}

class _WhatThisDemosCard extends StatelessWidget {
  const _WhatThisDemosCard();

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
              'Subscribes to player.playbackEventStream and shows every typed\n'
              'playback event as it fires. Apps wire this to analytics: royalty\n'
              'reporting needs heartbeat + completion, "lose interest" charts need\n'
              'skip events with skippedFromPosition. The wrapper emits one typed\n'
              'event per state change so consumers don\'t reverse-engineer transitions\n'
              'from raw streams.',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpectedResultCard extends StatelessWidget {
  const _ExpectedResultCard();

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
              '- Press Play -> "PlaybackStartedEvent" appears with source = first track.\n'
              '- Press Skip Next -> "PlaybackEndedBySkipEvent" with skippedFromPosition\n'
              '  showing where you were. Then a new "PlaybackStartedEvent" for the\n'
              '  second track.\n'
              '- Let the second track finish naturally -> "PlaybackEndedByCompletionEvent".\n'
              '- Press Stop -> "PlaybackEndedByStopEvent".\n'
              '- Drag the scrubber -> "PlaybackSeekEvent" with from + to positions.\n'
              '- Pull the network plug or run on a slow connection -> expect a\n'
              '  "PlaybackStallStartedEvent" then "PlaybackStallEndedEvent" with the\n'
              '  wall-clock stall duration.\n'
              '- Toggle heartbeat on -> every 2 s a "PlaybackHeartbeatEvent" appears\n'
              '  with elapsedSinceStart growing monotonically. Pause -> no more\n'
              '  heartbeats until resume.',
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

class _HeartbeatToggle extends StatelessWidget {
  const _HeartbeatToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.favorite),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Heartbeat: ${value ? "every 2s" : "off"}',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _EventLogView extends StatelessWidget {
  const _EventLogView({required this.log});
  final List<_LogLine> log;

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '(no events yet — press Play)',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      itemCount: log.length,
      itemBuilder: (BuildContext context, int i) {
        final line = log[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            _formatLine(line),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        );
      },
    );
  }

  /// Format a log line as `HH:MM:SS.mmm  EventTypeName  detail`. The
  /// `detail` field picks the most-informative typed field per event type:
  /// position for skip, stallDuration for stall-end, etc.
  String _formatLine(_LogLine line) {
    final t = line.when;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    final ts = '$hh:$mm:$ss.$ms';
    final detail = _eventDetail(line.event);
    return '$ts  ${line.event.runtimeType}  $detail';
  }

  String _eventDetail(CorePlaybackEvent event) {
    final src = event.source?.title ?? '<none>';
    // Exhaustive switch — analyzer catches a missing case if a future
    // subtype is added without updating this demo.
    return switch (event) {
      PlaybackStartedEvent() => 'source="$src"',
      PlaybackEndedByCompletionEvent() => 'source="$src"',
      PlaybackEndedBySkipEvent(:final skippedFromPosition) =>
          'source="$src" skippedFrom=${_dur(skippedFromPosition)}',
      PlaybackEndedByStopEvent() => 'source="$src"',
      PlaybackSeekEvent(:final fromPosition, :final toPosition) =>
          'source="$src" from=${_dur(fromPosition)} to=${_dur(toPosition)}',
      PlaybackStallStartedEvent() => 'source="$src"',
      PlaybackStallEndedEvent(:final stallDuration) =>
          'source="$src" stallDuration=${_dur(stallDuration)}',
      PlaybackHeartbeatEvent(:final elapsedSinceStart) =>
          'source="$src" elapsed=${_dur(elapsedSinceStart)}',
    };
  }

  String _dur(Duration d) {
    final secs = d.inSeconds;
    final ms = d.inMilliseconds.remainder(1000);
    return '${secs}s${ms.toString().padLeft(3, '0')}ms';
  }
}
