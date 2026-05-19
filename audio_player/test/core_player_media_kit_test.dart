import 'dart:async';
import 'dart:io';

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

  // The mock models real media_kit behavior: open(Playlist) drives a
  // matching playlist emission on player.stream.playlist, and next/
  // previous/jump advance the in-memory cursor and re-emit. This is what
  // gives the wrapper its single-source-of-truth contract — every queue
  // observation goes through player.stream.playlist.
  Playlist? lastPlaylist;
  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((
    inv,
  ) async {
    final playable = inv.positionalArguments[0];
    if (playable is Playlist) {
      lastPlaylist = playable;
      h.playlist.add(playable);
    }
  });
  when(() => mockPlayer.play()).thenAnswer((_) async {});
  when(() => mockPlayer.pause()).thenAnswer((_) async {});
  when(() => mockPlayer.stop()).thenAnswer((_) async {
    lastPlaylist = null;
  });
  when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setRate(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setVolume(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setPlaylistMode(any())).thenAnswer((_) async {});
  when(() => mockPlayer.next()).thenAnswer((_) async {
    final pl = lastPlaylist;
    if (pl == null) return;
    final next = pl.index + 1 >= pl.medias.length ? 0 : pl.index + 1;
    lastPlaylist = Playlist(pl.medias, index: next);
    h.playlist.add(lastPlaylist!);
  });
  when(() => mockPlayer.previous()).thenAnswer((_) async {
    final pl = lastPlaylist;
    if (pl == null) return;
    final prev = pl.index - 1 < 0 ? pl.medias.length - 1 : pl.index - 1;
    lastPlaylist = Playlist(pl.medias, index: prev);
    h.playlist.add(lastPlaylist!);
  });
  when(() => mockPlayer.jump(any())).thenAnswer((inv) async {
    final pl = lastPlaylist;
    if (pl == null) return;
    final to = inv.positionalArguments[0] as int;
    lastPlaylist = Playlist(pl.medias, index: to);
    h.playlist.add(lastPlaylist!);
  });
  when(() => mockPlayer.setShuffle(any())).thenAnswer((_) async {});
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

/// Phase 16: minimal stub bridge that counts activate/deactivate calls so a
/// test can verify the deferred-activation contract end-to-end (attach in
/// CorePlayerMediaKit constructor → no activate; play() → activate).
class _MockBridgeForPhase16 implements CoreAudioServiceBridge {
  int activateCallCount = 0;
  int deactivateCallCount = 0;

  /// Ordered log of side-effecting bridge calls that touch the OS surface.
  /// Used by Phase 17 to assert `activateSession` lands before the first
  /// `emitMediaItem` inside play() — see the dedicated test group below.
  /// Entries: 'activate', 'mediaItem', 'mediaItem:null', 'playbackState',
  /// 'stop', 'deactivate'.
  final List<String> callOrder = <String>[];

  @override
  Future<void> initialize(CoreAudioHandler handler) async {}

  @override
  Future<void> activateSession() async {
    activateCallCount++;
    callOrder.add('activate');
  }

  @override
  Future<void> deactivateSession() async {
    deactivateCallCount++;
    callOrder.add('deactivate');
  }

  @override
  void emitPlaybackState(Object state) {
    callOrder.add('playbackState');
  }

  @override
  void emitMediaItem(Object? item) {
    callOrder.add(item == null ? 'mediaItem:null' : 'mediaItem');
  }

  @override
  void emitStopState() {
    callOrder.add('stop');
  }

  @override
  Object? get currentMediaItem => null;

  @override
  void refreshMediaItemForActiveScope() {}
}

void main() {
  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late _StreamHarness h;
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
    corePlayer = CorePlayerMediaKit(testPlayer: mockPlayer);
  });

  tearDown(() async {
    if (!corePlayer.isDisposed) {
      await corePlayer.dispose();
    }
    await h.close();
  });

  group('CorePlayerMediaKit', () {
    group('construction', () {
      test('does not call attachPlayer when audioHandler is null', () {
        expect(corePlayer.audioHandler, isNull);
        expect(CoreAudioHandler.isCurrentPlayer(corePlayer), isFalse);
      });

      test('seeds rate from player.state on construction', () {
        when(() => mockState.rate).thenReturn(1.5);
        final p = CorePlayerMediaKit(testPlayer: mockPlayer);
        expect(p.playbackSpeed, 1.5);
      });

      test('does not autoLoad when audioSource is null', () async {
        await Future<void>.delayed(Duration.zero);
        verifyNever(() => mockPlayer.open(any(), play: any(named: 'play')));
      });

      test(
        'autoLoad triggers load when audioSource provided and autoLoad=true',
        () async {
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final src = CorePlayerAudioSource(
            title: 'auto',
            url: 'https://example.com/a.mp3',
          );
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioSource: src,
            autoLoad: true,
          );
          await Future<void>.delayed(Duration.zero);
          verify(() => localPlayer.open(any(), play: false)).called(1);

          await p.dispose();
          await localH.close();
        },
      );

      test(
        'autoLoad load failure routes through _playerErrorSubject to CorePlayerState.error',
        () async {
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);
          // Override the default success behavior to throw on open().
          when(
            () => localPlayer.open(any(), play: any(named: 'play')),
          ).thenThrow(Exception('open failed'));

          final src = CorePlayerAudioSource(
            title: 'auto',
            url: 'https://example.com/bogus.mp3',
          );
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioSource: src,
            autoLoad: true,
          );

          final states = <CorePlayerState>[];
          final sub = p.playerStateStream.listen(states.add);

          // Allow the unawaited load() future to complete first so the error is
          // pushed onto _playerErrorSubject.
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // The internal playerState pipeline is Rx.combineLatest5 over five
          // streams; it cannot emit until each one has produced at least one
          // value. _playerErrorSubject is a seeded BehaviorSubject (now holding
          // the thrown error string) and player.stream.completed is wrapped in
          // startWith(false), but buffer/playing/position come straight from
          // the native player and need to be primed. Push one tick into each
          // so combineLatest5 can fire.
          localH.buffer.add(Duration.zero);
          localH.playing.add(false);
          localH.position.add(Duration.zero);

          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(states.contains(CorePlayerState.error), isTrue);

          await sub.cancel();
          await p.dispose();
          await localH.close();
        },
      );

      test('exposes initial getters', () {
        expect(corePlayer.position, Duration.zero);
        expect(corePlayer.duration, Duration.zero);
        expect(corePlayer.buffer, Duration.zero);
        expect(corePlayer.isPlaying, isFalse);
        expect(corePlayer.playerState, CorePlayerState.idle);
        expect(corePlayer.audioSource, isNull);
        expect(corePlayer.autoLoad, isFalse);
        expect(corePlayer.isDisposed, isFalse);
        expect(corePlayer.playbackSpeed, 1.0);
      });
    });

    group('stream wiring', () {
      test('player.stream.duration -> durationStream', () async {
        final f = corePlayer.durationStream.skip(1).first;
        h.duration.add(const Duration(seconds: 5));
        expect(await f, const Duration(seconds: 5));
        expect(corePlayer.duration, const Duration(seconds: 5));
      });

      test('player.stream.position -> positionStream', () async {
        final f = corePlayer.positionStream.skip(1).first;
        h.position.add(const Duration(seconds: 2));
        expect(await f, const Duration(seconds: 2));
        expect(corePlayer.position, const Duration(seconds: 2));
      });

      test('player.stream.buffer -> bufferStream', () async {
        final f = corePlayer.bufferStream.skip(1).first;
        h.buffer.add(const Duration(seconds: 3));
        expect(await f, const Duration(seconds: 3));
        expect(corePlayer.buffer, const Duration(seconds: 3));
      });

      test('player.stream.playing -> playingStream + isPlaying', () async {
        final f = corePlayer.playingStream.skip(1).first;
        h.playing.add(true);
        expect(await f, isTrue);
        expect(corePlayer.isPlaying, isTrue);
      });

      test('player.stream.rate -> playbackSpeedStream', () async {
        final f = corePlayer.playbackSpeedStream.skip(1).first;
        h.rate.add(2.0);
        expect(await f, 2.0);
        expect(corePlayer.playbackSpeed, 2.0);
      });
    });

    group('playerStateStream (combineLatest5 on buffer > position)', () {
      // State machine inputs: buffer, playing, position, error, completed.
      // The state machine guards on `_audioSource == null` and returns idle
      // before any other rule fires; these tests preload an audioSource so
      // the remainder of the state machine is exercised.
      setUp(() async {
        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
      });

      test('error -> CorePlayerState.error and sets needToLoad=true', () async {
        final states = <CorePlayerState>[];
        final sub = corePlayer.playerStateStream.listen(states.add);

        h.error.add('boom');
        h.buffer.add(Duration.zero);
        h.position.add(Duration.zero);
        h.playing.add(false);

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(states.contains(CorePlayerState.error), isTrue);
        expect(corePlayer.needToLoad, isTrue);
        await sub.cancel();
      });

      test('buffer > position -> ready', () async {
        final f = corePlayer.playerStateStream.firstWhere(
          (s) => s == CorePlayerState.ready,
        );
        h.buffer.add(const Duration(seconds: 10));
        h.position.add(Duration.zero);
        h.playing.add(false);
        expect(await f, CorePlayerState.ready);
      });

      test('completed=true -> completed', () async {
        final f = corePlayer.playerStateStream.firstWhere(
          (s) => s == CorePlayerState.completed,
        );
        h.buffer.add(Duration.zero);
        h.position.add(Duration.zero);
        h.playing.add(false);
        h.completed.add(true);
        expect(await f, CorePlayerState.completed);
      });

      test('buffer <= position with no completion -> loading', () async {
        final f = corePlayer.playerStateStream.firstWhere(
          (s) => s == CorePlayerState.loading,
        );
        h.buffer.add(Duration.zero);
        h.position.add(Duration.zero);
        h.playing.add(false);
        h.completed.add(false);
        expect(await f, CorePlayerState.loading);
      });

      test('no audioSource loaded -> idle', () async {
        // Construct a fresh player without loading and verify idle persists
        // even when buffering/playing emit values.
        final localPlayer = MockPlayer();
        final localStream = MockPlayerStream();
        final localState = MockPlayerState();
        final localH = _StreamHarness();
        _wireMockStreams(localPlayer, localStream, localState, localH);
        final p = CorePlayerMediaKit(testPlayer: localPlayer);

        final states = <CorePlayerState>[];
        final sub = p.playerStateStream.listen(states.add);

        localH.buffering.add(false);
        localH.playing.add(true);
        localH.completed.add(false);

        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(p.playerState, CorePlayerState.idle);
        // The stream should only have observed idle (seeded value + branch).
        expect(states.every((s) => s == CorePlayerState.idle), isTrue);

        await sub.cancel();
        await p.dispose();
        await localH.close();
      });

      test('transitions away from idle after load()', () async {
        // corePlayer already has source loaded via group-level setUp.
        final f = corePlayer.playerStateStream.firstWhere(
          (s) => s != CorePlayerState.idle,
        );
        h.buffer.add(Duration.zero);
        h.position.add(Duration.zero);
        h.playing.add(false);
        h.completed.add(false);
        expect(await f, isNot(CorePlayerState.idle));
      });
    });

    group('load', () {
      test(
        'opens URL Playlist (single-item) when url provided and resets needToLoad',
        () async {
          final src = CorePlayerAudioSource(
            title: 't',
            url: 'https://example.com/a.mp3',
          );
          await corePlayer.load(src);
          // After Phase 11 the wrapper hands media_kit a one-element Playlist
          // instead of a bare Media, so [setQueue]/[load] always go through
          // the playlist primitive.
          verify(
            () => mockPlayer.open(any(that: isA<Playlist>()), play: false),
          ).called(1);
          expect(corePlayer.audioSource, src);
          expect(corePlayer.needToLoad, isFalse);
        },
      );

      test('opens File Playlist when filePath provided', () async {
        final tmp = File('${Directory.systemTemp.path}/test_audio.mp3');
        await tmp.writeAsBytes([0]);
        final src = CorePlayerAudioSource(title: 't', filePath: tmp.path);
        await corePlayer.load(src);
        verify(
          () => mockPlayer.open(any(that: isA<Playlist>()), play: false),
        ).called(1);
        await tmp.delete();
      });

      test(
        'throws InvalidMediaSourceFailure when neither url nor file provided',
        () async {
          final src = CorePlayerAudioSource(title: 't');
          await expectLater(
            corePlayer.load(src),
            throwsA(isA<InvalidMediaSourceFailure>()),
          );
        },
      );

      test('throws PlayerDisposedFailure when player disposed', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.load(CorePlayerAudioSource(title: 't', url: 'x')),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test('throws LoadFailure when underlying open() fails', () async {
        when(
          () => mockPlayer.open(any(), play: any(named: 'play')),
        ).thenThrow(Exception('open failed'));
        final src = CorePlayerAudioSource(
          title: 't',
          url: 'https://example.com/bogus.mp3',
        );
        await expectLater(
          corePlayer.load(src),
          throwsA(
            isA<LoadFailure>().having(
              (f) => f.cause,
              'cause',
              isA<Exception>(),
            ),
          ),
        );
      });

      test('passes httpHeaders through to Media inside the Playlist', () async {
        final src = CorePlayerAudioSource(
          title: 't',
          url: 'https://example.com/a.mp3',
          httpHeaders: const {'Authorization': 'Bearer x'},
        );
        await corePlayer.load(src);
        // The headers ride along inside the Playlist's single Media; the
        // exact map propagation is covered by Media's own equality checks.
        verify(
          () => mockPlayer.open(
            any(
              that: predicate<Playlist>(
                (p) =>
                    p.medias.length == 1 &&
                    p.medias.first.httpHeaders?['Authorization'] == 'Bearer x',
                'Playlist with one Media carrying the Authorization header',
              ),
            ),
            play: false,
          ),
        ).called(1);
      });
    });

    group('play', () {
      test(
        'throws MediaItemNotSetFailure when audioSource is not set',
        () async {
          await expectLater(
            corePlayer.play(),
            throwsA(isA<MediaItemNotSetFailure>()),
          );
        },
      );

      test('throws PlayerDisposedFailure when disposed', () async {
        await corePlayer.load(CorePlayerAudioSource(title: 't', url: 'x'));
        await corePlayer.dispose();
        await expectLater(
          corePlayer.play(),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test('reloads when needToLoad is true then plays', () async {
        final src = CorePlayerAudioSource(
          title: 't',
          url: 'https://example.com/a.mp3',
        );
        await corePlayer.load(src);
        expect(corePlayer.needToLoad, isFalse);

        corePlayer.needToLoad = true;
        await corePlayer.play();

        verify(() => mockPlayer.open(any(), play: false)).called(2);
        verify(() => mockPlayer.play()).called(1);
      });

      test('seeks to position when provided', () async {
        final src = CorePlayerAudioSource(
          title: 't',
          url: 'https://example.com/a.mp3',
        );
        await corePlayer.load(src);
        await corePlayer.play(position: const Duration(seconds: 12));
        verify(() => mockPlayer.seek(const Duration(seconds: 12))).called(1);
        verify(() => mockPlayer.play()).called(1);
      });

      test('does not seek when position is null', () async {
        final src = CorePlayerAudioSource(
          title: 't',
          url: 'https://example.com/a.mp3',
        );
        await corePlayer.load(src);
        await corePlayer.play();
        verifyNever(() => mockPlayer.seek(any()));
      });
    });

    group('pause', () {
      test('forwards to player.pause', () async {
        await corePlayer.pause();
        verify(() => mockPlayer.pause()).called(1);
      });

      test('throws PlayerDisposedFailure when disposed', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.pause(),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });
    });

    group('seek', () {
      test('forwards mid-range positions', () async {
        when(() => mockState.duration).thenReturn(const Duration(seconds: 100));
        await corePlayer.seek(const Duration(seconds: 50));
        verify(() => mockPlayer.seek(const Duration(seconds: 50))).called(1);
      });

      test('aborts when position within 300ms of end', () async {
        when(() => mockState.duration).thenReturn(const Duration(seconds: 100));
        await corePlayer.seek(const Duration(seconds: 99, milliseconds: 800));
        verifyNever(() => mockPlayer.seek(any()));
      });

      test('clamps positions under 300ms to zero', () async {
        when(() => mockState.duration).thenReturn(const Duration(seconds: 100));
        await corePlayer.seek(const Duration(milliseconds: 100));
        verify(() => mockPlayer.seek(Duration.zero)).called(1);
      });

      test('throws PlayerDisposedFailure when disposed', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.seek(const Duration(seconds: 1)),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });
    });

    group('setPlaybackSpeed', () {
      test('forwards to player.setRate and emits rate', () async {
        when(() => mockState.rate).thenReturn(1.75);
        await corePlayer.setPlaybackSpeed(1.75);
        verify(() => mockPlayer.setRate(1.75)).called(1);
        expect(corePlayer.playbackSpeed, 1.75);
      });

      test('throws PlayerDisposedFailure when disposed', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.setPlaybackSpeed(2.0),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test(
        'throws PlaybackSpeedFailure when underlying setRate fails',
        () async {
          when(
            () => mockPlayer.setRate(any()),
          ).thenThrow(Exception('rate not supported'));
          await expectLater(
            corePlayer.setPlaybackSpeed(99.0),
            throwsA(
              isA<PlaybackSpeedFailure>().having(
                (f) => f.cause,
                'cause',
                isA<Exception>(),
              ),
            ),
          );
        },
      );
    });

    group('setVolume / volumeStream (Phase 9c #1)', () {
      test('initial volume is 1.0 (normalized from media_kit 0-100 scale)', () {
        expect(corePlayer.volume, 1.0);
      });

      test(
        'setVolume(0.5) updates volume, emits on stream, calls native setVolume(50)',
        () async {
          final f = corePlayer.volumeStream.skip(1).first;
          await corePlayer.setVolume(0.5);
          expect(await f, 0.5);
          expect(corePlayer.volume, 0.5);
          verify(() => mockPlayer.setVolume(50.0)).called(1);
        },
      );

      test('setVolume(-0.3) clamps to 0.0', () async {
        await corePlayer.setVolume(-0.3);
        expect(corePlayer.volume, 0.0);
        verify(() => mockPlayer.setVolume(0.0)).called(1);
      });

      test('setVolume(1.5) clamps to 1.0', () async {
        await corePlayer.setVolume(1.5);
        expect(corePlayer.volume, 1.0);
        verify(() => mockPlayer.setVolume(100.0)).called(1);
      });

      test('setVolume after dispose throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.setVolume(0.5),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test('player.stream.volume -> volumeStream (normalized)', () async {
        final f = corePlayer.volumeStream.skip(1).first;
        h.volume.add(75.0);
        expect(await f, 0.75);
        expect(corePlayer.volume, 0.75);
      });
    });

    group('setLoopMode / loopModeStream (Phase 9c #2)', () {
      test('initial loop mode is off', () {
        expect(corePlayer.loopMode, CorePlayerLoopMode.off);
      });

      test(
        'setLoopMode(one) updates state, emits, and calls setPlaylistMode(single)',
        () async {
          final f = corePlayer.loopModeStream.skip(1).first;
          await corePlayer.setLoopMode(CorePlayerLoopMode.one);
          expect(await f, CorePlayerLoopMode.one);
          expect(corePlayer.loopMode, CorePlayerLoopMode.one);
          verify(
            () => mockPlayer.setPlaylistMode(PlaylistMode.single),
          ).called(1);
        },
      );

      test('setLoopMode(off) calls setPlaylistMode(none)', () async {
        await corePlayer.setLoopMode(CorePlayerLoopMode.one);
        await corePlayer.setLoopMode(CorePlayerLoopMode.off);
        expect(corePlayer.loopMode, CorePlayerLoopMode.off);
        verify(() => mockPlayer.setPlaylistMode(PlaylistMode.none)).called(1);
      });

      test(
        'setLoopMode(all) updates state and calls setPlaylistMode(loop)',
        () async {
          final f = corePlayer.loopModeStream.skip(1).first;
          await corePlayer.setLoopMode(CorePlayerLoopMode.all);
          expect(await f, CorePlayerLoopMode.all);
          expect(corePlayer.loopMode, CorePlayerLoopMode.all);
          verify(() => mockPlayer.setPlaylistMode(PlaylistMode.loop)).called(1);
        },
      );

      test('setLoopMode after dispose throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.setLoopMode(CorePlayerLoopMode.one),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });
    });

    group('errorStream (Phase 9c #3)', () {
      test(
        'play() with no audioSource throws MediaItemNotSetFailure AND emits same type on errorStream',
        () async {
          final emitted = <CorePlayerFailure>[];
          final sub = corePlayer.errorStream.listen(emitted.add);

          await expectLater(
            corePlayer.play(),
            throwsA(isA<MediaItemNotSetFailure>()),
          );

          // Drain microtasks so the broadcast emit reaches the listener.
          await Future<void>.delayed(Duration.zero);

          expect(emitted.length, 1);
          expect(emitted.first, isA<MediaItemNotSetFailure>());

          await sub.cancel();
        },
      );

      test(
        'mid-stream player.stream.error event surfaces a LoadFailure on errorStream',
        () async {
          final emitted = <CorePlayerFailure>[];
          final sub = corePlayer.errorStream.listen(emitted.add);

          h.error.add('network drop');
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(emitted.length, 1);
          expect(emitted.first, isA<LoadFailure>());
          expect((emitted.first as LoadFailure).cause, 'network drop');

          await sub.cancel();
        },
      );

      test('a successful load() does NOT emit on errorStream', () async {
        final emitted = <CorePlayerFailure>[];
        final sub = corePlayer.errorStream.listen(emitted.add);

        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(emitted, isEmpty);
        await sub.cancel();
      });
    });

    group('CorePlayerConfiguration (Phase 9c #4)', () {
      // ensureInitialized() touches MediaKit + AudioService natives; we only
      // exercise the static config slot here. The bridge wiring is covered by
      // the bridge's own integration tests.

      test(
        'default configuration: bufferSizeBytes is 5 MiB and Android flags match documented defaults',
        () {
          const config = CorePlayerConfiguration();
          expect(config.bufferSizeBytes, 5 * 1024 * 1024);
          expect(config.androidResumeOnClick, isFalse);
          // Phase 17: both flipped from their legacy "broken on real devices"
          // defaults so the foreground service / MediaSession actually starts
          // and the OS lock-screen surface switches to our MediaItem.
          expect(config.androidNotificationOngoing, isTrue);
          expect(config.androidStopForegroundOnPause, isTrue);
          expect(
            config.androidNotificationChannelId,
            'player_core.audio.default',
          );
          expect(config.androidNotificationChannelName, isNull);
          // Phase 18: explicit icon default so audio_service's foreground
          // service notification is well-formed on Samsung / Xiaomi.
          expect(config.androidNotificationIcon, 'mipmap/ic_launcher');
          expect(config.loadRetry.maxAttempts, 1);
        },
      );

      test(
        'custom configuration round-trips via CorePlayerMediaKit.configuration',
        () {
          final previous = CorePlayerMediaKit.configuration;
          addTearDown(
            () => CorePlayerMediaKit.debugSetConfigurationForTest(previous),
          );

          const custom = CorePlayerConfiguration(
            bufferSizeBytes: 10 * 1024 * 1024,
            androidResumeOnClick: true,
            androidNotificationOngoing: true,
            androidStopForegroundOnPause: false,
            androidNotificationChannelId: 'custom.id',
            androidNotificationChannelName: 'Custom',
          );
          CorePlayerMediaKit.debugSetConfigurationForTest(custom);

          expect(CorePlayerMediaKit.configuration, same(custom));
        },
      );
    });

    group('logCallback (Phase 9d #1)', () {
      tearDown(() {
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
          ),
        );
      });

      test(
        'default configuration has no logCallback (falls back to developer.log)',
        () {
          const config = CorePlayerConfiguration();
          expect(config.logCallback, isNull);
          // Drive the log path — no callback wired, should not throw.
          CorePlayerMediaKit.debugLog('fallback path');
        },
      );

      test(
        'custom logCallback receives messages dispatched through CorePlayerMediaKit.log',
        () {
          final received = <String>[];
          CorePlayerMediaKit.debugSetConfigurationForTest(
            CorePlayerConfiguration(
              logCallback: (message, {error, stackTrace}) {
                received.add(message);
              },
            ),
          );

          CorePlayerMediaKit.debugLog('helloplayer');

          expect(received, contains('helloplayer'));
        },
      );

      test('logCallback receives error + stackTrace forwarded by call sites', () {
        Object? capturedError;
        StackTrace? capturedStack;
        CorePlayerMediaKit.debugSetConfigurationForTest(
          CorePlayerConfiguration(
            logCallback: (message, {error, stackTrace}) {
              capturedError = error;
              capturedStack = stackTrace;
            },
          ),
        );

        final err = Exception('e');
        final st = StackTrace.current;
        // Use the @internal log entry point directly (same package, so allowed).
        CorePlayerMediaKit.log('with error', error: err, stackTrace: st);

        expect(capturedError, err);
        expect(capturedStack, st);
      });
    });

    group('load — retry policy (Phase 9c #5)', () {
      // Speed up backoffs so the suite stays snappy.
      const fastRetry = LoadRetryConfig(
        maxAttempts: 3,
        initialBackoff: Duration(milliseconds: 1),
        maxBackoff: Duration(milliseconds: 1),
      );

      setUp(() {
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
          ),
        );
      });

      tearDown(() {
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
          ),
        );
      });

      test(
        'default config (maxAttempts: 1) — throws on first failure with no retry',
        () async {
          when(
            () => mockPlayer.open(any(), play: any(named: 'play')),
          ).thenThrow(Exception('boom'));
          final src = CorePlayerAudioSource(
            title: 't',
            url: 'https://example.com/a.mp3',
          );
          await expectLater(corePlayer.load(src), throwsA(isA<LoadFailure>()));
          verify(() => mockPlayer.open(any(), play: false)).called(1);
        },
      );

      test(
        'maxAttempts: 3 + fail-fail-succeed → succeeds after 3 attempts',
        () async {
          CorePlayerMediaKit.debugSetConfigurationForTest(
            const CorePlayerConfiguration(
              loadRetry: fastRetry,
              internalPositionThrottle: Duration.zero,
            ),
          );
          var calls = 0;
          when(
            () => mockPlayer.open(any(), play: any(named: 'play')),
          ).thenAnswer((_) async {
            calls++;
            if (calls < 3) throw Exception('attempt $calls failed');
          });

          final src = CorePlayerAudioSource(
            title: 't',
            url: 'https://example.com/a.mp3',
          );
          await corePlayer.load(src);

          verify(() => mockPlayer.open(any(), play: false)).called(3);
          expect(corePlayer.audioSource, src);
        },
      );

      test(
        'maxAttempts: 3 + always-fails → throws LoadFailure after max attempts',
        () async {
          CorePlayerMediaKit.debugSetConfigurationForTest(
            const CorePlayerConfiguration(
              loadRetry: fastRetry,
              internalPositionThrottle: Duration.zero,
            ),
          );
          when(
            () => mockPlayer.open(any(), play: any(named: 'play')),
          ).thenThrow(Exception('always'));
          final src = CorePlayerAudioSource(
            title: 't',
            url: 'https://example.com/a.mp3',
          );

          await expectLater(corePlayer.load(src), throwsA(isA<LoadFailure>()));

          verify(() => mockPlayer.open(any(), play: false)).called(3);
        },
      );

      test(
        'InvalidMediaSourceFailure is NOT retried (no url and no filePath)',
        () async {
          CorePlayerMediaKit.debugSetConfigurationForTest(
            const CorePlayerConfiguration(
              loadRetry: fastRetry,
              internalPositionThrottle: Duration.zero,
            ),
          );
          final src = CorePlayerAudioSource(title: 't');
          await expectLater(
            corePlayer.load(src),
            throwsA(isA<InvalidMediaSourceFailure>()),
          );
          verifyNever(() => mockPlayer.open(any(), play: any(named: 'play')));
        },
      );
    });

    group('waitForReady (Phase 9d #5)', () {
      test('returns immediately if already ready', () async {
        // Drive the state machine into ready via the playerState combineLatest5
        // by emitting buffer > position with an audioSource loaded.
        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
        h.buffer.add(const Duration(seconds: 10));
        h.position.add(Duration.zero);
        h.playing.add(false);
        await corePlayer.playerStateStream.firstWhere(
          (s) => s == CorePlayerState.ready,
        );
        expect(corePlayer.playerState, CorePlayerState.ready);

        // Now waitForReady should complete instantly without listening for new
        // state emissions.
        await corePlayer.waitForReady().timeout(
          const Duration(milliseconds: 50),
        );
      });

      test('awaits the transition to ready', () async {
        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
        // Initially not ready.
        expect(corePlayer.playerState, isNot(CorePlayerState.ready));

        final future = corePlayer.waitForReady();

        // After a microtask, push state into ready (buffer > position).
        scheduleMicrotask(() {
          h.buffer.add(const Duration(seconds: 10));
          h.position.add(Duration.zero);
          h.playing.add(false);
        });

        await future.timeout(const Duration(seconds: 1));
        expect(corePlayer.playerState, CorePlayerState.ready);
      });

      test('throws LoadFailure when state transitions to error', () async {
        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
        final future = corePlayer.waitForReady();

        // Drive into error. Emit error FIRST so the listener routes it
        // into _playerErrorSubject before combineLatest5 fires. Then seed
        // the remaining un-seeded inputs (buffer/position/playing) so
        // combineLatest5 produces its first state with error already set —
        // state goes straight to error, not via a transient ready.
        h.error.add('network drop');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        h.buffer.add(Duration.zero);
        h.position.add(Duration.zero);
        h.playing.add(false);

        await expectLater(
          future,
          throwsA(
            isA<LoadFailure>().having(
              (f) => f.message,
              'message',
              contains('network drop'),
            ),
          ),
        );
      });

      test('on a disposed player throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.waitForReady(),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test('honors timeout', () async {
        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
        // Never push into ready — the wait should time out.
        await expectLater(
          corePlayer.waitForReady(timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
      });
    });

    group('stop', () {
      test('seeks to zero and pauses (non-dispose path)', () async {
        await corePlayer.stop();
        verify(() => mockPlayer.seek(Duration.zero)).called(1);
        verify(() => mockPlayer.pause()).called(1);
        expect(corePlayer.needToLoad, isTrue);
      });

      test('calls player.stop when fromDispose=true', () async {
        await corePlayer.stop(fromDispose: true);
        verify(() => mockPlayer.stop()).called(1);
        verifyNever(() => mockPlayer.pause());
      });

      test(
        'throws PlayerDisposedFailure when disposed and not fromDispose',
        () async {
          await corePlayer.dispose();
          await expectLater(
            corePlayer.stop(),
            throwsA(isA<PlayerDisposedFailure>()),
          );
        },
      );

      test('does not throw when disposed and fromDispose=true', () async {
        await corePlayer.dispose();
        await corePlayer.stop(fromDispose: true);
      });
    });

    group('dispose', () {
      test('marks isDisposed true and is idempotent', () async {
        expect(corePlayer.isDisposed, isFalse);
        await corePlayer.dispose();
        expect(corePlayer.isDisposed, isTrue);
        await corePlayer.dispose();
        verify(() => mockPlayer.dispose()).called(1);
      });

      test('cancels stream subscriptions and closes subjects', () async {
        await corePlayer.dispose();
        h.duration.add(const Duration(seconds: 1));
        h.position.add(const Duration(seconds: 1));
        h.buffer.add(const Duration(seconds: 1));
        h.playing.add(true);
        h.completed.add(true);
        h.rate.add(2.0);
        h.error.add('e');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      test('calls player.dispose', () async {
        await corePlayer.dispose();
        verify(() => mockPlayer.dispose()).called(1);
      });
    });

    group('currentAudioHandler', () {
      test('returns null when no handler attached', () {
        expect(corePlayer.currentAudioHandler, isNull);
      });
    });

    group('play — deferred audio session activation (Phase 16)', () {
      test(
        'constructor (attach) does NOT call bridge.activateSession',
        () async {
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final mockBridge = _MockBridgeForPhase16();
          CoreAudioHandler.debugSetBridge(mockBridge);
          addTearDown(() => CoreAudioHandler.debugSetBridge(null));

          final handler = CoreAudioHandler.instance!;
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioHandler: handler,
          );
          // Let the fire-and-forget attach() in the constructor flush.
          await Future<void>.delayed(Duration.zero);

          // Phase 16: attach no longer activates the session — only play() does.
          expect(mockBridge.activateCallCount, 0);

          await p.dispose();
          await localH.close();
        },
      );

      test(
        'play() calls bridge.activateSession via requestActiveSession',
        () async {
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final mockBridge = _MockBridgeForPhase16();
          CoreAudioHandler.debugSetBridge(mockBridge);
          addTearDown(() => CoreAudioHandler.debugSetBridge(null));

          final handler = CoreAudioHandler.instance!;
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioHandler: handler,
          );
          await Future<void>.delayed(Duration.zero);

          await p.load(
            CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
          );
          expect(mockBridge.activateCallCount, 0);

          await p.play();

          // Now the session is activated — playback intent triggered it.
          expect(mockBridge.activateCallCount, 1);

          await p.dispose();
          await localH.close();
        },
      );

      test(
        'play() activates the session BEFORE emitting the MediaItem (Phase 17)',
        () async {
          // The foreground service / audio_session must be live before
          // audio_service can bridge a MediaItem to the OS lock-screen
          // surface. play() therefore activates the session first; emitting
          // the MediaItem first would leave the bridged value to be silently
          // dropped on some Android versions, and the OS would keep showing
          // whichever app last claimed the surface (e.g. YouTube).
          //
          // To exercise the path where play() itself emits the MediaItem
          // (only happens when attach() returns wasNew=true), we detach the
          // player after construction-time attach + load. The next attach
          // inside play() is then a fresh one, and the gated
          // `emitMediaItem` call inside play() actually fires — letting us
          // observe the activate-then-emit order on the bridge.
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final mockBridge = _MockBridgeForPhase16();
          CoreAudioHandler.debugSetBridge(mockBridge);
          addTearDown(() => CoreAudioHandler.debugSetBridge(null));

          final handler = CoreAudioHandler.instance!;
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioHandler: handler,
          );
          await Future<void>.delayed(Duration.zero);

          await p.load(
            CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
          );
          // Detach so the next attach inside play() is fresh (wasNew=true)
          // and the in-play `emitMediaItem` gate opens.
          await handler.detach(p);

          // Clear any setQueue / detach-driven emits so the order assertion
          // focuses purely on what play() drives.
          mockBridge.callOrder.clear();

          await p.play();

          final activateIdx = mockBridge.callOrder.indexOf('activate');
          final firstMediaItemIdx = mockBridge.callOrder.indexOf('mediaItem');
          expect(
            activateIdx,
            isNonNegative,
            reason: 'activateSession must have been called by play()',
          );
          expect(
            firstMediaItemIdx,
            isNonNegative,
            reason: 'emitMediaItem must have been called by play()',
          );
          expect(
            activateIdx < firstMediaItemIdx,
            isTrue,
            reason:
                'activateSession must run before emitMediaItem (call order was ${mockBridge.callOrder})',
          );

          await p.dispose();
          await localH.close();
        },
      );
    });

    group('play — attachPlayer failure routing (Bug 1)', () {
      test(
        'throws PlayFailure when attachPlayer fails (handler not initialized)',
        () async {
          // Construct a player wired to the singleton handler. The handler is
          // marked initialized in setUpAll, so the constructor's
          // fire-and-forget attach succeeds. We then flip the handler back to
          // uninitialized so the second attach inside play() throws.
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final handler = CoreAudioHandler.instance!;
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioHandler: handler,
          );
          await p.load(
            CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
          );

          // Now make the next attachPlayer call (inside play()) blow up.
          CoreAudioHandler.setInitialized(false);
          addTearDown(() => CoreAudioHandler.setInitialized(true));

          await expectLater(
            p.play(),
            throwsA(
              isA<PlayFailure>().having(
                (f) => f.cause,
                'cause',
                isA<Exception>(),
              ),
            ),
          );

          CoreAudioHandler.setInitialized(true);
          await p.dispose();
          await localH.close();
        },
      );
    });

    group('loadAndPlay — single-flight (Bug 3)', () {
      test(
        'coalesces concurrent invocations to a single open() call',
        () async {
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          // Make open() slow so a second loadAndPlay arrives while the first is
          // still in flight.
          final openCompleter = Completer<void>();
          when(
            () => localPlayer.open(any(), play: any(named: 'play')),
          ).thenAnswer((_) => openCompleter.future);

          final p = CorePlayerMediaKit(testPlayer: localPlayer);
          final src = CorePlayerAudioSource(
            title: 't',
            url: 'https://example.com/a.mp3',
          );

          final f1 = p.loadAndPlay(src);
          final f2 = p.loadAndPlay(src);

          // Both futures should reference the same in-flight work.
          expect(identical(f1, f2), isTrue);

          // Release open() so both complete.
          openCompleter.complete();
          await f1;
          await f2;

          // Verify exactly ONE open() call survived the coalesce.
          verify(() => localPlayer.open(any(), play: false)).called(1);
          verify(() => localPlayer.play()).called(1);

          await p.dispose();
          await localH.close();
        },
      );

      test('a fresh call after the first settles is NOT coalesced', () async {
        final localPlayer = MockPlayer();
        final localStream = MockPlayerStream();
        final localState = MockPlayerState();
        final localH = _StreamHarness();
        _wireMockStreams(localPlayer, localStream, localState, localH);

        final p = CorePlayerMediaKit(testPlayer: localPlayer);
        final srcA = CorePlayerAudioSource(
          title: 'A',
          url: 'https://example.com/a.mp3',
        );
        final srcB = CorePlayerAudioSource(
          title: 'B',
          url: 'https://example.com/b.mp3',
        );

        await p.loadAndPlay(srcA);
        await p.loadAndPlay(srcB);

        // Two distinct sequences ran end-to-end.
        verify(() => localPlayer.open(any(), play: false)).called(2);
        verify(() => localPlayer.play()).called(2);

        await p.dispose();
        await localH.close();
      });

      test(
        'throws PlayerDisposedFailure when called on disposed player',
        () async {
          await corePlayer.dispose();
          expect(
            () => corePlayer.loadAndPlay(
              CorePlayerAudioSource(title: 't', url: 'x'),
            ),
            throwsA(isA<PlayerDisposedFailure>()),
          );
        },
      );
    });

    group('internal position throttle (Phase 9d #3)', () {
      tearDown(() {
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
          ),
        );
      });

      test(
        'rapid native position emissions are coalesced by the 200ms throttle',
        () async {
          // Configure a real throttle (production default) before building the
          // player — the subscription must capture the throttled stream at
          // construction time.
          CorePlayerMediaKit.debugSetConfigurationForTest(
            const CorePlayerConfiguration(
              internalPositionThrottle: Duration(milliseconds: 200),
            ),
          );

          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final p = CorePlayerMediaKit(testPlayer: localPlayer);
          addTearDown(() async {
            await p.dispose();
            await localH.close();
          });

          await p.load(
            CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
          );

          // Counter on the internal pipeline = playerState emissions triggered
          // by combineLatest5. Count distinct emissions to verify throttling.
          final stateEmissions = <CorePlayerState>[];
          final sub = p.playerStateStream.listen(stateEmissions.add);

          // Prime non-throttled inputs once.
          localH.buffer.add(const Duration(seconds: 5));
          localH.playing.add(false);
          await Future<void>.delayed(Duration.zero);

          // Fire 10 rapid position emissions within ~30ms.
          for (var i = 0; i < 10; i++) {
            localH.position.add(Duration(milliseconds: i * 3));
          }

          // Drain microtasks but stay inside the 200ms throttle window.
          await Future<void>.delayed(const Duration(milliseconds: 50));

          // The leading emit lands; trailing waits for the throttle window. At
          // most one trailing combine has fired so far — so combineLatest5
          // emissions count is bounded.
          // We don't assert an exact upper bound because BehaviorSubject seeds
          // can produce 1-2 idle emissions before load() too; instead we verify
          // the playerState observer was not driven 10+ times by the burst.
          expect(stateEmissions.length, lessThan(10));

          await sub.cancel();
        },
      );

      test(
        'public positionStream is NOT throttled (UI scrubbers still see native rate)',
        () async {
          CorePlayerMediaKit.debugSetConfigurationForTest(
            const CorePlayerConfiguration(
              internalPositionThrottle: Duration(milliseconds: 200),
            ),
          );

          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final p = CorePlayerMediaKit(testPlayer: localPlayer);
          addTearDown(() async {
            await p.dispose();
            await localH.close();
          });

          final positions = <Duration>[];
          final sub = p.positionStream.listen(positions.add);

          for (var i = 0; i < 5; i++) {
            localH.position.add(Duration(milliseconds: i * 3));
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // 1 seeded + 5 emits = 6.
          expect(positions.length, 6);

          await sub.cancel();
        },
      );
    });

    group('CorePlayer.observer (Phase 9d #2)', () {
      late _RecordingObserver observer;

      setUp(() {
        observer = _RecordingObserver();
        CorePlayer.observer = observer;
      });

      tearDown(() {
        CorePlayer.observer = null;
      });

      test('onCreate fires on construction', () {
        final localPlayer = MockPlayer();
        final localStream = MockPlayerStream();
        final localState = MockPlayerState();
        final localH = _StreamHarness();
        _wireMockStreams(localPlayer, localStream, localState, localH);

        final p = CorePlayerMediaKit(testPlayer: localPlayer);
        expect(observer.calls, contains('onCreate'));

        unawaited(p.dispose());
        unawaited(localH.close());
      });

      test('onLoad fires with the audio source on load()', () async {
        final src = CorePlayerAudioSource(
          title: 'tagged',
          url: 'https://example.com/a.mp3',
        );
        await corePlayer.load(src);
        expect(observer.calls, contains('onLoad:tagged'));
      });

      test(
        'onError fires when _throwAndEmit runs (disposed-player path)',
        () async {
          await corePlayer.load(
            CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
          );
          await corePlayer.dispose();
          observer.calls.clear();
          await expectLater(
            corePlayer.play(),
            throwsA(isA<PlayerDisposedFailure>()),
          );
          expect(observer.calls.any((c) => c.startsWith('onError:')), isTrue);
        },
      );

      test('onDispose fires at the end of dispose', () async {
        // Reset so we don't count the setUp's corePlayer.
        final localPlayer = MockPlayer();
        final localStream = MockPlayerStream();
        final localState = MockPlayerState();
        final localH = _StreamHarness();
        _wireMockStreams(localPlayer, localStream, localState, localH);

        final p = CorePlayerMediaKit(testPlayer: localPlayer);
        observer.calls.clear();

        await p.dispose();
        expect(observer.calls, contains('onDispose'));

        await localH.close();
      });

      test('onStateChange fires when state transitions', () async {
        await corePlayer.load(
          CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3'),
        );
        observer.calls.clear();

        // Drive into ready via buffer > position.
        h.buffer.add(const Duration(seconds: 5));
        h.playing.add(false);
        h.position.add(Duration.zero);

        await corePlayer.playerStateStream.firstWhere(
          (s) => s == CorePlayerState.ready,
        );
        expect(
          observer.calls.any(
            (c) =>
                c.contains('onStateChange:') &&
                c.endsWith('CorePlayerState.ready'),
          ),
          isTrue,
        );
      });
    });

    group('queue / setQueue / skipTo* (Phase 11)', () {
      const srcA = CorePlayerAudioSource(
        title: 'A',
        url: 'https://example.com/a.mp3',
      );
      const srcB = CorePlayerAudioSource(
        title: 'B',
        url: 'https://example.com/b.mp3',
      );
      const srcC = CorePlayerAudioSource(
        title: 'C',
        url: 'https://example.com/c.mp3',
      );

      test('initial queue is empty and queueStream is seeded', () async {
        expect(corePlayer.queue.isEmpty, isTrue);
        expect(corePlayer.queue.currentIndex, 0);
        expect(corePlayer.queueStream.value.isEmpty, isTrue);
      });

      test(
        'setQueue opens a Playlist with all sources at the right index',
        () async {
          const queue = CorePlayerQueue([srcA, srcB]);
          final emitted = <CorePlayerQueue>[];
          final sub = corePlayer.queueStream.listen(emitted.add);

          await corePlayer.setQueue(queue);
          // Phase 12: queue is a pure projection of player.stream.playlist. The
          // mock's open() emits a matching Playlist on h.playlist, which our
          // subscription mirrors into _queueStreamBacking. Drain microtasks so
          // the listener observes the new value.
          await Future<void>.delayed(Duration.zero);

          expect(corePlayer.queue.length, 2);
          expect(corePlayer.queue.currentIndex, 0);
          expect(corePlayer.audioSource, srcA);
          // Phase 11: one Playlist open() carries the whole queue; media_kit
          // handles transitions natively from there.
          verify(
            () => mockPlayer.open(
              any(
                that: predicate<Playlist>(
                  (p) => p.medias.length == 2 && p.index == 0,
                ),
              ),
              play: false,
            ),
          ).called(1);
          // 1 seeded empty + 1 new queue
          expect(emitted.length, greaterThanOrEqualTo(2));

          await sub.cancel();
        },
      );

      test(
        'setQueue with non-zero currentIndex carries the index into the Playlist',
        () async {
          await corePlayer.setQueue(
            const CorePlayerQueue([srcA, srcB, srcC], currentIndex: 2),
          );
          expect(corePlayer.queue.currentIndex, 2);
          expect(corePlayer.audioSource, srcC);
          verify(
            () => mockPlayer.open(
              any(
                that: predicate<Playlist>(
                  (p) => p.medias.length == 3 && p.index == 2,
                ),
              ),
              play: false,
            ),
          ).called(1);
        },
      );

      test('load(src) still works — internally a single-item queue', () async {
        await corePlayer.load(srcA);
        expect(corePlayer.queue.length, 1);
        expect(corePlayer.queue.current, srcA);
        expect(corePlayer.audioSource, srcA);
        verify(
          () => mockPlayer.open(
            any(that: predicate<Playlist>((p) => p.medias.length == 1)),
            play: false,
          ),
        ).called(1);
      });

      test('setQueue(empty) clears audioSource and stops the player', () async {
        // Pre-load something so stop() is observable as a behavior change.
        await corePlayer.setQueue(const CorePlayerQueue([srcA]));
        clearInteractions(mockPlayer);

        await corePlayer.setQueue(const CorePlayerQueue.empty());

        expect(corePlayer.queue.isEmpty, isTrue);
        expect(corePlayer.audioSource, isNull);
        verifyNever(() => mockPlayer.open(any(), play: any(named: 'play')));
        verify(() => mockPlayer.stop()).called(1);
      });

      test(
        'play() after setQueue(empty) throws MediaItemNotSetFailure',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue.empty());
          await expectLater(
            corePlayer.play(),
            throwsA(isA<MediaItemNotSetFailure>()),
          );
        },
      );

      test('setQueue after dispose throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.setQueue(const CorePlayerQueue([srcA])),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test(
        'skipToIndex forwards to player.jump and syncs index via playlist stream',
        () async {
          const queue = CorePlayerQueue([srcA, srcB, srcC]);
          final observer = _RecordingObserver();
          CorePlayer.observer = observer;
          addTearDown(() => CorePlayer.observer = null);

          await corePlayer.setQueue(queue);
          observer.calls.clear();

          await corePlayer.skipToIndex(2);
          // Phase 11: skipToIndex no longer re-opens — it asks media_kit to jump.
          verify(() => mockPlayer.jump(2)).called(1);
          // Only the initial setQueue open() — no second open() for the skip.
          verify(() => mockPlayer.open(any(), play: false)).called(1);

          // Simulate the resulting playlist emission from media_kit.
          h.playlist.add(
            Playlist([
              Media(srcA.url!),
              Media(srcB.url!),
              Media(srcC.url!),
            ], index: 2),
          );
          await Future<void>.delayed(Duration.zero);

          expect(corePlayer.queue.currentIndex, 2);
          expect(corePlayer.audioSource, srcC);
          expect(observer.calls.any((c) => c == 'onLoad:C'), isTrue);
        },
      );

      test('skipToIndex(-1) throws QueueOutOfBoundsFailure', () async {
        await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
        await expectLater(
          corePlayer.skipToIndex(-1),
          throwsA(isA<QueueOutOfBoundsFailure>()),
        );
        verifyNever(() => mockPlayer.jump(any()));
      });

      test('skipToIndex(length) throws QueueOutOfBoundsFailure', () async {
        await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
        await expectLater(
          corePlayer.skipToIndex(2),
          throwsA(isA<QueueOutOfBoundsFailure>()),
        );
        verifyNever(() => mockPlayer.jump(any()));
      });

      test('skipToIndex after dispose throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.skipToIndex(0),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test(
        'skipToNext forwards to player.next; index updates via playlist stream',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB, srcC]));
          await corePlayer.skipToNext();
          verify(() => mockPlayer.next()).called(1);
          // media_kit emits the new playlist with the advanced index.
          h.playlist.add(
            Playlist([
              Media(srcA.url!),
              Media(srcB.url!),
              Media(srcC.url!),
            ], index: 1),
          );
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue.currentIndex, 1);
          expect(corePlayer.audioSource, srcB);
        },
      );

      test(
        'skipToNext at last index with loopMode=off throws QueueOutOfBoundsFailure',
        () async {
          await corePlayer.setQueue(
            const CorePlayerQueue([srcA, srcB], currentIndex: 1),
          );
          await expectLater(
            corePlayer.skipToNext(),
            throwsA(isA<QueueOutOfBoundsFailure>()),
          );
          verifyNever(() => mockPlayer.next());
        },
      );

      test(
        'skipToNext at last index with loopMode=all forwards to player.next',
        () async {
          await corePlayer.setLoopMode(CorePlayerLoopMode.all);
          await corePlayer.setQueue(
            const CorePlayerQueue([srcA, srcB], currentIndex: 1),
          );
          await corePlayer.skipToNext();
          verify(() => mockPlayer.next()).called(1);
          // media_kit wraps the playlist index back to 0.
          h.playlist.add(
            Playlist([Media(srcA.url!), Media(srcB.url!)], index: 0),
          );
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue.currentIndex, 0);
          expect(corePlayer.audioSource, srcA);
        },
      );

      test(
        'skipToNext on empty queue throws QueueOutOfBoundsFailure',
        () async {
          // Initial state is empty queue, no load required.
          await expectLater(
            corePlayer.skipToNext(),
            throwsA(isA<QueueOutOfBoundsFailure>()),
          );
          verifyNever(() => mockPlayer.next());
        },
      );

      test(
        'skipToPrevious forwards to player.previous; index updates via playlist stream',
        () async {
          await corePlayer.setQueue(
            const CorePlayerQueue([srcA, srcB, srcC], currentIndex: 2),
          );
          await corePlayer.skipToPrevious();
          verify(() => mockPlayer.previous()).called(1);
          h.playlist.add(
            Playlist([
              Media(srcA.url!),
              Media(srcB.url!),
              Media(srcC.url!),
            ], index: 1),
          );
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue.currentIndex, 1);
          expect(corePlayer.audioSource, srcB);
        },
      );

      test('skipToPrevious at index 0 with loopMode=off throws', () async {
        await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
        await expectLater(
          corePlayer.skipToPrevious(),
          throwsA(isA<QueueOutOfBoundsFailure>()),
        );
        verifyNever(() => mockPlayer.previous());
      });

      test(
        'skipToPrevious at index 0 with loopMode=all forwards to player.previous',
        () async {
          await corePlayer.setLoopMode(CorePlayerLoopMode.all);
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB, srcC]));
          await corePlayer.skipToPrevious();
          verify(() => mockPlayer.previous()).called(1);
          h.playlist.add(
            Playlist([
              Media(srcA.url!),
              Media(srcB.url!),
              Media(srcC.url!),
            ], index: 2),
          );
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue.currentIndex, 2);
          expect(corePlayer.audioSource, srcC);
        },
      );

      test(
        'skipToPrevious on empty queue throws QueueOutOfBoundsFailure',
        () async {
          await expectLater(
            corePlayer.skipToPrevious(),
            throwsA(isA<QueueOutOfBoundsFailure>()),
          );
          verifyNever(() => mockPlayer.previous());
        },
      );

      test('skipToNext after dispose throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.skipToNext(),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });

      test(
        'skipToPrevious after dispose throws PlayerDisposedFailure',
        () async {
          await corePlayer.dispose();
          await expectLater(
            corePlayer.skipToPrevious(),
            throwsA(isA<PlayerDisposedFailure>()),
          );
        },
      );
    });

    // Phase 12: media_kit owns playback queue state. The wrapper's queue
    // surface (queue + queueStream) is a pure projection of
    // player.stream.playlist. The wrapper keeps only the typed-source
    // mapping ([_sources]) so it can round-trip a Playlist back into a
    // CorePlayerQueue. setQueue mutates _sources then calls player.open;
    // the playlist subscription is the *only* path that writes the
    // observable queue value.
    group('single source of truth (Phase 12)', () {
      const srcA = CorePlayerAudioSource(
        title: 'A',
        url: 'https://example.com/a.mp3',
      );
      const srcB = CorePlayerAudioSource(
        title: 'B',
        url: 'https://example.com/b.mp3',
      );
      const srcC = CorePlayerAudioSource(
        title: 'C',
        url: 'https://example.com/c.mp3',
      );

      test(
        'queue and queueStream.value always agree after each playlist emission',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB, srcC]));
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue, corePlayer.queueStream.value);
          expect(corePlayer.queue.currentIndex, 0);

          await corePlayer.skipToIndex(2);
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue, corePlayer.queueStream.value);
          expect(corePlayer.queue.currentIndex, 2);

          await corePlayer.skipToPrevious();
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue, corePlayer.queueStream.value);
          expect(corePlayer.queue.currentIndex, 1);
        },
      );

      test(
        'setQueue(empty) emits CorePlayerQueue.empty() exactly once via the empty path',
        () async {
          // Pre-load so the next setQueue(empty) is a real transition.
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
          await Future<void>.delayed(Duration.zero);

          final emitted = <CorePlayerQueue>[];
          final sub = corePlayer.queueStream.listen(emitted.add);
          await Future<void>.delayed(Duration.zero);
          emitted.clear();

          await corePlayer.setQueue(const CorePlayerQueue.empty());
          await Future<void>.delayed(Duration.zero);

          expect(corePlayer.queue.isEmpty, isTrue);
          expect(emitted, contains(const CorePlayerQueue.empty()));
          // After the empty transition, stale platform playlist emissions are
          // ignored — the guard in the playlist subscription discards them.
          h.playlist.add(Playlist([Media(srcA.url!)], index: 0));
          await Future<void>.delayed(Duration.zero);
          expect(corePlayer.queue.isEmpty, isTrue);

          await sub.cancel();
        },
      );

      test(
        'a stale platform playlist emission after setQueue(empty) is ignored',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
          await Future<void>.delayed(Duration.zero);
          await corePlayer.setQueue(const CorePlayerQueue.empty());
          await Future<void>.delayed(Duration.zero);

          // A late, out-of-order Playlist arrival from the platform must not
          // resurrect the queue — [_sources] is empty so the subscription
          // drops it.
          h.playlist.add(
            Playlist([Media(srcA.url!), Media(srcB.url!)], index: 1),
          );
          await Future<void>.delayed(Duration.zero);

          expect(corePlayer.queue.isEmpty, isTrue);
          expect(corePlayer.audioSource, isNull);
        },
      );

      test(
        'media_kit-emitted Playlist drives queue + audioSource (no setQueue write path)',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB, srcC]));
          await Future<void>.delayed(Duration.zero);

          // Simulate auto-advance: media_kit emits index=2 without any wrapper
          // method call. The queue surface tracks it.
          h.playlist.add(
            Playlist([
              Media(srcA.url!),
              Media(srcB.url!),
              Media(srcC.url!),
            ], index: 2),
          );
          await Future<void>.delayed(Duration.zero);

          expect(corePlayer.queue.currentIndex, 2);
          expect(corePlayer.queue.current, srcC);
          expect(corePlayer.audioSource, srcC);
        },
      );

      test(
        'skipToIndex bounds check reads from _sources, not the (lagging) projection',
        () async {
          // _sources is updated synchronously inside setQueue (before open()),
          // so bounds checks are immediately correct even if the projection
          // has not yet landed.
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
          // Note: no Future.delayed — the bounds check must still accept 0..1
          // even before any playlist event has been observed.
          await corePlayer.skipToIndex(1);
          verify(() => mockPlayer.jump(1)).called(1);
        },
      );
    });

    group('auto-advance via playlist stream (Phase 11)', () {
      const srcA = CorePlayerAudioSource(
        title: 'A',
        url: 'https://example.com/a.mp3',
      );
      const srcB = CorePlayerAudioSource(
        title: 'B',
        url: 'https://example.com/b.mp3',
      );

      test(
        'media_kit emitting a new playlist index syncs the wrapper queue and fires onLoad',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
          final observer = _RecordingObserver();
          CorePlayer.observer = observer;
          addTearDown(() => CorePlayer.observer = null);

          // After the initial open(), media_kit's PlaylistMode drives the
          // transition. We simulate the resulting playlist emission for index 1.
          h.playlist.add(
            Playlist([Media(srcA.url!), Media(srcB.url!)], index: 1),
          );
          await Future<void>.delayed(Duration.zero);

          expect(corePlayer.queue.currentIndex, 1);
          expect(corePlayer.audioSource, srcB);
          expect(observer.calls.any((c) => c == 'onLoad:B'), isTrue);
          // No second open(): the auto-advance happened entirely inside media_kit.
          verify(() => mockPlayer.open(any(), play: false)).called(1);
        },
      );

      test('playlist emission with same index is a no-op', () async {
        await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB]));
        final observer = _RecordingObserver();
        CorePlayer.observer = observer;
        addTearDown(() => CorePlayer.observer = null);

        h.playlist.add(Playlist([Media(srcA.url!), Media(srcB.url!)]));
        await Future<void>.delayed(Duration.zero);

        // Active source unchanged; no second onLoad.
        expect(corePlayer.audioSource, srcA);
        expect(observer.calls.where((c) => c.startsWith('onLoad:')).length, 0);
      });

      test(
        'setLoopMode maps to the correct PlaylistMode (media_kit owns the rest)',
        () async {
          await corePlayer.setLoopMode(CorePlayerLoopMode.one);
          verify(
            () => mockPlayer.setPlaylistMode(PlaylistMode.single),
          ).called(1);
          await corePlayer.setLoopMode(CorePlayerLoopMode.all);
          verify(() => mockPlayer.setPlaylistMode(PlaylistMode.loop)).called(1);
          await corePlayer.setLoopMode(CorePlayerLoopMode.off);
          verify(() => mockPlayer.setPlaylistMode(PlaylistMode.none)).called(1);
        },
      );
    });

    group('audioSourceStream / clearQueue (Phase 15)', () {
      const srcA = CorePlayerAudioSource(
        title: 'A',
        url: 'https://example.com/a.mp3',
      );
      const srcB = CorePlayerAudioSource(
        title: 'B',
        url: 'https://example.com/b.mp3',
      );
      const srcC = CorePlayerAudioSource(
        title: 'C',
        url: 'https://example.com/c.mp3',
      );

      test(
        'audioSourceStream is seeded with null when no source is loaded',
        () {
          expect(corePlayer.audioSourceStream.value, isNull);
        },
      );

      test(
        'audioSourceStream emits the new source after setQueue(.single)',
        () async {
          final emitted = <CorePlayerAudioSource?>[];
          final sub = corePlayer.audioSourceStream.listen(emitted.add);

          await corePlayer.setQueue(const CorePlayerQueue([srcA]));
          await Future<void>.delayed(Duration.zero);

          expect(emitted, contains(srcA));
          expect(corePlayer.audioSourceStream.value, srcA);
          await sub.cancel();
        },
      );

      test('audioSourceStream emits null after setQueue(empty)', () async {
        await corePlayer.setQueue(const CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);

        final emitted = <CorePlayerAudioSource?>[];
        final sub = corePlayer.audioSourceStream.listen(emitted.add);
        await Future<void>.delayed(Duration.zero);
        emitted.clear();

        await corePlayer.setQueue(const CorePlayerQueue.empty());
        await Future<void>.delayed(Duration.zero);

        expect(emitted, contains(null));
        expect(corePlayer.audioSourceStream.value, isNull);
        await sub.cancel();
      });

      test('audioSourceStream emits null after clearQueue()', () async {
        await corePlayer.setQueue(const CorePlayerQueue([srcA]));
        await Future<void>.delayed(Duration.zero);
        expect(corePlayer.audioSourceStream.value, srcA);

        await corePlayer.clearQueue();
        await Future<void>.delayed(Duration.zero);

        expect(corePlayer.audioSourceStream.value, isNull);
        expect(corePlayer.audioSource, isNull);
        expect(corePlayer.queue.isEmpty, isTrue);
      });

      test(
        'clearQueue() stops the player (delegates to setQueue(empty))',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA]));
          clearInteractions(mockPlayer);

          await corePlayer.clearQueue();

          verify(() => mockPlayer.stop()).called(1);
        },
      );

      test(
        'audioSourceStream emits the new source after skipToIndex (playlist auto-emit)',
        () async {
          await corePlayer.setQueue(const CorePlayerQueue([srcA, srcB, srcC]));
          await Future<void>.delayed(Duration.zero);

          final emitted = <CorePlayerAudioSource?>[];
          final sub = corePlayer.audioSourceStream.listen(emitted.add);
          await Future<void>.delayed(Duration.zero);
          emitted.clear();

          await corePlayer.skipToIndex(2);
          // Mock player.jump emits a new Playlist; the subscription mirrors it.
          await Future<void>.delayed(Duration.zero);

          expect(emitted, contains(srcC));
          expect(corePlayer.audioSourceStream.value, srcC);
          await sub.cancel();
        },
      );

      test('dispose closes the audioSourceStream subject', () async {
        // Subscribe before dispose so we observe the `done` event.
        var done = false;
        final sub = corePlayer.audioSourceStream.listen(
          (_) {},
          onDone: () => done = true,
        );
        await corePlayer.dispose();
        await Future<void>.delayed(Duration.zero);

        expect(done, isTrue);
        await sub.cancel();
      });
    });

    group('shuffle (Phase 11)', () {
      test('initial shuffle is false', () {
        expect(corePlayer.shuffle, isFalse);
      });

      test(
        'setShuffle(true) forwards to player.setShuffle and updates state + stream',
        () async {
          final emitted = <bool>[];
          final sub = corePlayer.shuffleStream.listen(emitted.add);

          await corePlayer.setShuffle(true);
          await Future<void>.delayed(Duration.zero);
          verify(() => mockPlayer.setShuffle(true)).called(1);
          expect(corePlayer.shuffle, isTrue);
          // seeded false + new true
          expect(emitted, containsAllInOrder([false, true]));

          await sub.cancel();
        },
      );

      test('setShuffle(false) reverses', () async {
        await corePlayer.setShuffle(true);
        await corePlayer.setShuffle(false);
        verify(() => mockPlayer.setShuffle(false)).called(1);
        expect(corePlayer.shuffle, isFalse);
      });

      test('player.stream.shuffle emissions feed into shuffleStream', () async {
        h.shuffle.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(corePlayer.shuffle, isTrue);
      });

      test('setShuffle after dispose throws PlayerDisposedFailure', () async {
        await corePlayer.dispose();
        await expectLater(
          corePlayer.setShuffle(true),
          throwsA(isA<PlayerDisposedFailure>()),
        );
      });
    });

    group('lock-screen skip events (Phase 11)', () {
      const srcA = CorePlayerAudioSource(
        title: 'A',
        url: 'https://example.com/a.mp3',
      );
      const srcB = CorePlayerAudioSource(
        title: 'B',
        url: 'https://example.com/b.mp3',
      );

      test(
        'SkipToNextEvent forwards to player.next when this is current player',
        () async {
          // Wire through CoreAudioHandler so the event subscription is active.
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final handler = CoreAudioHandler.instance!;
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioHandler: handler,
          );
          await p.setQueue(const CorePlayerQueue([srcA, srcB]));

          handler.debugPostEvent(CoreAudioHandlerSkipToNextEvent());
          await Future<void>.delayed(const Duration(milliseconds: 30));

          verify(() => localPlayer.next()).called(1);

          await p.dispose();
          await localH.close();
        },
      );

      test(
        'SkipToPreviousEvent forwards to player.previous when this is current player',
        () async {
          final localPlayer = MockPlayer();
          final localStream = MockPlayerStream();
          final localState = MockPlayerState();
          final localH = _StreamHarness();
          _wireMockStreams(localPlayer, localStream, localState, localH);

          final handler = CoreAudioHandler.instance!;
          final p = CorePlayerMediaKit(
            testPlayer: localPlayer,
            audioHandler: handler,
          );
          await p.setQueue(
            const CorePlayerQueue([srcA, srcB], currentIndex: 1),
          );

          handler.debugPostEvent(CoreAudioHandlerSkipToPreviousEvent());
          await Future<void>.delayed(const Duration(milliseconds: 30));

          verify(() => localPlayer.previous()).called(1);

          await p.dispose();
          await localH.close();
        },
      );
    });
  });
}

/// Records every observer call. Used to verify dispatch from the impl tests.
class _RecordingObserver extends CorePlayerObserver {
  final calls = <String>[];
  @override
  void onCreate(CorePlayer player) => calls.add('onCreate');
  @override
  void onLoad(CorePlayer player, CorePlayerAudioSource source) =>
      calls.add('onLoad:${source.title}');
  @override
  void onPlay(CorePlayer player) => calls.add('onPlay');
  @override
  void onPause(CorePlayer player) => calls.add('onPause');
  @override
  void onStop(CorePlayer player) => calls.add('onStop');
  @override
  void onSeek(CorePlayer player, Duration position) =>
      calls.add('onSeek:$position');
  @override
  void onStateChange(
    CorePlayer player,
    CorePlayerState from,
    CorePlayerState to,
  ) => calls.add('onStateChange:$from->$to');
  @override
  void onError(CorePlayer player, CorePlayerFailure failure) =>
      calls.add('onError:${failure.runtimeType}');
  @override
  void onDispose(CorePlayer player) => calls.add('onDispose');
}
