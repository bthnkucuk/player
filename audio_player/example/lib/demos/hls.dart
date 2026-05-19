import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';

/// Demos the HLS audio source: hand a `.m3u8` manifest to the wrapper and
/// let libmpv's native HLS demuxer do the rest.
///
/// No special wrapper configuration — the `_toMedia` switch hands the
/// manifest URL straight to media_kit; libmpv detects the content-type and
/// engages its HLS pipeline (rolling-manifest refresh, gapless segment
/// transitions, ABR rendition switching).
class HlsDemo extends StatefulWidget {
  const HlsDemo({super.key});

  @override
  State<HlsDemo> createState() => _HlsDemoState();
}

class _HlsDemoState extends State<HlsDemo> {
  late final CorePlayer _player;
  StreamSubscription<CorePlayerFailure>? _errorSub;
  String? _lastError;

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

  Future<void> _startStream() async {
    setState(() => _lastError = null);
    try {
      await _player.loadAndPlay(SampleTracks.hlsLiveRadio);
    } on CorePlayerFailure catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  static String _fmt(Duration d) {
    final int totalSec = d.inSeconds;
    final int m = (totalSec ~/ 60).clamp(0, 99);
    final int s = totalSec % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HLS audio source')),
      // Outer ListView keeps the screen overflow-safe on narrow viewports.
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const _IntroCard(),
            const SizedBox(height: 12),
            Text(
              SampleTracks.hlsLiveRadio.title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (SampleTracks.hlsLiveRadio.artist != null)
              Text(
                SampleTracks.hlsLiveRadio.artist!,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _startStream,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Start stream'),
            ),
            const SizedBox(height: 12),
            StreamBuilder<CorePlayerState>(
              stream: _player.playerStateStream,
              initialData: _player.playerState,
              builder: (BuildContext context, AsyncSnapshot<CorePlayerState> stateSnap) {
                final CorePlayerState state =
                    stateSnap.data ?? CorePlayerState.idle;
                return StreamBuilder<bool>(
                  stream: _player.playingStream,
                  initialData: _player.isPlaying,
                  builder: (BuildContext context, AsyncSnapshot<bool> playingSnap) {
                    return PlayPauseStopButtons(
                      player: _player,
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
            const SizedBox(height: 12),
            // Position / duration display. For a live HLS stream duration
            // stays at 00:00 (unbounded); for VOD HLS the demuxer reports a
            // real duration after a brief buffer window.
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              initialData: _player.position,
              builder: (BuildContext context, AsyncSnapshot<Duration> posSnap) {
                return StreamBuilder<Duration>(
                  stream: _player.durationStream,
                  initialData: _player.duration,
                  builder: (BuildContext context, AsyncSnapshot<Duration> durSnap) {
                    final Duration pos = posSnap.data ?? Duration.zero;
                    final Duration dur = durSnap.data ?? Duration.zero;
                    return Text(
                      '${_fmt(pos)}  /  ${_fmt(dur)}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<CorePlayerState>(
              stream: _player.playerStateStream,
              initialData: _player.playerState,
              builder: (BuildContext context, AsyncSnapshot<CorePlayerState> snap) {
                final state = snap.data ?? CorePlayerState.idle;
                return Text(
                  'State: ${state.name}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                );
              },
            ),
            if (_lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Error: $_lastError',
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 16),
            const _ExpectedCard(),
          ],
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'What this demos',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'HLS (HTTP Live Streaming) is an adaptive bitrate streaming\n'
              'protocol: a small ".m3u8" manifest enumerates short media\n'
              'segments which the player fetches in order. media_kit\n'
              'detects the manifest content-type and routes through\n'
              'libmpv\'s native HLS demuxer — the wrapper just forwards\n'
              'the URL. No segment bookkeeping, no manifest refresh\n'
              'loop, no rendition picker on the Dart side.',
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
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Expected result',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'Expected result:\n'
              '- "Start stream" -> after a brief buffering window, audio plays.\n'
              '- For a live HLS stream, the position bar shows elapsed listening\n'
              '  time and the duration shows 00:00 (live = unbounded).\n'
              '- The stream survives a brief network blip because libmpv\'s HLS\n'
              '  demuxer reconnects automatically.\n'
              '- Pause + Play resumes from the current live edge (HLS semantics —\n'
              '  you don\'t get to scrub backward into the past unless the stream\n'
              '  is VOD).\n'
              '\n'
              'The bundled sample uses a VOD HLS rendition (audio-only AAC\n'
              'segments) so the demo is reliable offline of any live\n'
              'broadcaster; the live-stream semantics above describe what\n'
              'a rolling-manifest URL would behave like with the same code.',
            ),
          ],
        ),
      ),
    );
  }
}
