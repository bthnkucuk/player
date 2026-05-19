import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';
import 'package:audio_player/audio_player.dart';

import '../helpers/test_mocks.dart';
import '_helpers/stream_harness.dart';

void _rearm(MockPlayer mockPlayer, MockPlayerStream mockStream, MockPlayerState mockState, StreamHarness h) {
  reset(mockPlayer);
  wirePlayer(mockPlayer, mockStream, mockState, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
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

  group('Bidirectional event routing between CoreAudioHandler and CorePlayerMediaKit', () {
    test('handler.play / pause / seek / stop emit events that the player consumes '
        'in the same order', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      _rearm(mockPlayer, mockStream, mockState, h);

      await bridge.play();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await bridge.pause();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      when(() => mockState.duration).thenReturn(const Duration(seconds: 100));
      await bridge.seek(const Duration(seconds: 25));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await bridge.stop();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verify(() => mockPlayer.play()).called(1);
      verify(() => mockPlayer.pause()).called(2);
      verify(() => mockPlayer.seek(const Duration(seconds: 25))).called(1);
      verify(() => mockPlayer.seek(Duration.zero)).called(1);
    });

    test('completed=true upstream sets needToLoad; subsequent handler.play() '
        'triggers a re-load on the underlying Player', () async {
      final src = HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3'));
      await player.load(src);
      expect(player.needToLoad, isFalse);

      await player.stop();
      expect(player.needToLoad, isTrue);

      _rearm(mockPlayer, mockStream, mockState, h);

      await bridge.play();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verify(() => mockPlayer.open(any(), play: false)).called(1);
      verify(() => mockPlayer.play()).called(1);
    });

    test('setPlaybackSpeed(1.5) forwards to player.setRate AND playbackSpeedStream '
        'emits the new rate', () async {
      when(() => mockState.rate).thenReturn(1.5);
      final f = player.playbackSpeedStream.firstWhere((r) => r == 1.5).timeout(const Duration(seconds: 1));

      await player.setPlaybackSpeed(1.5);

      verify(() => mockPlayer.setRate(1.5)).called(1);
      expect(await f, 1.5);
      expect(player.playbackSpeed, 1.5);
    });

    test('InterruptionBegin while playing causes the impl to pause', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      // Pretend we are playing.
      when(() => mockState.playing).thenReturn(true);
      h.playing.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      _rearm(mockPlayer, mockStream, mockState, h);
      when(() => mockState.playing).thenReturn(true);
      h.playing.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      handler.debugPostEvent(CoreAudioHandlerInterruptionBeginEvent(CoreAudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verify(() => mockPlayer.pause()).called(1);
    });

    test('InterruptionEnd(shouldResume: true) causes the impl to play', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      _rearm(mockPlayer, mockStream, mockState, h);

      handler.debugPostEvent(CoreAudioHandlerInterruptionEndEvent(shouldResume: true));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verify(() => mockPlayer.play()).called(1);
    });

    test('InterruptionEnd(shouldResume: false) does NOT play', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      _rearm(mockPlayer, mockStream, mockState, h);

      handler.debugPostEvent(CoreAudioHandlerInterruptionEndEvent(shouldResume: false));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verifyNever(() => mockPlayer.play());
    });

    test('BecomingNoisy while playing causes the impl to pause', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      when(() => mockState.playing).thenReturn(true);
      h.playing.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      _rearm(mockPlayer, mockStream, mockState, h);
      when(() => mockState.playing).thenReturn(true);
      h.playing.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      handler.debugPostEvent(CoreAudioHandlerBecomingNoisyEvent());
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verify(() => mockPlayer.pause()).called(1);
    });

    test('AppResume is a no-op (best-effort fallback only)', () async {
      await player.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      _rearm(mockPlayer, mockStream, mockState, h);

      handler.debugPostEvent(CoreAudioHandlerAppResumeEvent());
      await Future<void>.delayed(const Duration(milliseconds: 30));

      verifyNever(() => mockPlayer.play());
      verifyNever(() => mockPlayer.pause());
    });

    test('handler events targeting a non-current player are ignored by that '
        'instance even when the player is fully attached', () async {
      final mp2 = MockPlayer();
      final ms2 = MockPlayerStream();
      final mst2 = MockPlayerState();
      final h2 = StreamHarness();
      wirePlayer(mp2, ms2, mst2, h2);
      final p2 = CorePlayerMediaKit(testPlayer: mp2, audioHandler: handler);
      await p2.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      addTearDown(() async {
        if (!p2.isDisposed) await p2.dispose();
        await h2.close();
      });

      expect(CoreAudioHandler.isCurrentPlayer(player), isFalse);
      expect(CoreAudioHandler.isCurrentPlayer(p2), isTrue);
      _rearm(mockPlayer, mockStream, mockState, h);
      reset(mp2);
      wirePlayer(mp2, ms2, mst2, h2);

      handler.debugPostEvent(CoreAudioHandlerPlayEvent());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      verifyNever(() => mockPlayer.play());
      verify(() => mp2.play()).called(1);

      _rearm(mockPlayer, mockStream, mockState, h);
      reset(mp2);
      wirePlayer(mp2, ms2, mst2, h2);
      handler.debugPostEvent(CoreAudioHandlerPauseEvent());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      verifyNever(() => mockPlayer.pause());
      verify(() => mp2.pause()).called(1);

      when(() => mst2.duration).thenReturn(const Duration(seconds: 120));
      _rearm(mockPlayer, mockStream, mockState, h);
      reset(mp2);
      wirePlayer(mp2, ms2, mst2, h2);
      when(() => mst2.duration).thenReturn(const Duration(seconds: 120));
      handler.debugPostEvent(CoreAudioHandlerSeekEvent(const Duration(seconds: 7)));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      verifyNever(() => mockPlayer.seek(any()));
      verify(() => mp2.seek(const Duration(seconds: 7))).called(1);
    });
  });
}
