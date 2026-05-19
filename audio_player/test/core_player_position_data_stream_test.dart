import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Faz Q — positionDataStream tests.
///
/// Verifies the new combined (position, duration) stream:
///   * Seeded with zero/zero so a freshly mounted scrubber sees an
///     immediate value instead of a frame-one blank.
///   * Distinct: identical back-to-back records do NOT re-emit.
///   * Emits on position change.
///   * Emits on duration change.
///   * Closed after dispose; new subscribers receive only `done`.
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

  when(() => mockPlayer.open(any(), play: any(named: 'play')))
      .thenAnswer((_) async {});
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late _StreamHarness h;
  late CorePlayerMediaKit player;

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
    debugSetLibmpvOptionsApplierForTest((p, opts) async {});
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
    debugSetLibmpvOptionsApplierForTest(null);
  });

  setUp(() {
    mockPlayer = MockPlayer();
    mockStream = MockPlayerStream();
    mockState = MockPlayerState();
    h = _StreamHarness();
    _wireMockStreams(mockPlayer, mockStream, mockState, h);
    player = CorePlayerMediaKit(testPlayer: mockPlayer);
  });

  tearDown(() async {
    if (!player.isDisposed) {
      await player.dispose();
    }
    await h.close();
  });

  group('positionDataStream', () {
    test('seeded with zero/zero so a new subscriber gets an immediate value',
        () async {
      // Drive a microtask so the subject is fully constructed.
      await Future<void>.delayed(Duration.zero);

      final first = await player.positionDataStream.first
          .timeout(const Duration(seconds: 1));
      expect(first.position, Duration.zero);
      expect(first.duration, Duration.zero);
      expect(player.positionDataStream.value.position, Duration.zero);
      expect(player.positionDataStream.value.duration, Duration.zero);
    });

    test('emits on position update', () async {
      final received = <CorePlayerPositionData>[];
      final sub = player.positionDataStream.skip(1).listen(received.add);
      // Skip the seed value; we want to see only post-construction updates.

      h.position.add(const Duration(seconds: 5));
      // Flush combineLatest2 + distinct.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(received, isNotEmpty);
      expect(received.last.position, const Duration(seconds: 5));
      expect(received.last.duration, Duration.zero);
      await sub.cancel();
    });

    test('emits on duration update', () async {
      final received = <CorePlayerPositionData>[];
      final sub = player.positionDataStream.skip(1).listen(received.add);

      h.duration.add(const Duration(minutes: 3));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(received, isNotEmpty);
      expect(received.last.duration, const Duration(minutes: 3));
      expect(received.last.position, Duration.zero);
      await sub.cancel();
    });

    test('does NOT spam: identical back-to-back records are deduplicated',
        () async {
      final received = <CorePlayerPositionData>[];
      final sub = player.positionDataStream.skip(1).listen(received.add);

      h.position.add(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final lenAfterFirst = received.length;

      // Repeat the SAME position with no duration change. distinct() must
      // collapse this — both upstream subjects fire but the combined
      // record value is unchanged.
      h.position.add(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(received.length, lenAfterFirst,
          reason: 'distinct() must drop identical records');
      await sub.cancel();
    });

    test('after dispose, the stream is closed (new subscribers get done)',
        () async {
      await player.dispose();
      // listen after dispose: subject is closed; the listener never sees
      // data, just a `done` event. Verifies _positionDataSubject is closed
      // in dispose().
      final completer = Completer<void>();
      final sub = player.positionDataStream.listen(
        (_) {},
        onDone: completer.complete,
      );
      await completer.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
    });
  });
}
