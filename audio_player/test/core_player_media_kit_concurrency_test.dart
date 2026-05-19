import 'dart:async';

import 'package:fake_async/fake_async.dart';
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
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
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

  group('CorePlayerMediaKit concurrency (Faz H)', () {
    const srcA = CorePlayerAudioSource(
      title: 'A',
      url: 'https://example.com/a.mp3',
    );
    const srcB = CorePlayerAudioSource(
      title: 'B',
      url: 'https://example.com/b.mp3',
    );

    test(
      'stale setQueue completion does not overwrite the latest caller state',
      () async {
        // Two open() calls: the first hangs until we release it; the second
        // races behind queueLock. Once both finish, _audioSource and
        // _sources must reflect B, not the stale A completion.
        final openCompleters = <Completer<void>>[];
        final openedPlaylists = <Playlist>[];
        when(
          () => mockPlayer.open(any(), play: any(named: 'play')),
        ).thenAnswer((inv) {
          final playable = inv.positionalArguments[0];
          if (playable is Playlist) {
            openedPlaylists.add(playable);
          }
          final c = Completer<void>();
          openCompleters.add(c);
          return c.future;
        });

        final f1 = player.setQueue(const CorePlayerQueue([srcA]));
        // Allow the first setQueue to acquire queueLock and reach its
        // open() await.
        await Future<void>.delayed(Duration.zero);
        expect(openCompleters.length, 1);

        final f2 = player.setQueue(const CorePlayerQueue([srcB]));
        // f2 is parked on queueLock; only f1's open() is in flight.
        await Future<void>.delayed(Duration.zero);
        expect(openCompleters.length, 1);

        // Release the WINNER first: complete f1's open, which lets f1
        // proceed past its await. f1's token was bumped by f2's entry, so
        // f1's body must observe token mismatch and abandon its writes.
        openCompleters[0].complete();
        await f1;

        // Now f2 acquired the lock and its open() is in flight.
        await Future<void>.delayed(Duration.zero);
        expect(openCompleters.length, 2);
        // Emit the matching playlist for B so the subscription updates
        // queueStream/audioSource through the natural path.
        h.playlist.add(openedPlaylists.last);
        openCompleters[1].complete();
        await f2;
        await Future<void>.delayed(Duration.zero);

        expect(player.audioSource, srcB);
        expect(player.queue.length, 1);
        expect(player.queue.sources.single, srcB);
      },
    );

    test(
      'native lock serializes seek behind an in-flight open',
      () async {
        // setQueue's open() hangs; a concurrent seek must NOT fire on the
        // native player until open() returns.
        final openCompleter = Completer<void>();
        when(
          () => mockPlayer.open(any(), play: any(named: 'play')),
        ).thenAnswer((_) => openCompleter.future);

        final setQueueFuture = player.setQueue(const CorePlayerQueue([srcA]));
        // Allow setQueue to enter open() under both locks.
        await Future<void>.delayed(Duration.zero);

        // Fire a seek; the wrapper applies its end-threshold guard, so we
        // must report a non-zero duration on the mock state.
        when(() => mockState.duration).thenReturn(const Duration(minutes: 10));
        final seekFuture = player.seek(const Duration(seconds: 30));

        // While open() is in flight, neither seek() nor the underlying
        // libmpv command path should have been invoked.
        await Future<void>.delayed(Duration.zero);
        verifyNever(() => mockPlayer.seek(any()));

        openCompleter.complete();
        await setQueueFuture;
        await seekFuture;

        // After open() releases the native lock, the seek wins it and
        // forwards to the platform. (We hit the non-NativePlayer arm
        // because player.platform is unset on the mock.)
        verify(() => mockPlayer.seek(const Duration(seconds: 30))).called(1);
      },
    );

    test(
      'queueLock timeout surfaces as a TimeoutException when open() hangs',
      () {
        // Use a dedicated player + harness so the never-completing open()
        // future doesn't bleed into the global tearDown (which would hang
        // dispose() on the still-held nativeLock).
        final localPlayer = MockPlayer();
        final localStream = MockPlayerStream();
        final localState = MockPlayerState();
        final localH = _StreamHarness();
        _wireMockStreams(localPlayer, localStream, localState, localH);
        final openCompleter = Completer<void>();
        when(
          () => localPlayer.open(any(), play: any(named: 'play')),
        ).thenAnswer((_) => openCompleter.future);

        fakeAsync((async) {
          final p = CorePlayerMediaKit(testPlayer: localPlayer);

          unawaited(p.setQueue(const CorePlayerQueue([srcA])));
          async.flushMicrotasks();

          Object? caught;
          unawaited(
            p
                .setQueue(const CorePlayerQueue([srcB]))
                .catchError((Object e) {
              caught = e;
            }),
          );

          async.elapse(const Duration(seconds: 24));
          async.flushMicrotasks();
          expect(caught, isNull);

          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          expect(caught, isA<TimeoutException>());
        });

        // Release the stuck open() so the dedicated player's pending
        // operations resolve and don't leak into the next test.
        openCompleter.complete();
      },
    );

    test(
      're-entrant pause from event-stream listener does not deadlock',
      () async {
        // While setQueue is parked on a slow open(), simulate a native
        // verb mutation that would arrive from the audioHandler event
        // stream by calling pause() (a public method that goes through
        // nativeLock). It must queue behind the in-flight open() but
        // never deadlock — the lock contract forbids acquiring nativeLock
        // from inside a media_kit stream callback while it's held.
        final openCompleter = Completer<void>();
        when(
          () => mockPlayer.open(any(), play: any(named: 'play')),
        ).thenAnswer((_) => openCompleter.future);

        final setQueueFuture = player.setQueue(const CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);

        final pauseFuture = player.pause();
        // pause must not have fired yet: nativeLock is held by open().
        await Future<void>.delayed(Duration.zero);
        verifyNever(() => mockPlayer.pause());

        // Releasing open() should let pause progress to the native player
        // without re-entrancy issues.
        openCompleter.complete();
        await setQueueFuture.timeout(const Duration(seconds: 1));
        await pauseFuture.timeout(const Duration(seconds: 1));

        verify(() => mockPlayer.pause()).called(1);
      },
    );
  });
}
