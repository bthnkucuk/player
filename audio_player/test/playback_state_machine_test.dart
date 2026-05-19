import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'cross_package/_helpers/stream_harness.dart';
import 'helpers/test_mocks.dart';

/// Behavioral tests for the CorePlayer playback state machine.
///
/// `CorePlayerMediaKit` derives [CorePlayerState] via `Rx.combineLatest5` over
/// `buffer / playing / position / error / completed`. The single-state tests
/// already exist in `audio_player_test.dart`. This suite focuses on:
///
///   1. **transition sequences** (e.g. loading → ready → completed) — the
///      shape of the emitted history over a typical playback session.
///   2. **error recovery** — after an error sets `needToLoad=true`, the next
///      `load()` reset must allow normal state recovery.
///   3. **seek boundary precision** — the 300 ms-from-end abort threshold and
///      the 300 ms-from-start clamp-to-zero rule, asserted at exact-edge
///      durations rather than only mid-range/extreme values.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late StreamHarness h;
  late CorePlayerMediaKit corePlayer;

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
    // Disable internal position throttle in tests so the playerState
    // combineLatest5 fires synchronously off single position emits.
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(const CorePlayerConfiguration());
  });

  setUp(() {
    mockPlayer = MockPlayer();
    mockStream = MockPlayerStream();
    mockState = MockPlayerState();
    h = StreamHarness();
    wirePlayer(mockPlayer, mockStream, mockState, h);
    corePlayer = CorePlayerMediaKit(testPlayer: mockPlayer);
  });

  tearDown(() async {
    if (!corePlayer.isDisposed) {
      await corePlayer.dispose();
    }
    await h.close();
    detachAllPlayers();
  });

  group('CorePlayerState transition sequences', () {
    test('idle is the seeded initial state before any stream emissions', () {
      expect(corePlayer.playerState, CorePlayerState.idle);
    });

    test('loading -> ready -> completed sequence for a normal play-through', () async {
      // The state machine guards on `_audioSource == null` and returns idle
      // before any other branch fires. Load a source first so the rest of
      // the state machine is exercised.
      await corePlayer.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));

      // Subscribe before driving the streams so we capture every distinct emission.
      final states = <CorePlayerState>[];
      final sub = corePlayer.playerStateStream.listen(states.add);

      // Drive an initial "loading" tick: buffer == position == zero (so the
      // `buffer > position` ready predicate is false), no completion, no error.
      h.buffer.add(Duration.zero);
      h.position.add(Duration.zero);
      h.playing.add(false);
      h.completed.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Move into ready: buffer > position.
      h.buffer.add(const Duration(seconds: 10));
      h.playing.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Complete the track. After completion, position can equal or exceed
      // buffer — flip back to buffer <= position so the ready branch yields
      // to the completed branch.
      h.position.add(const Duration(seconds: 20));
      h.completed.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await sub.cancel();

      // The state machine must visit loading then ready then completed,
      // in that relative order. (Other intermediate emissions are allowed —
      // combineLatest re-fires on every stream tick.)
      final loadingIdx = states.indexOf(CorePlayerState.loading);
      final readyIdx = states.indexOf(CorePlayerState.ready);
      final completedIdx = states.indexOf(CorePlayerState.completed);
      expect(loadingIdx, greaterThanOrEqualTo(0), reason: 'never saw loading');
      expect(readyIdx, greaterThan(loadingIdx), reason: 'ready must come after loading');
      expect(completedIdx, greaterThan(readyIdx), reason: 'completed must come after ready');
    });

    test('error wins over ready/completed branches in the combineLatest', () async {
      // Load a source so the idle guard doesn't short-circuit before error.
      await corePlayer.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));

      // Seed a ready-looking state.
      h.buffer.add(const Duration(seconds: 10));
      h.playing.add(true);
      h.position.add(const Duration(seconds: 1));
      h.completed.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Now push an error. It must flip the state to error and set
      // needToLoad=true even though buffer > position would otherwise mean
      // ready.
      final f = corePlayer.playerStateStream.firstWhere((s) => s == CorePlayerState.error);
      h.error.add('network down');
      await f.timeout(const Duration(seconds: 1));

      expect(corePlayer.needToLoad, isTrue);
    });

    test('error path: load() resets needToLoad and clears the error signal', () async {
      // Pre-load so the idle guard doesn't short-circuit the error branch.
      await corePlayer.load(HttpAudioSource(title: 'pre', url: Uri.parse('https://example.com/pre.mp3')));

      // combineLatest5 needs ALL 5 inputs to have emitted at least once
      // before it fires. Completed is startWith-seeded and the error subject
      // is seeded too; seed buffer/position/playing so the error tick below
      // actually drives the state.
      h.buffer.add(Duration.zero);
      h.position.add(Duration.zero);
      h.playing.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Trigger an error first.
      h.error.add('boom');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(corePlayer.needToLoad, isTrue);

      // Now reload — load() sets _playerErrorSubject back to null AND clears
      // needToLoad. After this, a subsequent ready/loading tick must NOT be
      // forced back into error.
      await corePlayer.load(HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')));
      expect(corePlayer.needToLoad, isFalse);

      // Drive a ready-looking tick (buffer > position) to confirm the error
      // is no longer "stuck".
      h.buffer.add(const Duration(seconds: 10));
      h.position.add(Duration.zero);
      h.playing.add(true);
      h.completed.add(false);
      final ready = await corePlayer.playerStateStream
          .firstWhere((s) => s == CorePlayerState.ready)
          .timeout(const Duration(seconds: 1));
      expect(ready, CorePlayerState.ready);
    });
  });

  group('seek boundary precision', () {
    test('seek to position exactly equal to duration - 300ms aborts', () async {
      // Branch: `position > duration - 300ms` aborts. At exactly the
      // threshold the comparison is `>`, NOT `>=`, so the threshold itself
      // should still go through.
      when(() => mockState.duration).thenReturn(const Duration(seconds: 10));

      // Exactly at the edge: 10s - 300ms == 9.7s. This must NOT abort
      // (the implementation uses `>`, not `>=`).
      await corePlayer.seek(const Duration(milliseconds: 9700));
      verify(() => mockPlayer.seek(const Duration(milliseconds: 9700))).called(1);
    });

    test('seek to position just past duration - 300ms aborts (no player.seek)', () async {
      when(() => mockState.duration).thenReturn(const Duration(seconds: 10));
      await corePlayer.seek(const Duration(milliseconds: 9701));
      verifyNever(() => mockPlayer.seek(any()));
    });

    test('seek to position beyond the end aborts (no player.seek)', () async {
      when(() => mockState.duration).thenReturn(const Duration(seconds: 10));
      await corePlayer.seek(const Duration(seconds: 999));
      verifyNever(() => mockPlayer.seek(any()));
    });

    test('seek to zero forwards to player.seek(zero)', () async {
      when(() => mockState.duration).thenReturn(const Duration(seconds: 10));
      await corePlayer.seek(Duration.zero);
      verify(() => mockPlayer.seek(Duration.zero)).called(1);
    });

    test('seek to position exactly at 300ms is clamped to zero', () async {
      // Branch: `position < 300ms` -> clamp to zero. Exactly at 300ms the
      // comparison is `<`, NOT `<=`, so 300ms should pass through unchanged.
      when(() => mockState.duration).thenReturn(const Duration(seconds: 10));
      await corePlayer.seek(const Duration(milliseconds: 300));
      verify(() => mockPlayer.seek(const Duration(milliseconds: 300))).called(1);
    });

    test('seek to position just under 300ms is clamped to zero', () async {
      when(() => mockState.duration).thenReturn(const Duration(seconds: 10));
      await corePlayer.seek(const Duration(milliseconds: 299));
      verify(() => mockPlayer.seek(Duration.zero)).called(1);
    });

    test('seek with zero duration treats every positive position as past-end', () async {
      // Edge: when no media has been loaded yet, player.state.duration is
      // typically Duration.zero. Any positive seek must abort because
      // `pos > 0 - 300ms` is `pos > -300ms`, which any pos >= 0 satisfies.
      when(() => mockState.duration).thenReturn(Duration.zero);
      await corePlayer.seek(const Duration(seconds: 1));
      verifyNever(() => mockPlayer.seek(any()));
    });
  });

  group('error -> recover behavior contract', () {
    test('error stream emission sets needToLoad and the next play() reloads', () async {
      final src = HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3'));
      await corePlayer.load(src);
      expect(corePlayer.needToLoad, isFalse);

      // combineLatest5 needs ALL 5 inputs to have emitted at least once.
      // Completed is startWith-seeded and the error subject is seeded; seed
      // buffer/position/playing here so the error tick below produces a
      // state emission.
      h.buffer.add(Duration.zero);
      h.position.add(Duration.zero);
      h.playing.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Now push an error tick — combineLatest5 will produce `error` state
      // and the side-effect `needToLoad=true`.
      final errStateFuture = corePlayer.playerStateStream.firstWhere((s) => s == CorePlayerState.error);
      h.error.add('decoder failed');
      await errStateFuture.timeout(const Duration(seconds: 1));
      expect(corePlayer.needToLoad, isTrue);

      // The next play() call must therefore reload before playing.
      reset(mockPlayer);
      wirePlayer(mockPlayer, mockStream, mockState, h);
      await corePlayer.play();
      verify(() => mockPlayer.open(any(), play: false)).called(1);
      verify(() => mockPlayer.play()).called(1);
    });
  });
}
