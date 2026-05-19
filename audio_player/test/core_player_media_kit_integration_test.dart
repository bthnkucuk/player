import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

class _StreamHarness {
  final duration = StreamController<Duration>.broadcast();
  final position = StreamController<Duration>.broadcast();
  final buffer = StreamController<Duration>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final error = StreamController<String>.broadcast();
  final completed = StreamController<bool>.broadcast();
  final rate = StreamController<double>.broadcast();
  final volume = StreamController<double>.broadcast();
  final playlist = StreamController<Playlist>.broadcast();
  final shuffle = StreamController<bool>.broadcast();

  Future<void> close() async {
    await duration.close();
    await position.close();
    await buffer.close();
    await buffering.close();
    await playing.close();
    await error.close();
    await completed.close();
    await rate.close();
    await volume.close();
    await playlist.close();
    await shuffle.close();
  }
}

void _wire(MockPlayer mockPlayer, MockPlayerStream mockStream, MockPlayerState mockState, _StreamHarness h) {
  when(() => mockPlayer.stream).thenReturn(mockStream);
  when(() => mockPlayer.state).thenReturn(mockState);

  when(() => mockStream.duration).thenAnswer((_) => h.duration.stream);
  when(() => mockStream.position).thenAnswer((_) => h.position.stream);
  when(() => mockStream.buffer).thenAnswer((_) => h.buffer.stream);
  when(() => mockStream.buffering).thenAnswer((_) => h.buffering.stream);
  when(() => mockStream.playing).thenAnswer((_) => h.playing.stream);
  when(() => mockStream.error).thenAnswer((_) => h.error.stream);
  when(() => mockStream.completed).thenAnswer((_) => h.completed.stream);
  when(() => mockStream.rate).thenAnswer((_) => h.rate.stream);
  when(() => mockStream.volume).thenAnswer((_) => h.volume.stream);
  when(() => mockStream.playlist).thenAnswer((_) => h.playlist.stream);
  when(() => mockStream.shuffle).thenAnswer((_) => h.shuffle.stream);

  when(() => mockState.duration).thenReturn(Duration.zero);
  when(() => mockState.position).thenReturn(Duration.zero);
  when(() => mockState.buffer).thenReturn(Duration.zero);
  when(() => mockState.playing).thenReturn(false);
  when(() => mockState.rate).thenReturn(1.0);
  when(() => mockState.volume).thenReturn(100.0);

  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((_) async {});
  when(() => mockPlayer.play()).thenAnswer((_) async {});
  when(() => mockPlayer.pause()).thenAnswer((_) async {});
  when(() => mockPlayer.stop()).thenAnswer((_) async {});
  when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setRate(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setVolume(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setPlaylistMode(any())).thenAnswer((_) async {});
  when(() => mockPlayer.next()).thenAnswer((_) async {});
  when(() => mockPlayer.previous()).thenAnswer((_) async {});
  when(() => mockPlayer.jump(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setShuffle(any())).thenAnswer((_) async {});
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

void _rearm(MockPlayer mockPlayer, MockPlayerStream mockStream, MockPlayerState mockState, _StreamHarness h) {
  reset(mockPlayer);
  _wire(mockPlayer, mockStream, mockState, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late _StreamHarness h;
  late CoreAudioHandler handler;
  late CoreMediaKitAudioServiceBridge bridge;
  late CorePlayerMediaKit player;

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
  });

  setUp(() {
    bridge = installTestBridge();
    mockPlayer = MockPlayer();
    mockStream = MockPlayerStream();
    mockState = MockPlayerState();
    h = _StreamHarness();
    _wire(mockPlayer, mockStream, mockState, h);
    handler = CoreAudioHandler.instance!;
    player = CorePlayerMediaKit(testPlayer: mockPlayer, audioHandler: handler);
  });

  tearDown(() async {
    if (!player.isDisposed) {
      await player.dispose();
    }
    await h.close();
  });

  group('CorePlayerMediaKit + CoreAudioHandler integration', () {
    test('attachPlayer sets the media-kit instance as current player', () {
      expect(CoreAudioHandler.isCurrentPlayer(player), isTrue);
      expect(player.currentAudioHandler, same(handler));
    });

    test('handler.play event invokes player.play when current', () async {
      await player.load(CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'));
      _rearm(mockPlayer, mockStream, mockState, h);

      handler.debugPostEvent(CoreAudioHandlerPlayEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      verify(() => mockPlayer.play()).called(1);
    });

    test('handler.pause event invokes player.pause when current', () async {
      handler.debugPostEvent(CoreAudioHandlerPauseEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(() => mockPlayer.pause()).called(1);
    });

    test('handler.seek event invokes player.seek when current', () async {
      when(() => mockState.duration).thenReturn(const Duration(seconds: 100));
      handler.debugPostEvent(CoreAudioHandlerSeekEvent(const Duration(seconds: 30)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(() => mockPlayer.seek(const Duration(seconds: 30))).called(1);
    });

    test('handler.stop event drives seek-zero + pause path', () async {
      handler.debugPostEvent(CoreAudioHandlerStopEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(() => mockPlayer.seek(Duration.zero)).called(1);
      verify(() => mockPlayer.pause()).called(1);
    });

    test('events are ignored when player is not current', () async {
      final src = CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3');
      await player.load(src);

      final otherPlayer = MockPlayer();
      final otherStream = MockPlayerStream();
      final otherState = MockPlayerState();
      final otherH = _StreamHarness();
      _wire(otherPlayer, otherStream, otherState, otherH);
      final other = CorePlayerMediaKit(testPlayer: otherPlayer, audioHandler: handler);
      await other.load(src);
      addTearDown(() async {
        await other.dispose();
        await otherH.close();
      });

      expect(CoreAudioHandler.isCurrentPlayer(player), isFalse);
      expect(CoreAudioHandler.isCurrentPlayer(other), isTrue);
      _rearm(mockPlayer, mockStream, mockState, h);
      reset(otherPlayer);
      _wire(otherPlayer, otherStream, otherState, otherH);

      handler.debugPostEvent(CoreAudioHandlerPauseEvent());
      handler.debugPostEvent(CoreAudioHandlerSeekEvent(const Duration(seconds: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      verifyNever(() => mockPlayer.pause());
      verifyNever(() => mockPlayer.seek(any()));
      verify(() => otherPlayer.pause()).called(1);
    });

    test('player streams flow up to bridge.playbackState when current', () async {
      final f = bridge.playbackState.firstWhere((s) => s.playing == true);
      h.duration.add(const Duration(seconds: 10));
      h.buffer.add(const Duration(seconds: 5));
      h.playing.add(true);
      h.position.add(const Duration(seconds: 1));
      final state = await f.timeout(const Duration(seconds: 1));
      expect(state.playing, isTrue);
      expect(state.bufferedPosition, const Duration(seconds: 5));
    });

    test('play() re-attaches non-current player and emits mediaItem', () async {
      final src = CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3');
      await player.load(src);

      final otherPlayer = MockPlayer();
      final otherStream = MockPlayerStream();
      final otherState = MockPlayerState();
      final otherH = _StreamHarness();
      _wire(otherPlayer, otherStream, otherState, otherH);
      final other = CorePlayerMediaKit(testPlayer: otherPlayer, audioHandler: handler);
      await other.load(src);
      addTearDown(() async {
        await other.dispose();
        await otherH.close();
      });

      expect(CoreAudioHandler.isCurrentPlayer(player), isFalse);
      await player.play();
      expect(CoreAudioHandler.isCurrentPlayer(player), isTrue);
      expect(bridge.mediaItem.value?.id, src.url);
    });

    test('dispose detaches cleanly', () async {
      expect(CoreAudioHandler.isCurrentPlayer(player), isTrue);
      await player.dispose();
      expect(CoreAudioHandler.isCurrentPlayer(player), isFalse);
      expect(player.isDisposed, isTrue);
    });
  });
}
