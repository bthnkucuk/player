import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Minimal stream/state harness mirroring the pattern used by the
/// existing `core_player_media_kit_test.dart`. Local copy so this test
/// file is self-contained — the production harness is a private class
/// in the sibling file.
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
  when(() => mockPlayer.setShuffle(any())).thenAnswer((_) async {});
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

/// Bring the player into a "playing & loaded" state so the offline /
/// metered policy branches actually fire (the policy guards on
/// `isPlaying`).
Future<void> _primePlaying(
  CorePlayerMediaKit player,
  _StreamHarness h,
) async {
  await player.load(
    HttpAudioSource(
      title: 't',
      url: Uri.parse('https://example.com/a.mp3'),
    ),
  );
  // Flip the local isPlaying snapshot through the playing stream subject.
  h.playing.add(true);
  // Allow the synchronous wiring to settle.
  await Future<void>.delayed(Duration.zero);
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
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    // Restore default configuration so other test files start clean.
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
  });

  setUp(() {
    // Each test sets its own policy; default to the standard one.
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
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

  group('CorePlayerMediaKit.notifyNetworkHint', () {
    test('defaults to NetworkHint.unmetered and seeds the stream', () async {
      expect(corePlayer.currentNetworkHint, NetworkHint.unmetered);
      // New subscribers see the seeded value immediately.
      final first = await corePlayer.networkHintStream.first;
      expect(first, NetworkHint.unmetered);
    });

    test('idempotent: re-notifying current hint is a no-op', () async {
      final emissions = <NetworkHint>[];
      final sub = corePlayer.networkHintStream.listen(emissions.add);
      await Future<void>.delayed(Duration.zero); // drain seeded value
      emissions.clear();

      await corePlayer.notifyNetworkHint(NetworkHint.unmetered);
      await Future<void>.delayed(Duration.zero);

      expect(emissions, isEmpty);
      verifyNever(() => mockPlayer.pause());
      await sub.cancel();
    });

    test('default policy: offline while playing → pauses', () async {
      await _primePlaying(corePlayer, h);
      await corePlayer.notifyNetworkHint(NetworkHint.offline);
      verify(() => mockPlayer.pause()).called(1);
      expect(corePlayer.currentNetworkHint, NetworkHint.offline);
    });

    test('default policy: metered while playing → does NOT pause', () async {
      await _primePlaying(corePlayer, h);
      await corePlayer.notifyNetworkHint(NetworkHint.metered);
      verifyNever(() => mockPlayer.pause());
      expect(corePlayer.currentNetworkHint, NetworkHint.metered);
    });

    test('pauseOnMetered=true: metered while playing → pauses', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(
          internalPositionThrottle: Duration.zero,
          networkPolicy: NetworkPolicy(pauseOnMetered: true),
        ),
      );
      await _primePlaying(corePlayer, h);
      await corePlayer.notifyNetworkHint(NetworkHint.metered);
      verify(() => mockPlayer.pause()).called(1);
    });

    test(
      'NetworkPolicy.none: every transition emits but never pauses',
      () async {
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            networkPolicy: NetworkPolicy.none,
          ),
        );
        await _primePlaying(corePlayer, h);
        final emissions = <NetworkHint>[];
        final sub = corePlayer.networkHintStream.listen(emissions.add);
        await Future<void>.delayed(Duration.zero);

        await corePlayer.notifyNetworkHint(NetworkHint.offline);
        await corePlayer.notifyNetworkHint(NetworkHint.metered);
        await corePlayer.notifyNetworkHint(NetworkHint.unmetered);
        await Future<void>.delayed(Duration.zero);

        // Three transitions land in addition to the seeded unmetered value.
        expect(
          emissions,
          containsAllInOrder(<NetworkHint>[
            NetworkHint.offline,
            NetworkHint.metered,
            NetworkHint.unmetered,
          ]),
        );
        verifyNever(() => mockPlayer.pause());
        await sub.cancel();
      },
    );

    test('resumeWhenBackOnline=true: offline → unmetered auto-resumes', () async {
      CorePlayerMediaKit.debugSetConfigurationForTest(
        const CorePlayerConfiguration(
          internalPositionThrottle: Duration.zero,
          networkPolicy: NetworkPolicy(
            pauseOnOffline: true,
            resumeWhenBackOnline: true,
          ),
        ),
      );
      await _primePlaying(corePlayer, h);
      await corePlayer.notifyNetworkHint(NetworkHint.offline);
      verify(() => mockPlayer.pause()).called(1);

      // Simulate the native player flipping playing=false after pause so
      // the auto-resume's eligibility logic is realistic.
      h.playing.add(false);
      await Future<void>.delayed(Duration.zero);

      await corePlayer.notifyNetworkHint(NetworkHint.unmetered);
      verify(() => mockPlayer.play()).called(1);
    });

    test(
      'resumeWhenBackOnline=true: user pause between offline and unmetered cancels resume',
      () async {
        CorePlayerMediaKit.debugSetConfigurationForTest(
          const CorePlayerConfiguration(
            internalPositionThrottle: Duration.zero,
            networkPolicy: NetworkPolicy(
              pauseOnOffline: true,
              resumeWhenBackOnline: true,
            ),
          ),
        );
        await _primePlaying(corePlayer, h);
        await corePlayer.notifyNetworkHint(NetworkHint.offline);
        verify(() => mockPlayer.pause()).called(1);

        h.playing.add(false);
        await Future<void>.delayed(Duration.zero);

        // User-driven pause clears the auto-resume eligibility flag.
        await corePlayer.pause();
        verify(() => mockPlayer.pause()).called(1);

        await corePlayer.notifyNetworkHint(NetworkHint.unmetered);
        // play() must NOT have been called by the policy applier.
        verifyNever(() => mockPlayer.play());
      },
    );

    test('dispose closes the subject; notify after dispose throws', () async {
      await corePlayer.dispose();
      expect(
        () => corePlayer.notifyNetworkHint(NetworkHint.offline),
        throwsA(isA<PlayerDisposedFailure>()),
      );
    });
  });
}
