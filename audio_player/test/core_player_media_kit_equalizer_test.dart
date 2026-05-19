import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
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

void _wireMockStreams(
  MockPlayer mockPlayer,
  MockPlayerStream mockStream,
  MockPlayerState mockState,
  _StreamHarness h,
) {
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

  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
  when(() => mockPlayer.stop()).thenAnswer((_) async {});
  when(() => mockPlayer.pause()).thenAnswer((_) async {});
  when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
}

void main() {
  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
    debugSetEqualizerApplierForTest(null);
    debugSetLibmpvOptionsApplierForTest(null);
  });

  group('CorePlayerMediaKit equalizer', () {
    late MockPlayer mockPlayer;
    late MockPlayerStream mockStream;
    late MockPlayerState mockState;
    late _StreamHarness h;
    // Captured (player, afSpec) pairs from the equalizer applier seam so each
    // assertion can inspect the exact libmpv property string the wrapper
    // would have pushed at native.
    late List<String> capturedSpecs;

    setUp(() {
      mockPlayer = MockPlayer();
      mockStream = MockPlayerStream();
      mockState = MockPlayerState();
      h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);

      // Silence the unrelated libmpv options applier so the constructor's
      // fire-and-forget property push doesn't touch the real applier.
      debugSetLibmpvOptionsApplierForTest((_, __) async {});

      capturedSpecs = <String>[];
      debugSetEqualizerApplierForTest((player, spec) async {
        capturedSpecs.add(spec);
      });

      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
      );
    });

    tearDown(() async {
      await h.close();
      debugSetEqualizerApplierForTest(null);
      debugSetLibmpvOptionsApplierForTest(null);
    });

    test('capabilities.supportsEqualizer is true', () async {
      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      expect(p.capabilities.supportsEqualizer, isTrue);
      await p.dispose();
    });

    test('default equalizerBands is ten zeros', () async {
      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      expect(p.equalizerBands, hasLength(10));
      expect(p.equalizerBands.every((g) => g == 0.0), isTrue);
      await p.dispose();
    });

    test(
      'setEqualizerBands([0, ...]) pushes af=equalizer=0.0:0.0:...:0.0 at native',
      () async {
        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        await p.setEqualizerBands(const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        expect(capturedSpecs, isNotEmpty);
        expect(
          capturedSpecs.last,
          'equalizer=0.0:0.0:0.0:0.0:0.0:0.0:0.0:0.0:0.0:0.0',
        );
        await p.dispose();
      },
    );

    test(
      'setEqualizerBands with fewer than 10 elements throws InvalidEqualizerInputFailure',
      () async {
        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        expect(
          () => p.setEqualizerBands(const [0, 0, 0, 0, 0, 0, 0, 0, 0]),
          throwsA(isA<InvalidEqualizerInputFailure>()),
        );
        await p.dispose();
      },
    );

    test(
      'setEqualizerBands with more than 10 elements throws InvalidEqualizerInputFailure',
      () async {
        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        expect(
          () => p.setEqualizerBands(const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
          throwsA(isA<InvalidEqualizerInputFailure>()),
        );
        await p.dispose();
      },
    );

    test(
      'gains outside [-12, 12] are clamped in both the native spec and the subject',
      () async {
        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        await p.setEqualizerBands(const [20, -20, 5, -5, 13, -13, 0, 12, -12, 1.5]);
        // The native applier sees clamped values, not the raw input.
        expect(
          capturedSpecs.last,
          'equalizer=12.0:-12.0:5.0:-5.0:12.0:-12.0:0.0:12.0:-12.0:1.5',
        );
        // Subject mirrors the clamped values.
        expect(
          p.equalizerBands,
          [12.0, -12.0, 5.0, -5.0, 12.0, -12.0, 0.0, 12.0, -12.0, 1.5],
        );
        await p.dispose();
      },
    );

    test('equalizerBandsStream emits each set as a fresh list', () async {
      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      final emitted = <List<double>>[];
      // The subject is seeded with ten zeros — drop that initial emit so the
      // assertion focuses on post-set values.
      final sub = p.equalizerBandsStream.skip(1).listen(emitted.add);

      await p.setEqualizerBands(const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      await p.setEqualizerBands(const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      // Allow rxdart to flush the synchronous adds.
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted[0], [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]);
      expect(emitted[1], List<double>.filled(10, 0.0));

      await sub.cancel();
      await p.dispose();
    });

    test(
      'after dispose: equalizerBands subject is closed and setEqualizerBands throws PlayerDisposedFailure',
      () async {
        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        await p.dispose();
        expect(
          () => p.setEqualizerBands(const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      },
    );
  });
}
