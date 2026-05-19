import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';
import '../widgets/seek_bar.dart';

/// Demonstrates the multi-scope API:
/// two independent `CoreAudioHandler` scopes ("main" / "preview"), each with its
/// own player. Both can play simultaneously; `requestSystemAudioFocus()`
/// transfers which scope owns the OS surface (lock-screen / MediaSession).
class MultiScopeDemo extends StatefulWidget {
  const MultiScopeDemo({super.key});

  @override
  State<MultiScopeDemo> createState() => _MultiScopeDemoState();
}

class _MultiScopeDemoState extends State<MultiScopeDemo> {
  late final CoreAudioHandler _mainScope;
  late final CoreAudioHandler _previewScope;
  late final CorePlayer _mainPlayer;
  late final CorePlayer _previewPlayer;

  @override
  void initState() {
    super.initState();
    // The default scope is the "main" scope — keep using it so lock-screen
    // controls work out of the box. The preview scope is a sibling.
    _mainScope = CoreAudioHandler.instance!;
    _previewScope = CoreAudioHandler(debugName: 'preview');
    _mainPlayer = CorePlayer.create(audioHandler: _mainScope);
    _previewPlayer = CorePlayer.create(audioHandler: _previewScope);
  }

  @override
  void dispose() {
    unawaited(_mainPlayer.dispose());
    unawaited(_previewPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-scope')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('Active OS surface scope', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      StreamBuilder<CoreAudioHandler?>(
                        stream: CoreAudioHandler.activeScopeStream,
                        initialData: CoreAudioHandler.activeScope,
                        builder: (BuildContext context, AsyncSnapshot<CoreAudioHandler?> snap) {
                          final String name = snap.data?.debugName ?? '(none)';
                          return Text(name, style: const TextStyle(fontFamily: 'monospace', fontSize: 16));
                        },
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Only the active scope drives the lock-screen / MediaSession. '
                        'Both scopes can play audio simultaneously.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _ScopePane(
                  title: 'main scope',
                  source: SampleTracks.scienceFridayEpisode,
                  player: _mainPlayer,
                  scope: _mainScope,
                ),
              ),
              const Divider(),
              Expanded(
                child: _ScopePane(
                  title: 'preview scope',
                  source: SampleTracks.soundHelix1,
                  player: _previewPlayer,
                  scope: _previewScope,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopePane extends StatelessWidget {
  const _ScopePane({required this.title, required this.source, required this.player, required this.scope});

  final String title;
  final CorePlayerAudioSource source;
  final CorePlayer player;
  final CoreAudioHandler scope;

  @override
  Widget build(BuildContext context) {
    // SingleChildScrollView so a single scope card can shrink without
    // overflowing when its share of the screen is smaller than the natural
    // height of title row + thumb + play row + seek bar (e.g. landscape).
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Give focus'),
                onPressed: () => scope.requestSystemAudioFocus(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              _ScopeThumbnail(artUri: source.artUri, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  source.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          StreamBuilder<CorePlayerState>(
            stream: player.playerStateStream,
            initialData: player.playerState,
            builder: (BuildContext context, AsyncSnapshot<CorePlayerState> stateSnap) {
              return StreamBuilder<bool>(
                stream: player.playingStream,
                initialData: player.isPlaying,
                builder: (BuildContext context, AsyncSnapshot<bool> playingSnap) {
                  return PlayPauseStopButtons(
                    player: player,
                    state: stateSnap.data ?? CorePlayerState.idle,
                    isPlaying: playingSnap.data ?? false,
                    onPlay: () async {
                      if (player.audioSource == null) {
                        await player.loadAndPlay(source);
                      } else {
                        await player.play();
                      }
                    },
                    onPause: () => player.pause(),
                    onStop: () => player.stop(),
                  );
                },
              );
            },
          ),
          StreamBuilder<Duration>(
            stream: player.positionStream,
            initialData: player.position,
            builder: (BuildContext context, AsyncSnapshot<Duration> posSnap) {
              return StreamBuilder<Duration>(
                stream: player.durationStream,
                initialData: player.duration,
                builder: (BuildContext context, AsyncSnapshot<Duration> durSnap) {
                  return StreamBuilder<Duration>(
                    stream: player.bufferStream,
                    initialData: player.buffer,
                    builder: (BuildContext context, AsyncSnapshot<Duration> bufSnap) {
                      return SeekBar(
                        duration: durSnap.data ?? Duration.zero,
                        position: posSnap.data ?? Duration.zero,
                        bufferedPosition: bufSnap.data ?? Duration.zero,
                        onSeek: player.seek,
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Small square thumbnail used in each scope card.
///
/// Provides graceful loading + error fallbacks so a missing artwork never
/// crashes the demo or blanks the scope card.
class _ScopeThumbnail extends StatelessWidget {
  const _ScopeThumbnail({required this.artUri, required this.size});

  final Uri? artUri;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.center,
      child: Icon(Icons.music_note, size: size * 0.5, color: Colors.grey.shade600),
    );
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
