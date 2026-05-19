import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Smoke tests for the [CorePlayerCapabilities] surface advertised by
/// [CorePlayerMediaKit]. Pinned to the wrapper's documented engine-capability
/// model: flags reflect what the libmpv-backed engine fundamentally supports,
/// not what is currently wired in any given branch.
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
    debugSetLibmpvOptionsApplierForTest(null);
  });

  tearDown(() {
    debugSetLibmpvOptionsApplierForTest(null);
  });

  group('CorePlayerMediaKit.capabilities', () {
    late MockPlayer mockPlayer;
    late MockPlayerStream mockStream;
    late MockPlayerState mockState;
    late _StreamHarness h;
    late CorePlayerMediaKit player;

    setUp(() {
      mockPlayer = MockPlayer();
      mockStream = MockPlayerStream();
      mockState = MockPlayerState();
      h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);
      debugSetLibmpvOptionsApplierForTest((player, options) async {});
      player = CorePlayerMediaKit(testPlayer: mockPlayer);
    });

    tearDown(() async {
      await player.dispose();
      await h.close();
    });

    test('supportsHls is true (libmpv handles HLS manifests natively)', () {
      expect(player.capabilities.supportsHls, isTrue);
    });

    test('supportsLiveSource is true (engine has the playlist primitive)', () {
      expect(player.capabilities.supportsLiveSource, isTrue);
    });

    test('supportsCrossfade is false (deferred per ROADMAP)', () {
      expect(player.capabilities.supportsCrossfade, isFalse);
    });

    test('supportsCast is false (libmpv has no cast pipeline)', () {
      expect(player.capabilities.supportsCast, isFalse);
    });

    test('supportsDrm is false (no DRM today)', () {
      expect(player.capabilities.supportsDrm, isFalse);
    });

    test(
      'supportsEqualizer is true (wrapper exposes setEqualizerBands via '
      'libmpv af=equalizer=...)',
      () {
        expect(player.capabilities.supportsEqualizer, isTrue);
      },
    );

    test(
      'getter does not allocate a new instance per call — cached constant',
      () {
        final first = player.capabilities;
        final second = player.capabilities;
        expect(
          identical(first, second),
          isTrue,
          reason:
              'capabilities should return a cached instance; repeated reads '
              'from per-frame UI must not churn the allocator',
        );
      },
    );
  });
}
