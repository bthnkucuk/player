import 'dart:async';

import 'package:audio_player/audio_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';

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

  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((
    inv,
  ) async {
    final playable = inv.positionalArguments[0];
    if (playable is Playlist) {
      h.playlist.add(playable);
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
  when(() => mockPlayer.next()).thenAnswer((_) async {});
  when(() => mockPlayer.previous()).thenAnswer((_) async {});
  when(() => mockPlayer.jump(any())).thenAnswer((_) async {});
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

void main() {
  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
    // Tests need synchronous position/playing propagation. Heartbeat is
    // null by default; specific tests reinstall a heartbeat configuration.
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
  });

  group('CorePlayerMediaKit playbackEventStream', () {
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
      player = CorePlayerMediaKit(testPlayer: mockPlayer);
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
      await h.close();
    });

    final srcA = HttpAudioSource(
      title: 'A',
      url: Uri.parse('https://example.com/a.mp3'),
    );
    final srcB = HttpAudioSource(
      title: 'B',
      url: Uri.parse('https://example.com/b.mp3'),
    );

    test('playing false→true emits PlaybackStartedEvent exactly once', () async {
      final events = <CorePlaybackEvent>[];
      final sub = player.playbackEventStream.listen(events.add);

      await player.setQueue(CorePlayerQueue([srcA]));
      await Future<void>.delayed(Duration.zero);

      // Two playing emissions but only one false→true edge.
      h.playing.add(true);
      h.playing.add(true);
      await Future<void>.delayed(Duration.zero);

      final started = events.whereType<PlaybackStartedEvent>().toList();
      expect(started, hasLength(1));
      expect(started.single.source, srcA);

      await sub.cancel();
    });

    test(
      'completed=true emits PlaybackEndedByCompletionEvent for the active source',
      () async {
        final events = <CorePlaybackEvent>[];
        final sub = player.playbackEventStream.listen(events.add);

        await player.setQueue(CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);
        h.playing.add(true);
        await Future<void>.delayed(Duration.zero);
        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);

        final completed = events.whereType<PlaybackEndedByCompletionEvent>().toList();
        expect(completed, hasLength(1));
        expect(completed.single.source, srcA);

        await sub.cancel();
      },
    );

    test(
      'skipToNext emits PlaybackEndedBySkipEvent with the pre-skip position',
      () async {
        final events = <CorePlaybackEvent>[];
        final sub = player.playbackEventStream.listen(events.add);

        await player.setQueue(CorePlayerQueue([srcA, srcB]));
        await Future<void>.delayed(Duration.zero);
        // Drive the position forward via the position subject so player.position
        // reflects the pre-skip playhead.
        h.position.add(const Duration(seconds: 17));
        await Future<void>.delayed(Duration.zero);

        await player.skipToNext();
        await Future<void>.delayed(Duration.zero);

        final skipped = events.whereType<PlaybackEndedBySkipEvent>().toList();
        expect(skipped, hasLength(1));
        expect(skipped.single.source, srcA);
        expect(skipped.single.skippedFromPosition, const Duration(seconds: 17));

        await sub.cancel();
      },
    );

    test('stop() emits PlaybackEndedByStopEvent', () async {
      final events = <CorePlaybackEvent>[];
      final sub = player.playbackEventStream.listen(events.add);

      await player.setQueue(CorePlayerQueue([srcA]));
      await Future<void>.delayed(Duration.zero);
      await player.stop();
      await Future<void>.delayed(Duration.zero);

      final stopped = events.whereType<PlaybackEndedByStopEvent>().toList();
      expect(stopped, hasLength(1));
      expect(stopped.single.source, srcA);

      await sub.cancel();
    });

    test('seek emits PlaybackSeekEvent with from + to positions', () async {
      final events = <CorePlaybackEvent>[];
      final sub = player.playbackEventStream.listen(events.add);

      await player.setQueue(CorePlayerQueue([srcA]));
      await Future<void>.delayed(Duration.zero);
      // Configure the mock state so the seek's pre-seek read returns a
      // known value and the duration check doesn't short-circuit.
      when(() => mockState.duration).thenReturn(const Duration(minutes: 5));
      when(() => mockState.position).thenReturn(const Duration(seconds: 12));

      await player.seek(const Duration(seconds: 90));
      await Future<void>.delayed(Duration.zero);

      final seeks = events.whereType<PlaybackSeekEvent>().toList();
      expect(seeks, hasLength(1));
      expect(seeks.single.fromPosition, const Duration(seconds: 12));
      expect(seeks.single.toPosition, const Duration(seconds: 90));

      await sub.cancel();
    });

    test(
      'mid-playback buffering true→false emits StallStarted + StallEnded with duration',
      () async {
        // Stall duration ≈ wall-clock gap: use a short real-time window and
        // a tolerance so the assertion doesn't depend on scheduling jitter.
        final events = <CorePlaybackEvent>[];
        final sub = player.playbackEventStream.listen(events.add);

        await player.setQueue(CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);
        h.playing.add(true);
        await Future<void>.delayed(Duration.zero);

        h.buffering.add(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        h.buffering.add(false);
        await Future<void>.delayed(Duration.zero);

        final started = events.whereType<PlaybackStallStartedEvent>().toList();
        final ended = events.whereType<PlaybackStallEndedEvent>().toList();
        expect(started, hasLength(1));
        expect(ended, hasLength(1));
        // Wall-clock window we slept for was 50ms; jitter ⇒ 30–250ms band.
        expect(
          ended.single.stallDuration.inMilliseconds,
          inInclusiveRange(30, 250),
        );

        await sub.cancel();
      },
    );

    test(
      'heartbeat null (default) emits no PlaybackHeartbeatEvent ever',
      () async {
        final events = <CorePlaybackEvent>[];
        final sub = player.playbackEventStream.listen(events.add);

        await player.setQueue(CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);
        h.playing.add(true);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final beats = events.whereType<PlaybackHeartbeatEvent>().toList();
        expect(beats, isEmpty);

        await sub.cancel();
      },
    );

    test(
      'dispose closes the controller; new subscribers get done immediately',
      () async {
        // Listen first so we can observe the controller close.
        final doneFuture = player.playbackEventStream.drain<void>();

        await player.setQueue(CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);

        await player.dispose();

        // The pre-dispose subscriber sees `done`.
        await doneFuture.timeout(const Duration(seconds: 1));

        // A new subscriber after dispose also receives `done` immediately
        // (broadcast controller is closed).
        await player.playbackEventStream.drain<void>().timeout(
          const Duration(seconds: 1),
        );
      },
    );
  });

  group(
    'CorePlayerMediaKit playbackEventStream with heartbeat configured',
    () {
      late MockPlayer mockPlayer;
      late MockPlayerStream mockStream;
      late MockPlayerState mockState;
      late _StreamHarness h;
      late CorePlayerMediaKit player;

      setUp(() {
        // Reinstall configuration with a 100ms heartbeat for these tests.
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            heartbeatInterval: Duration(milliseconds: 100),
          ),
        );
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
        // Restore default for sibling test groups.
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
        );
      });

      final srcA = HttpAudioSource(
        title: 'A',
        url: Uri.parse('https://example.com/a.mp3'),
      );

      test(
        'heartbeat fires periodic events while playing and stops on pause',
        () async {
          // Real-time test with a tight 100ms interval. Heartbeats compute
          // their elapsedSinceStart against `DateTime.now()` (wall-clock)
          // so a fakeAsync zone can't drive that anyway — the timer fires
          // but the elapsed-since-start would read real time. Stick with
          // real-time scheduling and assert a band rather than an exact
          // count to absorb test-host jitter.
          final events = <CorePlaybackEvent>[];
          final sub = player.playbackEventStream.listen(events.add);

          await player.setQueue(CorePlayerQueue([srcA]));
          await Future<void>.delayed(Duration.zero);

          h.playing.add(true);
          // Sleep ~350ms with a 100ms interval ⇒ 2–4 heartbeats accounting
          // for the scheduling window. Sufficient to prove "more than 1"
          // without flaking on slow CI hosts.
          await Future<void>.delayed(const Duration(milliseconds: 350));

          final beatsWhilePlaying =
              events.whereType<PlaybackHeartbeatEvent>().toList();
          expect(beatsWhilePlaying.length, inInclusiveRange(2, 4));
          // Elapsed must grow monotonically — the royalty contract.
          for (int i = 1; i < beatsWhilePlaying.length; i++) {
            expect(
              beatsWhilePlaying[i].elapsedSinceStart,
              greaterThan(beatsWhilePlaying[i - 1].elapsedSinceStart),
            );
          }

          // Pause: no new heartbeats observable after a full interval window.
          h.playing.add(false);
          final beatsBeforePauseSettled = beatsWhilePlaying.length;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final beatsAfterPause =
              events.whereType<PlaybackHeartbeatEvent>().toList();
          expect(beatsAfterPause.length, beatsBeforePauseSettled);

          await sub.cancel();
        },
      );
    },
  );
}
