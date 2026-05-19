import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Demonstrates the single-track API surface:
/// `loadAndPlay`, play/pause/stop, seek, speed, volume, loop mode (off / one),
/// `errorStream` subscription.
class SingleTrackDemo extends StatefulWidget {
  const SingleTrackDemo({super.key});

  @override
  State<SingleTrackDemo> createState() => _SingleTrackDemoState();
}

class _SingleTrackDemoState extends State<SingleTrackDemo> {
  late final CorePlayer _player;
  StreamSubscription<CorePlayerFailure>? _errorSub;
  StreamSubscription<CorePlayerState>? _stateSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<Duration>? _positionSub;
  String? _lastError;

  // Instrumentation state.
  final List<String> _eventLog = <String>[];
  DateTime? _seekStartedAt;
  Duration? _seekTarget;
  CorePlayerState _lastState = CorePlayerState.idle;
  Duration _lastBuffer = Duration.zero;
  Duration _lastPosition = Duration.zero;
  final Stopwatch _bootClock = Stopwatch()..start();

  String get _ts {
    final double s = _bootClock.elapsedMilliseconds / 1000.0;
    return '[T+${s.toStringAsFixed(3)}s]';
  }

  void _log(String msg) {
    final String line = '$_ts $msg';
    debugPrint(line);
    if (!mounted) return;
    setState(() {
      _eventLog.insert(0, line);
      if (_eventLog.length > 200) _eventLog.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);

    _errorSub = _player.errorStream.listen((CorePlayerFailure failure) {
      _log('ERROR ${failure.runtimeType}: $failure');
      if (!mounted) return;
      setState(() => _lastError = failure.toString());
    });

    _stateSub = _player.playerStateStream.listen((CorePlayerState state) {
      final CorePlayerState prev = _lastState;
      _lastState = state;
      _log(
        'STATE $prev -> $state  (pos=${_fmt(_lastPosition)}  buf=${_fmt(_lastBuffer)})',
      );

      // Detect end of seek: we marked _seekStartedAt; resolve when next we see
      // a non-loading/non-buffering state (ready or playing).
      if (_seekStartedAt != null &&
          state != CorePlayerState.loading &&
          state != CorePlayerState.idle) {
        final Duration elapsed = DateTime.now().difference(_seekStartedAt!);
        final Duration target = _seekTarget ?? Duration.zero;
        _log(
          'SEEK_RESOLVED target=${_fmt(target)} elapsed=${elapsed.inMilliseconds}ms finalState=$state pos=${_fmt(_lastPosition)} buf=${_fmt(_lastBuffer)}',
        );
        _seekStartedAt = null;
        _seekTarget = null;
      }
    });

    _bufferSub = _player.bufferStream.listen((Duration b) {
      // Throttle: only log when changed by >=5s to avoid spam.
      if ((b - _lastBuffer).inSeconds.abs() >= 5) {
        _log('BUFFER ${_fmt(_lastBuffer)} -> ${_fmt(b)}');
      }
      _lastBuffer = b;
    });

    _positionSub = _player.positionStream.listen((Duration p) {
      _lastPosition = p;
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _stateSub?.cancel();
    _bufferSub?.cancel();
    _positionSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _loadAndPlay() async {
    setState(() => _lastError = null);
    _log('CALL loadAndPlay()');
    try {
      await _player.loadAndPlay(SampleTracks.scienceFridayEpisode);
      _log('RETURN loadAndPlay() OK');
    } on CorePlayerFailure catch (e) {
      _log('THROW loadAndPlay() $e');
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  Future<void> _seekTo(Duration target) async {
    _seekStartedAt = DateTime.now();
    _seekTarget = target;
    _log(
      'CALL seek(${_fmt(target)})  fromPos=${_fmt(_lastPosition)}  buf=${_fmt(_lastBuffer)}',
    );
    try {
      await _player.seek(target);
      _log('RETURN seek(${_fmt(target)}) OK');
    } catch (e) {
      _log('THROW seek(${_fmt(target)}) $e');
    }
  }

  static String _fmt(Duration d) {
    final int totalSec = d.inSeconds;
    final int h = totalSec ~/ 3600;
    final int m = (totalSec % 3600) ~/ 60;
    final int s = totalSec % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Single track')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _TrackHeader(source: SampleTracks.scienceFridayEpisode),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadAndPlay,
              icon: const Icon(Icons.download),
              label: const Text('loadAndPlay()'),
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
                    final CorePlayerState state =
                        stateSnap.data ?? CorePlayerState.idle;
                    return StreamBuilder<bool>(
                      stream: _player.playingStream,
                      initialData: _player.isPlaying,
                      builder:
                          (
                            BuildContext context,
                            AsyncSnapshot<bool> playingSnap,
                          ) {
                            return PlayPauseStopButtons(
                              state: state,
                              isPlaying: playingSnap.data ?? false,
                              onPlay: () => _player.play(),
                              onPause: () => _player.pause(),
                              onStop: () => _player.stop(),
                            );
                          },
                    );
                  },
            ),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              initialData: _player.position,
              builder:
                  (BuildContext context, AsyncSnapshot<Duration> posSnap) {
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
                                      duration: durSnap.data ?? Duration.zero,
                                      position: posSnap.data ?? Duration.zero,
                                      bufferedPosition:
                                          bufSnap.data ?? Duration.zero,
                                      onSeek: _seekTo,
                                    );
                                  },
                            );
                          },
                    );
                  },
            ),
            const SizedBox(height: 12),
            // Instrumentation: hardcoded seek buttons for deterministic repro.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                OutlinedButton(
                  onPressed: () => _seekTo(const Duration(minutes: 5)),
                  child: const Text('Seek 5m'),
                ),
                OutlinedButton(
                  onPressed: () => _seekTo(const Duration(minutes: 30)),
                  child: const Text('Seek 30m'),
                ),
                OutlinedButton(
                  onPressed: () => _seekTo(const Duration(hours: 1)),
                  child: const Text('Seek 1h'),
                ),
                OutlinedButton(
                  onPressed: () {
                    setState(_eventLog.clear);
                  },
                  child: const Text('Clear log'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            StreamBuilder<double>(
              stream: _player.playbackSpeedStream,
              initialData: _player.playbackSpeed,
              builder: (BuildContext context, AsyncSnapshot<double> snap) {
                return SpeedDropdown(
                  speed: snap.data ?? 1.0,
                  onChanged: _player.setPlaybackSpeed,
                );
              },
            ),
            const SizedBox(height: 8),
            StreamBuilder<double>(
              stream: _player.volumeStream,
              initialData: _player.volume,
              builder: (BuildContext context, AsyncSnapshot<double> snap) {
                return VolumeSlider(
                  volume: snap.data ?? 1.0,
                  onChanged: _player.setVolume,
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Text('Loop:'),
                StreamBuilder<CorePlayerLoopMode>(
                  stream: _player.loopModeStream,
                  initialData: _player.loopMode,
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<CorePlayerLoopMode> snap,
                      ) {
                        return LoopModeButton(
                          mode: snap.data ?? CorePlayerLoopMode.off,
                          onChanged: _player.setLoopMode,
                        );
                      },
                ),
              ],
            ),
            if (_lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Error: $_lastError',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            const SizedBox(height: 12),
            // In-app event log so we don't depend on terminal capture.
            // Bounded height + internal ListView so the log scrolls on its
            // own without forcing the outer ListView to grow unbounded.
            SizedBox(
              height: 240,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _eventLog.length,
                  itemBuilder: (BuildContext c, int i) {
                    final String line = _eventLog[i];
                    Color color = Colors.greenAccent;
                    if (line.contains('SEEK_RESOLVED')) {
                      color = Colors.yellowAccent;
                    } else if (line.contains('ERROR') ||
                        line.contains('THROW')) {
                      color = Colors.redAccent;
                    } else if (line.contains('STATE')) {
                      color = Colors.lightBlueAccent;
                    } else if (line.contains('CALL ')) {
                      color = Colors.orangeAccent;
                    }
                    return Text(
                      line,
                      style: TextStyle(
                        color: color,
                        fontFamily: 'monospace',
                        fontSize: 11,
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

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.source});

  final CorePlayerAudioSource source;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _CoverArt(artUri: source.artUri, size: 120),
        const SizedBox(height: 8),
        Text(
          source.title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (source.artist != null)
          Text(
            source.artist!,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 4),
        Text(
          source.url ?? source.filePath ?? '',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.grey),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Large square cover art for the single-track demo.
///
/// Falls back to a music-note placeholder when [artUri] is null, while loading,
/// or on error so a missing artwork never crashes or blanks the demo.
class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.artUri, required this.size});

  final Uri? artUri;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: size * 0.4,
        color: Colors.grey.shade600,
      ),
    );
    if (artUri == null) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          artUri.toString(),
          width: size,
          height: size,
          fit: BoxFit.cover,
          loadingBuilder:
              (BuildContext context, Widget child, ImageChunkEvent? progress) {
                if (progress == null) return child;
                return fallback;
              },
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stack) =>
                  fallback,
        ),
      ),
    );
  }
}
