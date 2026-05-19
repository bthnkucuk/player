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
  // Stubbed for the dispose() call inside test teardown: stop(fromDispose)
  // runs `player.stop()` then `currentAudioHandler?.emitPlaybackState(...)`.
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
    CorePlayerMediaKit.debugSetConfigurationForTest(const CorePlayerConfiguration());
    debugSetLibmpvOptionsApplierForTest(null);
  });

  group('libmpvOptions', () {
    late MockPlayer mockPlayer;
    late MockPlayerStream mockStream;
    late MockPlayerState mockState;
    late _StreamHarness h;
    late List<Map<String, String>> appliedMaps;

    setUp(() {
      mockPlayer = MockPlayer();
      mockStream = MockPlayerStream();
      mockState = MockPlayerState();
      h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);

      appliedMaps = <Map<String, String>>[];
      debugSetLibmpvOptionsApplierForTest((player, options) async {
        // Capture a defensive copy so later mutations cannot bleed in.
        appliedMaps.add(Map<String, String>.from(options));
      });
    });

    tearDown(() async {
      await h.close();
      debugSetLibmpvOptionsApplierForTest(null);
      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
      );
    });

    test('CorePlayerConfiguration.libmpvOptions defaults to null', () {
      const config = CorePlayerConfiguration();
      expect(config.libmpvOptions, isNull);
    });

    test('null libmpvOptions: backend applies the documented defaults', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
      );

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      // Allow the unawaited apply future to settle. cache-dir resolution may
      // throw under the test binding (no platform channel); the applier still
      // fires with whatever effective set is non-empty.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(appliedMaps, isNotEmpty, reason: 'applier should fire once');
      final applied = appliedMaps.single;
      expect(applied['demuxer-lavf-o'], 'fflags=+fastseek');
      expect(
        applied['stream-lavf-o'],
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,seekable=1,multiple_requests=1',
      );
      expect(applied['demuxer-readahead-secs'], '20');
      expect(applied['force-seekable'], 'yes');
      // Fix 4: audio output longevity defaults.
      expect(applied['audio-keep-open'], 'yes');
      expect(applied['gapless-audio'], 'yes');
      expect(
        applied.length,
        6,
        reason: 'default libmpv option set should contain exactly 6 keys',
      );

      await p.dispose();
    });

    test('consumer override replaces the matching default; other defaults remain', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(
          internalPositionThrottle: Duration.zero,
          libmpvOptions: {'demuxer-lavf-o': 'fflags=+nofastseek'},
        ),
      );

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(appliedMaps, isNotEmpty);
      final applied = appliedMaps.single;
      expect(applied['demuxer-lavf-o'], 'fflags=+nofastseek');
      // Other defaults are untouched.
      expect(applied['force-seekable'], 'yes');
      expect(applied['demuxer-readahead-secs'], '20');

      await p.dispose();
    });

    test('empty-string override SKIPS the corresponding default key', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(
          internalPositionThrottle: Duration.zero,
          libmpvOptions: {'demuxer-lavf-o': ''},
        ),
      );

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(appliedMaps, isNotEmpty);
      final applied = appliedMaps.single;
      expect(applied.containsKey('demuxer-lavf-o'), isFalse);
      // Sibling defaults are still applied.
      expect(applied['force-seekable'], 'yes');

      await p.dispose();
    });
  });
}
