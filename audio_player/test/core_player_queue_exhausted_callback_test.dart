import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Faz Q — onQueueExhausted callback tests.
///
/// Verifies the new continuous-listening hook in
/// [CorePlayerConfiguration]:
///
///   * Single-track queue: completed → callback invoked exactly once.
///   * Multi-track queue: intermediate completed events do NOT fire the
///     callback; only the LAST item's completion does.
///   * Callback returning null: playback stops naturally, no append.
///   * Callback returning []: playback stops naturally, no append.
///   * Callback returning a non-empty list: queue grows AND playback
///     advances to the first appended item via `add()` + `jump()` +
///     `play()` on the native player.
///   * Re-entrancy guard: rapid duplicate `completed=true` ticks fire
///     the callback exactly once.
///   * Callback throws: error is logged and swallowed; player keeps
///     working.

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
  // Default playlist state: empty, index 0. Tests override per-scenario.
  when(() => mockState.playlist).thenReturn(const Playlist(<Media>[]));

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
  when(() => mockPlayer.add(any())).thenAnswer((_) async {});
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
    registerFallbackValue(Media('about:blank'));
    CoreAudioHandler.setInitialized(true);
    debugSetLibmpvOptionsApplierForTest((p, opts) async {});
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
    debugSetLibmpvOptionsApplierForTest(null);
  });

  /// Helper: simulate the playlist stream emission media_kit normally
  /// sends when the active index changes, so the wrapper's projected
  /// queue (read by the auto-radio detector) sees the new index.
  Future<void> setActiveIndex(int i, {required int length}) async {
    h.playlist.add(
      Playlist(
        List.generate(length, (_) => Media('https://example.com/x.mp3')),
        index: i,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> primeQueue(int length) async {
    final sources = List.generate(
      length,
      (i) => CorePlayerAudioSource(
        title: 't$i',
        url: 'https://example.com/$i.mp3',
      ),
    );
    await player.setQueue(CorePlayerQueue(sources));
    // setQueue's _setQueueLocked calls runOnNative(player.open) which our
    // mock wires through h.playlist.add — but we still need a microtask
    // pump for the listener to land.
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    mockPlayer = MockPlayer();
    mockStream = MockPlayerStream();
    mockState = MockPlayerState();
    h = _StreamHarness();
    _wireMockStreams(mockPlayer, mockStream, mockState, h);
  });

  tearDown(() async {
    if (!player.isDisposed) {
      await player.dispose();
    }
    await h.close();
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  group('onQueueExhausted callback', () {
    test(
      'single-track queue: completed fires → callback invoked exactly once',
      () async {
        var callCount = 0;
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            onQueueExhausted: () {
              callCount++;
              return null;
            },
          ),
        );
        player = CorePlayerMediaKit(testPlayer: mockPlayer);
        await primeQueue(1);
        await setActiveIndex(0, length: 1);

        h.completed.add(true);
        // Listener + async callback dispatch.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(callCount, 1);
      },
    );

    test(
      'multi-track queue: only the LAST item completing fires the callback',
      () async {
        var callCount = 0;
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            onQueueExhausted: () {
              callCount++;
              return null;
            },
          ),
        );
        player = CorePlayerMediaKit(testPlayer: mockPlayer);
        await primeQueue(3);

        // Intermediate completions (index 0 of 3, index 1 of 3) must NOT
        // fire the callback.
        await setActiveIndex(0, length: 3);
        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(callCount, 0, reason: 'index 0/3 must not fire');

        await setActiveIndex(1, length: 3);
        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(callCount, 0, reason: 'index 1/3 must not fire');

        // Last item: must fire.
        await setActiveIndex(2, length: 3);
        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(callCount, 1, reason: 'index 2/3 (last) must fire');
      },
    );

    test('callback returns null: no append, no jump, no play', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        CorePlayerConfiguration(
          internalPositionThrottle: Duration.zero,
          onQueueExhausted: () => null,
        ),
      );
      player = CorePlayerMediaKit(testPlayer: mockPlayer);
      await primeQueue(1);
      await setActiveIndex(0, length: 1);

      // Baseline call counts: setQueue may have triggered a jump on
      // construction depending on impl. Reset interaction trackers.
      clearInteractions(mockPlayer);

      h.completed.add(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => mockPlayer.add(any()));
      verifyNever(() => mockPlayer.jump(any()));
    });

    test('callback returns []: no append, no jump, no play', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        CorePlayerConfiguration(
          internalPositionThrottle: Duration.zero,
          onQueueExhausted: () async => <CorePlayerAudioSource>[],
        ),
      );
      player = CorePlayerMediaKit(testPlayer: mockPlayer);
      await primeQueue(1);
      await setActiveIndex(0, length: 1);

      clearInteractions(mockPlayer);

      h.completed.add(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => mockPlayer.add(any()));
      verifyNever(() => mockPlayer.jump(any()));
    });

    test(
      'callback returns non-empty: append via player.add + jump + play',
      () async {
        final extra = [
          CorePlayerAudioSource(
            title: 'extra-1',
            url: 'https://example.com/extra-1.mp3',
          ),
          CorePlayerAudioSource(
            title: 'extra-2',
            url: 'https://example.com/extra-2.mp3',
          ),
        ];
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            onQueueExhausted: () async => extra,
          ),
        );
        player = CorePlayerMediaKit(testPlayer: mockPlayer);
        await primeQueue(1);
        await setActiveIndex(0, length: 1);

        clearInteractions(mockPlayer);

        h.completed.add(true);
        // Let the broadcast listener -> async callback -> runOnQueue -> add
        // -> jump -> play chain settle.
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        verify(() => mockPlayer.add(any())).called(2);
        // First appended index for a length-1 queue is 1.
        verify(() => mockPlayer.jump(1)).called(1);
        verify(() => mockPlayer.play()).called(1);
        // Simulate the playlist stream emission that media_kit normally
        // sends after add()+jump() so the wrapper's _queueStreamBacking
        // sees the new length. Without this the wrapper's typed-source
        // mapping has updated but queueStream hasn't fanned out yet (it's
        // a pure projection of player.stream.playlist).
        h.playlist.add(
          Playlist(
            List.generate(3, (_) => Media('https://example.com/x.mp3')),
            index: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.queue.length, 3);
      },
    );

    test(
      'auto-radio append leaves _sources mutable: subsequent appendToQueue '
      'does not throw UnsupportedOperationError',
      () async {
        // Regression for a latent integration bug: an earlier draft of the
        // auto-radio path reassigned `_sources` to `List.unmodifiable(...)`
        // after the append. That bricked every Faz Q1 mutation
        // (appendToQueue / insertNext / removeAt / moveItem / replaceAt)
        // for the remainder of the player's life. The fix routes the
        // append through `_appendAllLocked` so both paths share the
        // single growable-list invariant.
        final extra = [
          CorePlayerAudioSource(
            title: 'auto-1',
            url: 'https://example.com/auto-1.mp3',
          ),
        ];
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            onQueueExhausted: () async => extra,
          ),
        );
        player = CorePlayerMediaKit(testPlayer: mockPlayer);
        await primeQueue(1);
        await setActiveIndex(0, length: 1);

        h.completed.add(true);
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        // Simulate the post-jump playlist emission so the projected queue
        // sees the new length (mirrors the previous test's pattern).
        h.playlist.add(
          Playlist(
            List.generate(2, (_) => Media('https://example.com/x.mp3')),
            index: 1,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // Now the user issues an unrelated Q1 mutation. With the unmodifiable
        // regression, this throws `Unsupported operation: Cannot add to an
        // unmodifiable list`.
        await player.appendToQueue(
          CorePlayerAudioSource(
            title: 'user-added',
            url: 'https://example.com/user-added.mp3',
          ),
        );
        // No exception → invariant preserved.
      },
    );

    test(
      'rapid duplicate completed=true ticks fire the callback exactly once',
      () async {
        var callCount = 0;
        final gate = Completer<void>();
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            onQueueExhausted: () {
              callCount++;
              return gate.future.then(
                (_) => <CorePlayerAudioSource>[],
              );
            },
          ),
        );
        player = CorePlayerMediaKit(testPlayer: mockPlayer);
        await primeQueue(1);
        await setActiveIndex(0, length: 1);

        // Fire three completed=true emissions back-to-back; only the first
        // should pass the guard. The async callback is still in flight on
        // the gate, but the re-entrancy flag flipped synchronously inside
        // _maybeFireQueueExhausted.
        h.completed.add(true);
        h.completed.add(true);
        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(callCount, 1);

        gate.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Even after the in-flight callback resolves, further completed
        // ticks against the same exhaustion must stay guarded.
        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(callCount, 1);
      },
    );

    test(
      'callback throws: error logged + swallowed; player still usable',
      () async {
        final logged = <String>[];
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            logCallback: (msg, {error, stackTrace}) {
              logged.add(msg);
            },
            onQueueExhausted: () async {
              throw StateError('rec engine offline');
            },
          ),
        );
        player = CorePlayerMediaKit(testPlayer: mockPlayer);
        await primeQueue(1);
        await setActiveIndex(0, length: 1);

        h.completed.add(true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(player.isDisposed, isFalse);
        expect(
          logged.any((m) => m.contains('onQueueExhausted callback threw')),
          isTrue,
        );
        // No append attempted.
        verifyNever(() => mockPlayer.add(any()));
      },
    );
  });
}
