import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Verifies the factory-registration shape used by [CorePlayerMediaKit.ensureInitialized].
///
/// We do NOT call `CorePlayerMediaKit.ensureInitialized()` here: it triggers
/// `MediaKit.ensureInitialized()` which loads `Mpv.framework` and fails outside
/// a real app process. The unit under test is the factory glue itself — that
/// `CorePlayer.create(...)` round-trips through a registered factory and
/// constructs a working [CorePlayerMediaKit].
void main() {
  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
  });

  setUp(CorePlayer.debugClearFactory);
  tearDown(CorePlayer.debugClearFactory);

  group('CorePlayerMediaKit factory registration', () {
    test('registered factory builds a CorePlayerMediaKit via CorePlayer.create', () async {
      // Mirror what `CorePlayerMediaKit.ensureInitialized()` registers, but use
      // an injected mock Player so the test does not touch native code.
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();

      when(() => mockPlayer.stream).thenReturn(mockStream);
      when(() => mockPlayer.state).thenReturn(mockState);
      when(() => mockStream.duration).thenAnswer((_) => const Stream<Duration>.empty());
      when(() => mockStream.position).thenAnswer((_) => const Stream<Duration>.empty());
      when(() => mockStream.buffer).thenAnswer((_) => const Stream<Duration>.empty());
      when(() => mockStream.buffering).thenAnswer((_) => const Stream<bool>.empty());
      when(() => mockStream.playing).thenAnswer((_) => const Stream<bool>.empty());
      when(() => mockStream.error).thenAnswer((_) => const Stream<String>.empty());
      when(() => mockStream.completed).thenAnswer((_) => const Stream<bool>.empty());
      when(() => mockStream.rate).thenAnswer((_) => const Stream<double>.empty());
      when(() => mockStream.volume).thenAnswer((_) => const Stream<double>.empty());
      when(() => mockStream.playlist).thenAnswer((_) => const Stream<Playlist>.empty());
      when(() => mockStream.shuffle).thenAnswer((_) => const Stream<bool>.empty());
      when(() => mockState.rate).thenReturn(1.0);
      when(() => mockState.volume).thenReturn(100.0);
      when(() => mockState.duration).thenReturn(Duration.zero);
      when(() => mockPlayer.dispose()).thenAnswer((_) async {});
      when(() => mockPlayer.stop()).thenAnswer((_) async {});
      when(() => mockPlayer.pause()).thenAnswer((_) async {});
      when(() => mockPlayer.seek(any())).thenAnswer((_) async {});

      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
        return CorePlayerMediaKit(
          audioSource: audioSource,
          audioHandler: audioHandler,
          autoLoad: autoLoad,
          testPlayer: mockPlayer,
        );
      });

      expect(CorePlayer.isFactoryRegistered, isTrue);

      final player = CorePlayer.create();
      expect(player, isA<CorePlayerMediaKit>());
      await player.dispose();
    });

    test('isFactoryRegistered is false before any registration', () {
      expect(CorePlayer.isFactoryRegistered, isFalse);
      expect(CorePlayer.create, throwsA(isA<StateError>()));
    });
  });
}
