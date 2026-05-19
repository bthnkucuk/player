import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Demonstrates the queue API:
/// `setQueue`, `skipToNext`, `skipToPrevious`, `skipToIndex`, `setShuffle`,
/// loop mode (off / one / all), `queueStream`.
class PlaylistDemo extends StatefulWidget {
  const PlaylistDemo({super.key});

  @override
  State<PlaylistDemo> createState() => _PlaylistDemoState();
}

class _PlaylistDemoState extends State<PlaylistDemo> {
  late final CorePlayer _player;
  StreamSubscription<CorePlayerFailure>? _errorSub;
  String? _lastError;
  bool _queueLoaded = false;

  @override
  void initState() {
    super.initState();
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _errorSub = _player.errorStream.listen((CorePlayerFailure failure) {
      if (!mounted) return;
      setState(() => _lastError = failure.toString());
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _loadQueue() async {
    setState(() => _lastError = null);
    try {
      await _player.setQueue(CorePlayerQueue(SampleTracks.playlist));
      setState(() => _queueLoaded = true);
      await _player.play();
    } on CorePlayerFailure catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } on CorePlayerFailure catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: _loadQueue,
                    icon: const Icon(Icons.queue_music),
                    label: Text(_queueLoaded ? 'Reload queue' : 'Load ${SampleTracks.playlist.length}-track queue'),
                  ),
                  StreamBuilder<CorePlayerState>(
                    stream: _player.playerStateStream,
                    initialData: _player.playerState,
                    builder: (BuildContext context, AsyncSnapshot<CorePlayerState> stateSnap) {
                      return StreamBuilder<bool>(
                        stream: _player.playingStream,
                        initialData: _player.isPlaying,
                        builder: (BuildContext context, AsyncSnapshot<bool> playingSnap) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              IconButton(
                                iconSize: 40,
                                icon: const Icon(Icons.skip_previous),
                                onPressed: () => _safe(_player.skipToPrevious),
                              ),
                              PlayPauseStopButtons(
                                state: stateSnap.data ?? CorePlayerState.idle,
                                isPlaying: playingSnap.data ?? false,
                                onPlay: () => _safe(_player.play),
                                onPause: () => _safe(_player.pause),
                                onStop: () => _safe(_player.stop),
                                showStop: false,
                              ),
                              IconButton(
                                iconSize: 40,
                                icon: const Icon(Icons.skip_next),
                                onPressed: () => _safe(_player.skipToNext),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  StreamBuilder<Duration>(
                    stream: _player.positionStream,
                    initialData: _player.position,
                    builder: (BuildContext context, AsyncSnapshot<Duration> posSnap) {
                      return StreamBuilder<Duration>(
                        stream: _player.durationStream,
                        initialData: _player.duration,
                        builder: (BuildContext context, AsyncSnapshot<Duration> durSnap) {
                          return StreamBuilder<Duration>(
                            stream: _player.bufferStream,
                            initialData: _player.buffer,
                            builder: (BuildContext context, AsyncSnapshot<Duration> bufSnap) {
                              return SeekBar(
                                duration: durSnap.data ?? Duration.zero,
                                position: posSnap.data ?? Duration.zero,
                                bufferedPosition: bufSnap.data ?? Duration.zero,
                                onSeek: _player.seek,
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      StreamBuilder<CorePlayerLoopMode>(
                        stream: _player.loopModeStream,
                        initialData: _player.loopMode,
                        builder: (BuildContext context, AsyncSnapshot<CorePlayerLoopMode> snap) {
                          return LoopModeButton(
                            mode: snap.data ?? CorePlayerLoopMode.off,
                            onChanged: _player.setLoopMode,
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      StreamBuilder<bool>(
                        stream: _player.shuffleStream,
                        initialData: _player.shuffle,
                        builder: (BuildContext context, AsyncSnapshot<bool> snap) {
                          return ShuffleButton(enabled: snap.data ?? false, onChanged: _player.setShuffle);
                        },
                      ),
                    ],
                  ),
                  if (_lastError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Error: $_lastError', style: const TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<CorePlayerQueue>(
                stream: _player.queueStream,
                initialData: _player.queue,
                builder: (BuildContext context, AsyncSnapshot<CorePlayerQueue> snap) {
                  final CorePlayerQueue queue = snap.data ?? const CorePlayerQueue.empty();
                  if (queue.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Queue is empty. Tap "Load queue" above.'),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: queue.length,
                    itemBuilder: (BuildContext context, int index) {
                      final CorePlayerAudioSource source = queue[index];
                      final bool isCurrent = index == queue.currentIndex;
                      return ListTile(
                        key: ValueKey<int>(index),
                        leading: _TrackArtwork(artUri: source.artUri, size: 56, isCurrent: isCurrent, index: index),
                        title: Text(
                          source.title,
                          style: TextStyle(fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal),
                        ),
                        subtitle: source.artist == null ? null : Text(source.artist!),
                        trailing: isCurrent ? const Icon(Icons.equalizer) : null,
                        onTap: () => _safe(() => _player.skipToIndex(index)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square artwork thumbnail used in the playlist rows.
///
/// Falls back to a numbered circular avatar when [artUri] is null, fails to
/// load, or is still loading. The fallback uses the current-track highlight
/// color so the row still reads correctly without art.
class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({required this.artUri, required this.size, required this.isCurrent, required this.index});

  final Uri? artUri;
  final double size;
  final bool isCurrent;
  final int index;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = _Fallback(size: size, isCurrent: isCurrent, index: index);
    if (artUri == null) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          artUri.toString(),
          width: size,
          height: size,
          fit: BoxFit.cover,
          loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? progress) {
            if (progress == null) return child;
            return fallback;
          },
          errorBuilder: (BuildContext context, Object error, StackTrace? stack) => fallback,
        ),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.size, required this.isCurrent, required this.index});

  final double size;
  final bool isCurrent;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isCurrent ? Theme.of(context).colorScheme.primary : Colors.grey.shade300,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        '${index + 1}',
        style: TextStyle(color: isCurrent ? Colors.white : Colors.black, fontWeight: FontWeight.bold),
      ),
    );
  }
}
