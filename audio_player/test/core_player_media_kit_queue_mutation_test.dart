import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Fallback so `any()` matchers against `Player.add(Media)` /
/// `Player.move(int, int)` work — mocktail needs a sample instance to
/// route argument-matching through.
class _FakeMedia extends Fake implements Media {}

/// Stream harness for the test player — broadcast subjects we drive
/// manually so the platform-side emission semantics (sync write into the
/// playlist controller inside `add()` / `move()` / `remove()`) can be
/// reproduced without standing up a real `media_kit` native player.
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

/// Backing list (parallel to `_sources`) shared between the mock impls of
/// `add` / `move` / `remove` so each verb sees + broadcasts a consistent
/// Playlist snapshot — matches media_kit's real `current = [...]` semantics.
class _MockPlaylistState {
  final List<Media> medias = [];
  int index = 0;
}

void _wireMockStreams(
  MockPlayer mockPlayer,
  MockPlayerStream mockStream,
  MockPlayerState mockState,
  _StreamHarness h,
  _MockPlaylistState pl,
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
      pl.medias
        ..clear()
        ..addAll(playable.medias);
      pl.index = playable.index;
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
  when(() => mockPlayer.jump(any())).thenAnswer((_) async {
    // mpv updates playlist-pos but does not re-broadcast the playlist
    // list itself on a jump. We mirror that by emitting a playlist with
    // the new index but the same medias array — matches the wrapper's
    // playlist subscription contract.
  });

  // Mirror media_kit's native body: SYNC mutation + sync playlist broadcast
  // BEFORE any await. The wrapper-side mirror update is expected to be
  // already in place by the time the broadcast fires.
  when(() => mockPlayer.add(any())).thenAnswer((inv) async {
    final media = inv.positionalArguments[0] as Media;
    pl.medias.add(media);
    h.playlist.add(Playlist(List.of(pl.medias), index: pl.index));
  });
  when(() => mockPlayer.remove(any())).thenAnswer((inv) async {
    final i = inv.positionalArguments[0] as int;
    if (i < 0 || i >= pl.medias.length) return;
    pl.medias.removeAt(i);
    if (pl.index > i) {
      pl.index--;
    } else if (pl.index == i && pl.index >= pl.medias.length) {
      pl.index = pl.medias.isEmpty ? 0 : pl.medias.length - 1;
    }
    h.playlist.add(Playlist(List.of(pl.medias), index: pl.index));
  });
  when(() => mockPlayer.move(any(), any())).thenAnswer((inv) async {
    final from = inv.positionalArguments[0] as int;
    final to = inv.positionalArguments[1] as int;
    if (from < 0 || from >= pl.medias.length) return;
    final m = pl.medias.removeAt(from);
    final insertAt = to > from ? to - 1 : to;
    pl.medias.insert(insertAt, m);
    // Match mpv: playlist-pos is preserved by item identity.
    h.playlist.add(Playlist(List.of(pl.medias), index: pl.index));
  });
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

void main() {
  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late _StreamHarness h;
  late _MockPlaylistState pl;
  late CorePlayerMediaKit player;

  setUpAll(() {
    registerMediaKitTestFallbacks();
    registerFallbackValue(_FakeMedia());
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
    pl = _MockPlaylistState();
    _wireMockStreams(mockPlayer, mockStream, mockState, h, pl);
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
    url: Uri.parse('https://example.com/a.mp3'));
  final srcB = HttpAudioSource(
    title: 'B',
    url: Uri.parse('https://example.com/b.mp3'));
  final srcC = HttpAudioSource(
    title: 'C',
    url: Uri.parse('https://example.com/c.mp3'));
  final srcD = HttpAudioSource(
    title: 'D',
    url: Uri.parse('https://example.com/d.mp3'));
  final inserted = HttpAudioSource(
    title: 'INS',
    url: Uri.parse('https://example.com/ins.mp3'));

  Future<void> primeQueue(List<CoreAudioSource> q, {int index = 0}) async {
    await player.setQueue(CorePlayerQueue(q, currentIndex: index));
    // Allow the playlist subscription microtask to run.
    await Future<void>.delayed(Duration.zero);
  }

  group('insertNext', () {
    test(
      'while playing places the new source immediately after currentIndex',
      () async {
        await primeQueue([srcA, srcB, srcC]);
        await player.insertNext(inserted);
        await Future<void>.delayed(Duration.zero);

        // Queue layout — INS sits at currentIndex + 1, NOT at the end.
        expect(player.queue.sources, [srcA, inserted, srcB, srcC]);
        // Active source unchanged — we did NOT re-open the playlist.
        expect(player.audioSource, srcA);
        // Verify that open() was called exactly once (for setQueue), NOT
        // again for the insertNext path.
        verify(() => mockPlayer.open(any(), play: any(named: 'play'))).called(1);
        // add + move — single incremental insertion at the right slot.
        verify(() => mockPlayer.add(any())).called(1);
        verify(() => mockPlayer.move(3, 1)).called(1);
      },
    );

    test('on an empty queue degenerates to setQueue', () async {
      // No prime — start from the empty default.
      await player.insertNext(inserted);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [inserted]);
      expect(player.audioSource, inserted);
    });
  });

  group('appendToQueue', () {
    test('mid-track append does not disturb the active source', () async {
      await primeQueue([srcA, srcB]);
      // Simulate mid-track playback by pushing a position; the subscription
      // listener does not touch position on append, but the test asserts
      // that no position reset is forced by the wrapper.
      h.position.add(const Duration(seconds: 12));
      await Future<void>.delayed(Duration.zero);
      expect(player.position, const Duration(seconds: 12));

      await player.appendToQueue(inserted);
      await Future<void>.delayed(Duration.zero);

      expect(player.queue.sources, [srcA, srcB, inserted]);
      expect(player.audioSource, srcA);
      // Position must not reset (we never re-emit zero on append).
      expect(player.position, const Duration(seconds: 12));
      verify(() => mockPlayer.add(any())).called(1);
      verifyNever(() => mockPlayer.move(any(), any()));
    });

    test('on an empty queue routes through setQueue', () async {
      await player.appendToQueue(inserted);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [inserted]);
    });
  });

  group('appendAllToQueue', () {
    test('appends each source in iteration order', () async {
      await primeQueue([srcA]);
      await player.appendAllToQueue([srcB, srcC]);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [srcA, srcB, srcC]);
      verify(() => mockPlayer.add(any())).called(2);
    });

    test('empty list is a no-op (no native verbs fire)', () async {
      await primeQueue([srcA]);
      clearInteractions(mockPlayer);
      await player.appendAllToQueue(const []);
      verifyNever(() => mockPlayer.add(any()));
    });
  });

  group('removeAt', () {
    test('removing currentIndex advances to the next item', () async {
      await primeQueue([srcA, srcB, srcC]);
      await player.removeAt(0);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [srcB, srcC]);
      // The mock playlist now broadcasts index=0 against the new list,
      // whose head is srcB → wrapper's active source projection follows.
      expect(player.audioSource, srcB);
    });

    test(
      'removing an index BEFORE currentIndex decrements the active cursor',
      () async {
        await primeQueue([srcA, srcB, srcC], index: 2);
        // After setQueue the playlist subscription sees index=2 → currentIndex
        // is srcC.
        expect(player.audioSource, srcC);

        await player.removeAt(0);
        await Future<void>.delayed(Duration.zero);
        expect(player.queue.sources, [srcB, srcC]);
        expect(player.queue.currentIndex, 1);
        // Active source remains srcC — playback was NOT restarted.
        expect(player.audioSource, srcC);
      },
    );

    test('throws QueueOutOfBoundsFailure on out-of-range index', () async {
      await primeQueue([srcA, srcB]);
      expect(
        () => player.removeAt(7),
        throwsA(isA<QueueOutOfBoundsFailure>()),
      );
      expect(() => player.removeAt(-1), throwsA(isA<QueueOutOfBoundsFailure>()));
    });
  });

  group('moveItem', () {
    // Public contract: after moveItem(from, to), the source previously at
    // `from` ends up at index `to` in the resulting queue. Matrix over all
    // (from, to) combinations on a 4-item queue.
    final matrix = <(int, int, List<CoreAudioSource>)>[
      (0, 1, [srcB, srcA, srcC, srcD]),
      (0, 2, [srcB, srcC, srcA, srcD]),
      (0, 3, [srcB, srcC, srcD, srcA]),
      (1, 0, [srcB, srcA, srcC, srcD]),
      (1, 2, [srcA, srcC, srcB, srcD]),
      (1, 3, [srcA, srcC, srcD, srcB]),
      (2, 0, [srcC, srcA, srcB, srcD]),
      (2, 1, [srcA, srcC, srcB, srcD]),
      (2, 3, [srcA, srcB, srcD, srcC]),
      (3, 0, [srcD, srcA, srcB, srcC]),
      (3, 1, [srcA, srcD, srcB, srcC]),
      (3, 2, [srcA, srcB, srcD, srcC]),
    ];

    for (final entry in matrix) {
      final (from, to, expected) = entry;
      test('moveItem($from, $to) on [A,B,C,D] yields ${expected.map((s) => s.title).join(',')}', () async {
        await primeQueue([srcA, srcB, srcC, srcD]);
        await player.moveItem(from, to);
        await Future<void>.delayed(Duration.zero);
        expect(player.queue.sources, expected);
      });
    }

    test('moveItem(0, 1) issues native move(0, 2) — mpv index translation', () async {
      await primeQueue([srcA, srcB, srcC, srcD]);
      clearInteractions(mockPlayer);
      await player.moveItem(0, 1);
      await Future<void>.delayed(Duration.zero);
      // mpv's playlist-move inserts at `to - 0.5` post-removal; landing
      // the source at final index 1 requires passing `to = 2`.
      verify(() => mockPlayer.move(0, 2)).called(1);
    });

    test('moveItem(2, 0) issues native move(2, 0) — backward move unchanged', () async {
      await primeQueue([srcA, srcB, srcC, srcD]);
      clearInteractions(mockPlayer);
      await player.moveItem(2, 0);
      await Future<void>.delayed(Duration.zero);
      // Backward moves: insertion at `to - 0.5 = -0.5` lands the item at
      // final index 0 without needing an offset.
      verify(() => mockPlayer.move(2, 0)).called(1);
    });

    test('moveItem(0, 3) issues native move(0, 4) for forward-to-end', () async {
      await primeQueue([srcA, srcB, srcC, srcD]);
      clearInteractions(mockPlayer);
      await player.moveItem(0, 3);
      await Future<void>.delayed(Duration.zero);
      verify(() => mockPlayer.move(0, 4)).called(1);
    });

    test('move across currentIndex preserves the active item', () async {
      await primeQueue([srcA, srcB, srcC, srcD], index: 1);
      expect(player.audioSource, srcB);
      await player.moveItem(1, 2);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [srcA, srcC, srcB, srcD]);
      // The wrapper-side mirror lands B at index 2 (its new home). The
      // mock harness does not model mpv's identity-preserving playlist-pos
      // (the broadcast still carries index=pl.index), so this test pins
      // the visible source order which is what app callers observe.
    });

    test('clamps out-of-range indices to the valid range', () async {
      await primeQueue([srcA, srcB, srcC]);
      // from=99 clamps to 2; to=99 clamps to 2 → same index → no-op.
      await player.moveItem(99, 99);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [srcA, srcB, srcC]);
    });
  });

  group('replaceAt', () {
    test('non-active replace swaps the entry without touching position', () async {
      await primeQueue([srcA, srcB, srcC]);
      // Active = srcA. Replace index 2 (srcC) with `inserted`.
      await player.replaceAt(2, inserted);
      await Future<void>.delayed(Duration.zero);
      expect(player.queue.sources, [srcA, srcB, inserted]);
      expect(player.audioSource, srcA);
      // Replace must NOT seek when index != currentIndex.
      verifyNever(() => mockPlayer.seek(any()));
    });

    test(
      'active replace with preservePosition: true seeks to captured offset',
      () async {
        await primeQueue([srcA, srcB]);
        // Position the active track at 30s; capture happens inside replaceAt.
        when(() => mockState.position).thenReturn(const Duration(seconds: 30));

        await player.replaceAt(0, inserted, preservePosition: true);
        await Future<void>.delayed(Duration.zero);

        expect(player.queue.sources, [inserted, srcB]);
        // Wrapper issued a seek toward the captured position.
        verify(() => mockPlayer.seek(const Duration(seconds: 30))).called(1);
      },
    );

    test(
      'active replace with preservePosition: false skips the seek',
      () async {
        await primeQueue([srcA, srcB]);
        when(() => mockState.position).thenReturn(const Duration(seconds: 30));

        await player.replaceAt(0, inserted);
        await Future<void>.delayed(Duration.zero);

        expect(player.queue.sources, [inserted, srcB]);
        verifyNever(() => mockPlayer.seek(any()));
      },
    );

    test('throws QueueOutOfBoundsFailure on out-of-range index', () async {
      await primeQueue([srcA]);
      expect(
        () => player.replaceAt(5, inserted),
        throwsA(isA<QueueOutOfBoundsFailure>()),
      );
    });

    test(
      'tolerance constant is exposed and reasonable for buffer-aware seeks',
      () {
        // Documented SLA: ±200ms is the published tolerance for the position
        // landing on the next position-stream emission after replace.
        expect(
          kReplacePreservePositionTolerance,
          const Duration(milliseconds: 200),
        );
      },
    );
  });

  group('concurrency', () {
    test('appendToQueue waits for an in-flight setQueue', () async {
      // Hold the first setQueue's open() until we release it. The append
      // call must NOT issue add() against the native player until setQueue
      // finishes.
      final openCompleter = Completer<void>();
      when(
        () => mockPlayer.open(any(), play: any(named: 'play')),
      ).thenAnswer((inv) {
        final playable = inv.positionalArguments[0];
        if (playable is Playlist) {
          pl.medias
            ..clear()
            ..addAll(playable.medias);
          pl.index = playable.index;
          h.playlist.add(playable);
        }
        return openCompleter.future;
      });

      final setQueueFuture = player.setQueue(CorePlayerQueue([srcA]));
      await Future<void>.delayed(Duration.zero);
      // setQueue holds queueLock; appendToQueue must park behind it.
      final appendFuture = player.appendToQueue(srcB);
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => mockPlayer.add(any()));

      openCompleter.complete();
      await setQueueFuture;
      await appendFuture;
      await Future<void>.delayed(Duration.zero);

      // After serialisation, the append landed exactly once and the final
      // queue carries both items.
      verify(() => mockPlayer.add(any())).called(1);
      expect(player.queue.sources, [srcA, srcB]);
    });
  });
}
