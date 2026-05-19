import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Faz H — Hardening: lifecycle / dispose tests for CorePlayerMediaKit.
///
/// Targets the leak_tracker failure classes documented in prior production
/// outages:
///
///   1. Constructor fire-and-forget Futures landing on a disposed player
///      (setProperty / attach after dispose).
///   2. _disposed = true happening after awaits in dispose, so guards
///      relying on the flag fail to short-circuit during the teardown.
///   3. Missing disposeSync mirror on CorePlayerMediaKit (bridge has one).

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
  _StreamHarness h, {
  Future<void> Function()? openDelay,
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

  when(() => mockState.duration).thenReturn(Duration.zero);
  when(() => mockState.position).thenReturn(Duration.zero);
  when(() => mockState.buffer).thenReturn(Duration.zero);
  when(() => mockState.playing).thenReturn(false);
  when(() => mockState.rate).thenReturn(1.0);
  when(() => mockState.volume).thenReturn(100.0);

  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((
    inv,
  ) async {
    if (openDelay != null) await openDelay();
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
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
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

  group('Faz H — rapid construct-then-dispose', () {
    test(
      'dispose called before constructor unawaiteds settle: applier never '
      'runs against a disposed player',
      () async {
        final mockPlayer = MockPlayer();
        final mockStream = MockPlayerStream();
        final mockState = MockPlayerState();
        final h = _StreamHarness();
        _wireMockStreams(mockPlayer, mockStream, mockState, h);

        // Block the applier on a controllable completer so we can drive the
        // ordering precisely: ctor fires _applyLibmpvOptions, dispose flips
        // _disposed before the completer resolves.
        var applierObservedDisposed = false;
        var applierCallCount = 0;
        final gate = Completer<void>();
        debugSetLibmpvOptionsApplierForTest((player, options) async {
          applierCallCount++;
          await gate.future;
          // After the gate releases, _disposed should be true. The wrapper's
          // _applyLibmpvOptions re-checks _disposed BEFORE calling the
          // applier; reaching this line at all means the wrapper's guard
          // failed to skip. The captured-flag assertion below catches that.
          applierObservedDisposed = true;
        });

        final p = CorePlayerMediaKit(testPlayer: mockPlayer);

        // Immediately request dispose, without awaiting it. The gate is still
        // closed, so the applier hasn't entered yet — but dispose will flip
        // _disposed synchronously and then await the _pendingOps drain.
        final disposeFuture = p.dispose();

        expect(p.isDisposed, isTrue, reason: '_disposed must be set synchronously');

        // Release the applier gate. The wrapper's pre-applier _disposed
        // re-check should now short-circuit so the applier body never runs.
        gate.complete();

        await disposeFuture;

        // The applier IS invoked once from the unawaited entry point — but
        // its body runs AFTER the wrapper re-checks _disposed. The wrapper's
        // re-check at the top of _applyLibmpvOptions skips the applier call
        // entirely when the apply runs after dispose. Verify the net effect:
        // applier body did not observe a post-dispose execution.
        expect(
          applierObservedDisposed,
          isFalse,
          reason:
              'Wrapper must short-circuit _applyLibmpvOptions on _disposed before '
              'invoking _libmpvOptionsApplier. applierCallCount=$applierCallCount',
        );

        await h.close();
      },
    );

    test('dispose drains _pendingOps before subscriptions cancel', () async {
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      final h = _StreamHarness();
      // Gate the autoLoad's open() so the unawaited load() future stays in
      // _pendingOps for the entirety of the dispose drain. The applier is
      // not a reliable drain witness because the wrapper's post-await
      // _disposed re-checks short-circuit the apply path on the way out.
      final openGate = Completer<void>();
      _wireMockStreams(
        mockPlayer,
        mockStream,
        mockState,
        h,
        openDelay: () => openGate.future,
      );
      debugSetLibmpvOptionsApplierForTest((player, options) async {});

      final src = CorePlayerAudioSource(
        title: 't',
        url: 'https://example.com/a.mp3',
      );
      final p = CorePlayerMediaKit(
        testPlayer: mockPlayer,
        audioSource: src,
        autoLoad: true,
      );
      // Pump once so the constructor's _trackPending(load(...)) call wires
      // the gated open() into _pendingOps.
      await Future<void>.delayed(Duration.zero);

      final disposeFuture = p.dispose();

      // dispose must not return until the pending autoLoad future settles.
      final raceWinner = await Future.any<String>([
        disposeFuture.then((_) => 'dispose'),
        Future<String>.delayed(const Duration(milliseconds: 150), () => 'timeout'),
      ]);
      expect(
        raceWinner,
        'timeout',
        reason: 'dispose must block on _pendingOps drain; open() is still gated',
      );

      openGate.complete();
      await disposeFuture.timeout(const Duration(seconds: 2));
      await h.close();
    });

    test('after dispose() returns, _pendingOps is empty', () async {
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      final h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);

      debugSetLibmpvOptionsApplierForTest((player, options) async {});

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      await p.dispose();

      // _pendingOps is private; behavioural proxy: a follow-up dispose() call
      // returns immediately (no second drain hang) and isDisposed is true.
      await p.dispose().timeout(const Duration(seconds: 1));
      expect(p.isDisposed, isTrue);
      await h.close();
    });
  });

  group('Faz H — disposed-flag ordering inside dispose()', () {
    test(
      '_disposed is true before the first await inside dispose() — '
      'loadAndPlay invoked between dispose-entry and dispose-completion '
      'rejects immediately with PlayerDisposedFailure',
      () async {
        final mockPlayer = MockPlayer();
        final mockStream = MockPlayerStream();
        final mockState = MockPlayerState();
        final h = _StreamHarness();
        _wireMockStreams(mockPlayer, mockStream, mockState, h);

        // Slow applier so dispose's drain holds the future open. While
        // dispose is mid-drain, isDisposed must already be true (the flag
        // flipped synchronously at dispose-entry), so any new public method
        // call must reject.
        final gate = Completer<void>();
        debugSetLibmpvOptionsApplierForTest((player, options) async {
          await gate.future;
        });

        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        await Future<void>.delayed(Duration.zero);

        final disposeFuture = p.dispose();
        // dispose has not yet returned (drain pending on gate).
        expect(p.isDisposed, isTrue);

        // loadAndPlay throws synchronously off _throwAndEmit; wrap the call
        // in a closure so expectLater observes the sync throw rather than
        // letting it escape the test.
        expect(
          () => p.loadAndPlay(
            CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
          ),
          throwsA(isA<PlayerDisposedFailure>()),
          reason: 'public mutators must throw once _disposed flips, even '
              'while the async dispose drain is still settling',
        );

        gate.complete();
        await disposeFuture.timeout(const Duration(seconds: 2));
        await h.close();
      },
    );
  });

  group('Faz H — disposeSync mirror', () {
    test('disposeSync flips isDisposed synchronously', () {
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      final h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);
      debugSetLibmpvOptionsApplierForTest((player, options) async {});

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      expect(p.isDisposed, isFalse);

      p.disposeSync();

      expect(p.isDisposed, isTrue);
      // Cleanup: still need the async dispose to fully release subjects /
      // subscriptions; disposeSync alone does not.
      addTearDown(() async {
        await p.dispose();
        await h.close();
      });
    });

    test('disposeSync is idempotent', () {
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      final h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);
      debugSetLibmpvOptionsApplierForTest((player, options) async {});

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      p.disposeSync();
      p.disposeSync();
      expect(p.isDisposed, isTrue);

      addTearDown(() async {
        await p.dispose();
        await h.close();
      });
    });

    test(
      'public mutators called after disposeSync throw PlayerDisposedFailure '
      '(matches the bridge\'s post-disposeSync contract)',
      () async {
        final mockPlayer = MockPlayer();
        final mockStream = MockPlayerStream();
        final mockState = MockPlayerState();
        final h = _StreamHarness();
        _wireMockStreams(mockPlayer, mockStream, mockState, h);
        debugSetLibmpvOptionsApplierForTest((player, options) async {});

        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        await Future<void>.delayed(Duration.zero);

        p.disposeSync();

        await expectLater(
          p.load(CorePlayerAudioSource(title: 't', url: 'x')),
          throwsA(isA<PlayerDisposedFailure>()),
        );
        await expectLater(
          p.pause(),
          throwsA(isA<PlayerDisposedFailure>()),
        );
        await expectLater(
          p.seek(Duration.zero),
          throwsA(isA<PlayerDisposedFailure>()),
        );
        await expectLater(
          p.setVolume(0.5),
          throwsA(isA<PlayerDisposedFailure>()),
        );

        // The full async teardown still runs after disposeSync.
        await p.dispose();
        await h.close();
      },
    );

    test('dispose() after disposeSync() still completes the async teardown',
        () async {
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      final h = _StreamHarness();
      _wireMockStreams(mockPlayer, mockStream, mockState, h);
      debugSetLibmpvOptionsApplierForTest((player, options) async {});

      final p = CorePlayerMediaKit(testPlayer: mockPlayer);
      await Future<void>.delayed(Duration.zero);

      p.disposeSync();
      // _asyncDisposeStarted must still permit one full dispose() pass.
      await p.dispose().timeout(const Duration(seconds: 2));

      // Native player.dispose() is called by the async teardown.
      verify(() => mockPlayer.dispose()).called(1);

      // Second dispose() is a no-op — verified by the call count of the
      // native player.dispose() staying at 1 even after a re-entrant call.
      await p.dispose().timeout(const Duration(seconds: 1));
      verifyNever(() => mockPlayer.dispose());
      await h.close();
    });
  });

  group('Faz H — constructor abort short-circuit', () {
    test(
      'slow _applyLibmpvOptions: dispose called immediately after construct, '
      'applier body never observes a post-dispose run',
      () async {
        final mockPlayer = MockPlayer();
        final mockStream = MockPlayerStream();
        final mockState = MockPlayerState();
        final h = _StreamHarness();
        _wireMockStreams(mockPlayer, mockStream, mockState, h);

        var ranAfterDispose = false;
        final gate = Completer<void>();
        debugSetLibmpvOptionsApplierForTest((player, options) async {
          // If the wrapper's pre-applier _disposed re-check fired correctly
          // this body never executes because _applyLibmpvOptions returns
          // before calling the applier when _disposed is already true.
          // Hold open until the test releases us so we can synchronise the
          // construct/dispose race.
          await gate.future;
          ranAfterDispose = true;
        });

        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        // Synchronously dispose: _disposed flips, the applier hasn't
        // started yet because the unawaited microtask hasn't been pumped.
        final disposeFuture = p.dispose();

        // Release the gate AFTER dispose has had a chance to await its drain
        // — even though the gate never gets entered, this proves the
        // wrapper's pre-applier check skipped the call.
        gate.complete();
        await disposeFuture.timeout(const Duration(seconds: 2));

        expect(
          ranAfterDispose,
          isFalse,
          reason: '_applyLibmpvOptions must short-circuit on _disposed before '
              'invoking the applier',
        );
        await h.close();
      },
    );

    test(
      'autoLoad construct + immediate dispose: open() may have started but '
      'dispose still drains and completes without throwing',
      () async {
        final mockPlayer = MockPlayer();
        final mockStream = MockPlayerStream();
        final mockState = MockPlayerState();
        final h = _StreamHarness();
        final openGate = Completer<void>();
        _wireMockStreams(
          mockPlayer,
          mockStream,
          mockState,
          h,
          openDelay: () => openGate.future,
        );
        debugSetLibmpvOptionsApplierForTest((player, options) async {});

        final src = CorePlayerAudioSource(
          title: 't',
          url: 'https://example.com/a.mp3',
        );
        final p = CorePlayerMediaKit(
          testPlayer: mockPlayer,
          audioSource: src,
          autoLoad: true,
        );

        // Begin dispose while the autoLoad's open() is still gated. The
        // autoLoad branch goes through _trackPending so dispose must drain
        // it before returning.
        final disposeFuture = p.dispose();

        // dispose should not return yet — the open() future is still gated.
        final winner = await Future.any<String>([
          disposeFuture.then((_) => 'dispose'),
          Future<String>.delayed(const Duration(milliseconds: 100), () => 'timeout'),
        ]);
        expect(winner, 'timeout');

        openGate.complete();
        await disposeFuture.timeout(const Duration(seconds: 2));
        expect(p.isDisposed, isTrue);
        await h.close();
      },
    );
  });
}
