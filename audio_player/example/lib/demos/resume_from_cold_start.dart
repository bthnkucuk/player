import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Demonstrates `CorePlayer.snapshot()` and `CorePlayer.restore()` — the
/// Suno-tier cold-launch resume primitive. Snapshot is held in memory so
/// the round-trip is observable without a real process restart.
class ResumeFromColdStartDemo extends StatefulWidget {
  const ResumeFromColdStartDemo({super.key});

  @override
  State<ResumeFromColdStartDemo> createState() => _ResumeFromColdStartDemoState();
}

class _ResumeFromColdStartDemoState extends State<ResumeFromColdStartDemo> {
  CorePlayer? _player;
  StreamSubscription<CorePlayerFailure>? _errorSub;

  /// In-memory snapshot — kept as JSON so the preview text reflects exactly
  /// what would be written to disk in a real app. `null` until the user has
  /// pressed "Save snapshot" at least once.
  String? _savedSnapshotJson;
  String? _lastError;
  bool _restoring = false;

  // Queue used for the demo — small subset of [SampleTracks] so the user can
  // exercise skip + restore on a manageable queue.
  static final List<CorePlayerAudioSource> _demoQueue = <CorePlayerAudioSource>[
    SampleTracks.soundHelix1,
    SampleTracks.soundHelix2,
    SampleTracks.soundHelix3,
  ];

  @override
  void initState() {
    super.initState();
    _player = _newPlayer();
  }

  CorePlayer _newPlayer() {
    final p = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _errorSub?.cancel();
    _errorSub = p.errorStream.listen((failure) {
      if (!mounted) return;
      setState(() => _lastError = failure.toString());
    });
    return p;
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _loadQueue() async {
    final p = _player;
    if (p == null) return;
    setState(() => _lastError = null);
    try {
      await p.setQueue(CorePlayerQueue(_demoQueue));
      await p.play();
    } on CorePlayerFailure catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  void _saveSnapshot() {
    final p = _player;
    if (p == null) return;
    final snap = p.snapshot();
    // Encode + pretty-print so the preview text matches what would be
    // written to disk by a real app's persistence layer.
    final pretty = const JsonEncoder.withIndent('  ').convert(snap);
    setState(() {
      _savedSnapshotJson = pretty;
      _lastError = null;
    });
  }

  Future<void> _restoreSnapshot() async {
    final saved = _savedSnapshotJson;
    if (saved == null) return;
    setState(() {
      _restoring = true;
      _lastError = null;
    });
    try {
      // Tear down the existing player BEFORE creating the replacement so the
      // old native handle releases its claim on the audio session before the
      // new one attaches. Without this the new player races the old one on
      // iOS's AVAudioSession activation.
      final old = _player;
      _player = null;
      _errorSub?.cancel();
      _errorSub = null;
      await old?.dispose();

      final raw = jsonDecode(saved) as Map<String, Object?>;
      final restored = await CorePlayer.restore(raw, audioHandler: CoreAudioHandler.instance);
      _errorSub = restored.errorStream.listen((failure) {
        if (!mounted) return;
        setState(() => _lastError = failure.toString());
      });
      if (!mounted) {
        await restored.dispose();
        return;
      }
      setState(() {
        _player = restored;
        _restoring = false;
      });
    } on CorePlayerFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = e.toString();
        _restoring = false;
        // Surface a fresh player even on failure so the UI doesn't sit on a
        // null _player; demo-only — a real app would surface a retry banner.
        _player ??= _newPlayer();
      });
    }
  }

  static String _fmt(Duration d) {
    final totalSec = d.inSeconds;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = _player;
    return Scaffold(
      appBar: AppBar(title: const Text('Resume from cold start')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('What this demos', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                      'This demos snapshot/restore for cold-start resume.\n'
                      'Tap "Save snapshot" while a track is mid-playback,\n'
                      'then tap "Restore from saved" — the player should\n'
                      'recreate itself paused, with the queue and playhead\n'
                      'at the same position, exactly where you left off.\n\n'
                      'Notes: in a real app the snapshot would be written\n'
                      'to disk (e.g. shared_preferences or a JSON file) on\n'
                      'app-pause. This demo just keeps it in memory so you\n'
                      'can test the round-trip without a process restart.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: player == null ? null : _loadQueue,
              icon: const Icon(Icons.queue_music),
              label: const Text('Load demo queue + play'),
            ),
            const SizedBox(height: 8),
            if (player != null) ...<Widget>[
              StreamBuilder<CorePlayerAudioSource?>(
                stream: player.audioSourceStream,
                initialData: player.audioSource,
                builder: (context, snap) {
                  final src = snap.data;
                  final title = src?.title ?? '(no source)';
                  final index = player.queue.currentIndex;
                  final length = player.queue.length;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Title: $title', style: theme.textTheme.bodyLarge),
                      Text('Active index: $index / ${length == 0 ? 0 : length - 1}'),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              StreamBuilder<Duration>(
                stream: player.positionStream,
                initialData: player.position,
                builder: (context, posSnap) {
                  return StreamBuilder<Duration>(
                    stream: player.durationStream,
                    initialData: player.duration,
                    builder: (context, durSnap) {
                      final pos = posSnap.data ?? Duration.zero;
                      final dur = durSnap.data ?? Duration.zero;
                      return Column(
                        children: <Widget>[
                          SeekBar(
                            duration: dur,
                            position: pos,
                            bufferedPosition: player.buffer,
                            onSeek: (d) => player.seek(d),
                          ),
                          Text('Position: ${_fmt(pos)} / ${_fmt(dur)}'),
                        ],
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 8),
              StreamBuilder<CorePlayerState>(
                stream: player.playerStateStream,
                initialData: player.playerState,
                builder: (context, stateSnap) {
                  return StreamBuilder<bool>(
                    stream: player.playingStream,
                    initialData: player.isPlaying,
                    builder: (context, playingSnap) {
                      return PlayPauseStopButtons(
                        state: stateSnap.data ?? CorePlayerState.idle,
                        isPlaying: playingSnap.data ?? false,
                        onPlay: () => player.play(),
                        onPause: () => player.pause(),
                        onStop: () => player.stop(),
                      );
                    },
                  );
                },
              ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: player == null || _restoring ? null : _saveSnapshot,
                    icon: const Icon(Icons.save),
                    label: const Text('Save snapshot'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _savedSnapshotJson == null || _restoring
                        ? null
                        : _restoreSnapshot,
                    icon: const Icon(Icons.restore),
                    label: const Text('Restore from saved'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_savedSnapshotJson != null) ...<Widget>[
              Text('Saved snapshot (JSON):', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _savedSnapshotJson!,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
            if (_lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Error: $_lastError', style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Expected result', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                      'Expected result:\n'
                      '- "Save snapshot" -> JSON appears in the preview\n'
                      '  showing schemaVersion + queue items + activeIndex\n'
                      '  + position-ms.\n'
                      '- "Restore from saved" -> player UI re-initializes,\n'
                      '  the queue / active item / scrubber position match\n'
                      '  exactly what was saved, AND the player is paused\n'
                      '  (you must press play to resume).\n'
                      '- The restored playhead position is within ~200 ms\n'
                      '  of the saved value (engine-side seek tolerance).\n\n'
                      'If the restored player auto-resumes playback, that\'s\n'
                      'a regression -- restore must always be paused.',
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
