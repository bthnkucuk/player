import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Stream harness — mirrors `core_player_media_kit_test.dart` so we can wire
/// mock players the same way the rest of the audio_player suite does. Kept
/// local so this file has no cross-test coupling.
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

void _wire(
  MockPlayer mockPlayer,
  MockPlayerStream mockStream,
  MockPlayerState mockState,
  _StreamHarness h, {
  Duration positionValue = Duration.zero,
  bool playingValue = false,
}) {
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

  when(() => mockState.duration).thenReturn(const Duration(minutes: 30));
  when(() => mockState.position).thenReturn(positionValue);
  when(() => mockState.buffer).thenReturn(Duration.zero);
  when(() => mockState.playing).thenReturn(playingValue);
  when(() => mockState.rate).thenReturn(1.0);
  when(() => mockState.volume).thenReturn(100.0);

  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((inv) async {
    final p = inv.positionalArguments[0];
    if (p is Playlist) {
      h.playlist.add(p);
    }
  });
  when(() => mockPlayer.play()).thenAnswer((_) async {});
  when(() => mockPlayer.pause()).thenAnswer((_) async {});
  when(() => mockPlayer.stop()).thenAnswer((_) async {});
  when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setRate(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setVolume(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setPlaylistMode(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setShuffle(any())).thenAnswer((_) async {});
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

void main() {
  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(const CorePlayerConfiguration());
  });

  setUp(CorePlayer.debugClearFactory);
  tearDown(CorePlayer.debugClearFactory);

  group('CorePlayer.snapshot()', () {
    test('captures queue + activeIndex + position + playing flag', () async {
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      final h = _StreamHarness();
      _wire(
        mockPlayer,
        mockStream,
        mockState,
        h,
        positionValue: const Duration(seconds: 42),
        playingValue: true,
      );

      final player = CorePlayerMediaKit(testPlayer: mockPlayer);
      const src1 = CorePlayerAudioSource(title: 'A', url: 'https://example.com/a.mp3');
      const src2 = CorePlayerAudioSource(title: 'B', url: 'https://example.com/b.mp3');
      await player.setQueue(const CorePlayerQueue([src1, src2], currentIndex: 1));

      // Drive a synthetic position emission so the position subject reflects
      // the playhead the user actually sees. We don't have an audio engine
      // here — the test seam injects via the stream the wrapper subscribes to.
      h.position.add(const Duration(seconds: 42));
      await Future<void>.delayed(Duration.zero);
      h.playing.add(true);
      await Future<void>.delayed(Duration.zero);

      final snap = player.snapshot();

      expect(snap['schemaVersion'], 1);
      expect(snap['positionMs'], 42 * 1000);
      expect(snap['playing'], isTrue);
      final queueJson = snap['queue'] as Map<String, Object?>;
      expect(queueJson['activeIndex'], 1);
      expect((queueJson['items'] as List).length, 2);

      await player.dispose();
      await h.close();
    });
  });

  group('CorePlayer.restore()', () {
    test('rejects unknown snapshot schemaVersion with typed failure', () async {
      // Even without a factory registered the schema check should fire first.
      expect(
        () => CorePlayer.restore(<String, Object?>{
          'schemaVersion': 999,
          'queue': <String, Object?>{},
          'positionMs': 0,
        }),
        throwsA(isA<SnapshotSchemaMismatchFailure>()
            .having((f) => f.foundVersion, 'foundVersion', 999)
            .having((f) => f.expectedVersion, 'expectedVersion', 1)),
      );
    });

    test('throws SnapshotMalformedFailure when queue is missing', () async {
      expect(
        () => CorePlayer.restore(<String, Object?>{
          'schemaVersion': 1,
          'positionMs': 0,
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('throws SnapshotMalformedFailure when positionMs is missing', () async {
      expect(
        () => CorePlayer.restore(<String, Object?>{
          'schemaVersion': 1,
          'queue': const CorePlayerQueue.empty().toJson(),
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('rejects snapshot whose nested queue has an unknown schema', () async {
      expect(
        () => CorePlayer.restore(<String, Object?>{
          'schemaVersion': 1,
          'queue': <String, Object?>{
            'schemaVersion': 42,
            'items': <Map<String, Object?>>[],
            'activeIndex': 0,
          },
          'positionMs': 0,
        }),
        throwsA(isA<SnapshotSchemaMismatchFailure>()),
      );
    });

    test('restores queue + index + seeks position; leaves player paused even when snapshot was playing', () async {
      // Original (source) player — drives the snapshot.
      final originalMock = MockPlayer();
      final h1 = _StreamHarness();
      _wire(
        originalMock,
        MockPlayerStream(),
        MockPlayerState(),
        h1,
        positionValue: const Duration(seconds: 15),
        playingValue: true,
      );
      // Re-wire the mock's state.position because _wire only sets it once;
      // snapshot() reads via `position` (BehaviorSubject), so we drive via the
      // stream below.
      final original = CorePlayerMediaKit(testPlayer: originalMock);
      const queue = CorePlayerQueue(
        [
          CorePlayerAudioSource(title: 'A', url: 'https://example.com/a.mp3'),
          CorePlayerAudioSource(title: 'B', url: 'https://example.com/b.mp3'),
          CorePlayerAudioSource(title: 'C', url: 'https://example.com/c.mp3'),
        ],
        currentIndex: 1,
      );
      await original.setQueue(queue);
      h1.position.add(const Duration(seconds: 15));
      h1.playing.add(true);
      await Future<void>.delayed(Duration.zero);

      final snap = original.snapshot();
      expect(snap['playing'], isTrue);
      expect(snap['positionMs'], 15000);
      await original.dispose();
      await h1.close();

      // Restored player — register a factory that hands the mock harness for
      // the new player. This mirrors what ensureInitialized() does in prod.
      final restoredMock = MockPlayer();
      final h2 = _StreamHarness();
      _wire(restoredMock, MockPlayerStream(), MockPlayerState(), h2);

      // Track the seek call so we can assert it's invoked (within ~200ms of
      // the snapshot — engine-side seek is best-effort).
      final seekCalls = <Duration>[];
      when(() => restoredMock.seek(any())).thenAnswer((inv) async {
        seekCalls.add(inv.positionalArguments[0] as Duration);
      });

      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
        return CorePlayerMediaKit(
          audioSource: audioSource,
          audioHandler: audioHandler,
          autoLoad: autoLoad,
          testPlayer: restoredMock,
        );
      });

      final restored = await CorePlayer.restore(snap);
      addTearDown(() async {
        await restored.dispose();
        await h2.close();
      });

      expect(restored, isA<CorePlayerMediaKit>());
      expect(restored.queue.length, 3);
      expect(restored.queue.currentIndex, 1);
      // Position-restore is best-effort: media_kit's seek is fire-and-acknowledge
      // and the underlying engine may snap to the nearest keyframe. We assert
      // a single seek call landed within ±200ms of the snapshot target.
      expect(seekCalls, hasLength(1));
      final delta = (seekCalls.single - const Duration(seconds: 15)).abs();
      expect(delta.inMilliseconds, lessThanOrEqualTo(200));
      // play() was never invoked: restore must leave the player paused.
      verifyNever(() => restoredMock.play());
      expect(restored.isPlaying, isFalse);
    });

    test('skips the seek when snapshot position is zero', () async {
      final mockPlayer = MockPlayer();
      final h = _StreamHarness();
      _wire(mockPlayer, MockPlayerStream(), MockPlayerState(), h);

      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
        return CorePlayerMediaKit(
          audioSource: audioSource,
          audioHandler: audioHandler,
          autoLoad: autoLoad,
          testPlayer: mockPlayer,
        );
      });

      const queue = CorePlayerQueue([
        CorePlayerAudioSource(title: 'A', url: 'https://example.com/a.mp3'),
      ]);
      final restored = await CorePlayer.restore(<String, Object?>{
        'schemaVersion': 1,
        'queue': queue.toJson(),
        'positionMs': 0,
        'playing': false,
      });
      addTearDown(() async {
        await restored.dispose();
        await h.close();
      });
      verifyNever(() => mockPlayer.seek(any()));
      verifyNever(() => mockPlayer.play());
    });

    test('handles empty-queue snapshot without seek or open', () async {
      final mockPlayer = MockPlayer();
      final h = _StreamHarness();
      _wire(mockPlayer, MockPlayerStream(), MockPlayerState(), h);

      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
        return CorePlayerMediaKit(
          audioSource: audioSource,
          audioHandler: audioHandler,
          autoLoad: autoLoad,
          testPlayer: mockPlayer,
        );
      });

      final restored = await CorePlayer.restore(<String, Object?>{
        'schemaVersion': 1,
        'queue': const CorePlayerQueue.empty().toJson(),
        'positionMs': 12345,
        'playing': false,
      });
      addTearDown(() async {
        await restored.dispose();
        await h.close();
      });
      expect(restored.queue.isEmpty, isTrue);
      verifyNever(() => mockPlayer.open(any(), play: any(named: 'play')));
      verifyNever(() => mockPlayer.seek(any()));
    });
  });
}
