import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Installs a [CorePlayerObserver] and logs every callback into a scrollable
/// list so the user can see lifecycle events as they happen. Demonstrates the
/// observability hook (analogous to `flutter_bloc`'s `BlocObserver`).
class ObserverDemo extends StatefulWidget {
  const ObserverDemo({super.key});

  @override
  State<ObserverDemo> createState() => _ObserverDemoState();
}

class _ObserverDemoState extends State<ObserverDemo> {
  late final CorePlayer _player;
  final Queue<String> _logs = Queue<String>();
  final ScrollController _scrollCtrl = ScrollController();
  CorePlayerObserver? _previous;
  late final _UiObserver _observer;

  static const int _maxLogs = 200;

  @override
  void initState() {
    super.initState();
    _previous = CorePlayer.observer;
    _observer = _UiObserver(_appendLog);
    CorePlayer.observer = _observer;
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
  }

  @override
  void dispose() {
    CorePlayer.observer = _previous;
    unawaited(_player.dispose());
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      final String stamp = DateTime.now().toIso8601String().substring(11, 23);
      _logs.addLast('[$stamp] $line');
      while (_logs.length > _maxLogs) {
        _logs.removeFirst();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _triggerError() async {
    // Load a bogus URL to force a LoadFailure — fires onError via the
    // wrapper's _throwAndEmit helper.
    try {
      await _player.loadAndPlay(
        const CorePlayerAudioSource(
          title: 'Bogus track',
          url: 'https://invalid.example.invalid/missing.mp3',
        ),
      );
    } on CorePlayerFailure {
      // Already logged via onError; ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Observer'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: () => setState(_logs.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              'Each button below fires a different CorePlayerObserver hook. Watch the green log panel.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              SampleTracks.scienceFridayEpisode.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: () => _player.loadAndPlay(
                    SampleTracks.scienceFridayEpisode,
                  ),
                  child: const Text('loadAndPlay → onLoad + onPlay'),
                ),
                FilledButton.tonal(
                  onPressed: _triggerError,
                  child: const Text('Trigger error → onError'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Real seek bar — drag to fire onSeek with arbitrary positions.
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              initialData: _player.position,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<Duration> posSnap,
                  ) {
                    return StreamBuilder<Duration>(
                      stream: _player.durationStream,
                      initialData: _player.duration,
                      builder:
                          (
                            BuildContext context,
                            AsyncSnapshot<Duration> durSnap,
                          ) {
                            return StreamBuilder<Duration>(
                              stream: _player.bufferStream,
                              initialData: _player.buffer,
                              builder:
                                  (
                                    BuildContext context,
                                    AsyncSnapshot<Duration> bufSnap,
                                  ) {
                                    return SeekBar(
                                      position:
                                          posSnap.data ?? Duration.zero,
                                      duration:
                                          durSnap.data ?? Duration.zero,
                                      bufferedPosition:
                                          bufSnap.data ?? Duration.zero,
                                      onSeek: (Duration target) =>
                                          _player.seek(target),
                                    );
                                  },
                            );
                          },
                    );
                  },
            ),
            const SizedBox(height: 4),
            Text(
              'Drag the slider above → onSeek',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            StreamBuilder<CorePlayerState>(
              stream: _player.playerStateStream,
              initialData: _player.playerState,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<CorePlayerState> stateSnap,
                  ) {
                    return StreamBuilder<bool>(
                      stream: _player.playingStream,
                      initialData: _player.isPlaying,
                      builder:
                          (
                            BuildContext context,
                            AsyncSnapshot<bool> playingSnap,
                          ) {
                            return PlayPauseStopButtons(
                              player: _player,
                              state: stateSnap.data ?? CorePlayerState.idle,
                              isPlaying: playingSnap.data ?? false,
                              onPlay: () => _player.play(),
                              onPause: () => _player.pause(),
                              onStop: () => _player.stop(),
                            );
                          },
                    );
                  },
            ),
            Text(
              'Play / Pause / Stop → onPlay / onPause / onStop + onStateChange',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // Bounded log surface (240px) with its own ListView so the log
            // scrolls independently within the outer scrollable body.
            SizedBox(
              height: 240,
              child: Container(
                color: Colors.black,
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: _logs.length,
                  itemBuilder: (BuildContext context, int index) {
                    final String line = _logs.elementAt(index);
                    return Text(
                      line,
                      key: ValueKey<int>(index),
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UiObserver extends CorePlayerObserver {
  _UiObserver(this._sink);

  final void Function(String line) _sink;

  @override
  void onCreate(CorePlayer player) => _sink('onCreate');

  @override
  void onLoad(CorePlayer player, CorePlayerAudioSource source) =>
      _sink('onLoad: ${source.title}');

  @override
  void onPlay(CorePlayer player) => _sink('onPlay');

  @override
  void onPause(CorePlayer player) => _sink('onPause');

  @override
  void onStop(CorePlayer player) => _sink('onStop');

  @override
  void onSeek(CorePlayer player, Duration position) =>
      _sink('onSeek: ${position.inSeconds}s');

  @override
  void onStateChange(CorePlayer player, CorePlayerState from, CorePlayerState to) {
    _sink('onStateChange: ${from.name} → ${to.name}');
  }

  @override
  void onError(CorePlayer player, CorePlayerFailure failure) =>
      _sink('onError: $failure');

  @override
  void onDispose(CorePlayer player) => _sink('onDispose');
}
