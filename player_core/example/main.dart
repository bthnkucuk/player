// This is a documentation snippet, not a runnable file.
// The player_core package is an abstraction — pair with a concrete impl
// (e.g. audio_player) to actually play audio.
//
// For a runnable Flutter example, see
// `packages/player_core/audio_player/example/`.

import 'package:player_core/player_core.dart';

Future<void> demo() async {
  // After your impl's `ensureInitialized()`:
  await CoreAudioHandler.initialize();

  final player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);

  // Single-track convenience.
  final source = HttpAudioSource(
    title: 'Demo Track',
    artist: 'Demo Artist',
    url: Uri.parse('https://example.com/audio.mp3'),
  );
  // Single-flight: rapid double-taps coalesce to one in-flight Future.
  await player.loadAndPlay(source);

  // Or queue-based playback (Phase 10+):
  final queue = CorePlayerQueue(<CoreAudioSource>[
    HttpAudioSource(
      title: 'Track 1',
      url: Uri.parse('https://example.com/1.mp3'),
    ),
    HttpAudioSource(
      title: 'Track 2',
      url: Uri.parse('https://example.com/2.mp3'),
    ),
  ]);
  await player.setQueue(queue);
  await player.play();

  // Loop modes: off / one / all. Auto-advance respects loopMode.
  await player.setLoopMode(CorePlayerLoopMode.all);

  // Shuffle traverses the queue in randomized order (Phase 11).
  await player.setShuffle(true);

  // Observe state:
  player.playerStateStream.listen((s) => print('state=$s'));
  player.positionStream.listen((p) => print('position=$p'));
  player.queueStream.listen(
    (q) => print('queue.currentIndex=${q.currentIndex}'),
  );

  // Multi-scope (Phase 13): independent audio paths. Only the active scope
  // owns the lock-screen / MediaSession; players in other scopes keep playing.
  final preview = CoreAudioHandler(debugName: 'preview');
  final previewPlayer = CorePlayer.create(audioHandler: preview);
  await preview.requestSystemAudioFocus(); // hand the OS surface to "preview".

  // ... later:
  await previewPlayer.dispose();
  await player.dispose();
}
