import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';
import 'package:audio_player/audio_player.dart';

import '../helpers/test_mocks.dart';
import '_helpers/stream_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
    // Disable internal position throttle in tests so the playerState
    // combineLatest5 fires synchronously off single position emits.
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(const CorePlayerConfiguration());
  });

  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late StreamHarness h;
  late CoreAudioHandler handler;
  late CoreMediaKitAudioServiceBridge bridge;
  late CorePlayerMediaKit player;

  setUp(() {
    detachAllPlayers();
    bridge = installTestBridge();
    mockPlayer = MockPlayer();
    mockStream = MockPlayerStream();
    mockState = MockPlayerState();
    h = StreamHarness();
    wirePlayer(mockPlayer, mockStream, mockState, h);
    handler = CoreAudioHandler.instance!;
    player = CorePlayerMediaKit(testPlayer: mockPlayer, audioHandler: handler);
  });

  tearDown(() async {
    if (!player.isDisposed) {
      await player.dispose();
    }
    await h.close();
    detachAllPlayers();
  });

  group('PlaybackState propagation: media_kit Player -> CorePlayerMediaKit -> CoreAudioHandler.playbackState', () {
    test('buffer > position emits AudioProcessingState.ready and bufferedPosition '
        'reflects upstream value', () async {
      // Load a source so the `_audioSource == null` idle guard doesn't
      // short-circuit the state machine before the ready branch fires.
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));

      final f = bridge.playbackState
          .firstWhere((s) => s.processingState == AudioProcessingState.ready)
          .timeout(const Duration(seconds: 1));

      h.duration.add(const Duration(seconds: 30));
      h.buffer.add(const Duration(seconds: 10));
      h.buffering.add(false);
      h.playing.add(true);
      h.position.add(const Duration(seconds: 1));

      final state = await f;
      expect(state.processingState, AudioProcessingState.ready);
      expect(state.bufferedPosition, const Duration(seconds: 10));
      expect(state.playing, isTrue);
    });

    test('completed=true upstream emits AudioProcessingState.completed downstream', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));

      final f = bridge.playbackState
          .firstWhere((s) => s.processingState == AudioProcessingState.completed)
          .timeout(const Duration(seconds: 1));

      h.duration.add(const Duration(seconds: 5));
      h.position.add(const Duration(seconds: 5));
      h.buffer.add(const Duration(seconds: 5));
      h.buffering.add(false);
      h.playing.add(false);
      h.completed.add(true);

      final state = await f;
      expect(state.processingState, AudioProcessingState.completed);
    });

    test('upstream error emits AudioProcessingState.error AND flips needToLoad=true', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));

      final f = bridge.playbackState
          .firstWhere((s) => s.processingState == AudioProcessingState.error)
          .timeout(const Duration(seconds: 1));

      h.error.add('boom');
      h.buffer.add(Duration.zero);
      h.position.add(Duration.zero);
      h.playing.add(false);

      final state = await f;
      expect(state.processingState, AudioProcessingState.error);
      expect(player.needToLoad, isTrue);
    });

    test('buffer <= position with no completion emits AudioProcessingState.loading', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));

      final f = bridge.playbackState
          .firstWhere((s) => s.processingState == AudioProcessingState.loading)
          .timeout(const Duration(seconds: 1));

      // State machine: buffer NOT > position AND no error AND not completed
      // -> loading. Seed all combineLatest5 sources so the combine fires.
      h.buffer.add(Duration.zero);
      h.position.add(Duration.zero);
      h.playing.add(false);
      h.completed.add(false);

      final state = await f;
      expect(state.processingState, AudioProcessingState.loading);
    });

    test('streams from a NON-current player do NOT mutate bridge.playbackState', () async {
      // Build a second player; it becomes current and demotes `player`.
      final mp2 = MockPlayer();
      final ms2 = MockPlayerStream();
      final mst2 = MockPlayerState();
      final h2 = StreamHarness();
      wirePlayer(mp2, ms2, mst2, h2);
      final p2 = CorePlayerMediaKit(testPlayer: mp2, audioHandler: handler);
      addTearDown(() async {
        if (!p2.isDisposed) await p2.dispose();
        await h2.close();
      });

      expect(CoreAudioHandler.isCurrentPlayer(player), isFalse);
      expect(CoreAudioHandler.isCurrentPlayer(p2), isTrue);

      // Capture the playbackState snapshot before driving non-current streams.
      final before = bridge.playbackState.value;
      final emissions = <PlaybackState>[];
      final sub = bridge.playbackState.listen(emissions.add);

      // Drive `player`'s harness (NOT current). Production guards on
      // isCurrentPlayer(this) before pushing to bridge.playbackState.
      h.duration.add(const Duration(seconds: 99));
      h.buffer.add(const Duration(seconds: 50));
      h.position.add(const Duration(seconds: 1));
      h.playing.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await sub.cancel();

      // Either no new emissions, or every emission still has the previous
      // bufferedPosition (i.e., the harness for `player` did NOT propagate).
      for (final s in emissions) {
        expect(s.bufferedPosition, isNot(const Duration(seconds: 50)));
      }
      // The handler value must not have adopted player's 50s buffer.
      expect(bridge.playbackState.value.bufferedPosition, isNot(const Duration(seconds: 50)));
      // Strong assertion: the snapshot before == snapshot after w.r.t. buffer.
      expect(bridge.playbackState.value.bufferedPosition, before.bufferedPosition);
    });

    test('load(audioSource) followed by play() pushes a MediaItem with the '
        'expected metadata onto bridge.mediaItem', () async {
      final src = HttpAudioSource(
        title: 'Episode 1',
        artist: 'Host',
        url: Uri.parse('https://example.com/ep1.mp3'),
      );
      await player.load(src);
      await player.play();

      final mi = bridge.mediaItem.value;
      expect(mi, isNotNull);
      // MediaItem.id stores the URL as a String; the sealed source carries
      // a Uri. Compare via toString().
      expect(mi!.id, src.url.toString());
      expect(mi.title, 'Episode 1');
      expect(mi.artist, 'Host');
    });
  });
}
