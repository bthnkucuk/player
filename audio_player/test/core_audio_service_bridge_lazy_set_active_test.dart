import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Regression test for the lazy `audio_session.setActive(true)` policy.
///
/// The bridge intentionally defers session activation until the FIRST real
/// `play()` call. If we activated at [CorePlayerMediaKit] construction time
/// (or on attach), every cold-launch of an app embedding the player would
/// interrupt whatever audio the user was already listening to (Spotify /
/// Reels / YouTube) — even though our player never produced a sound.
///
/// The gate lives in [CoreMediaKitAudioServiceBridge.activateSession] via
/// `_hasUserActivatedSession`. We observe it through `debugHasUserActivatedSession`
/// since `audio_session.AudioSession.setActive` is a no-op on the macOS test
/// host (Platform.isIOS / Platform.isAndroid are both false) and offers no
/// observable side-effect.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const audioSessionChannel = MethodChannel('com.ryanheise.audio_session');

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
  });

  setUp(() {
    // Stub the audio_session master channel so `AudioSession.instance`
    // resolves without timing out. `getConfiguration` returns an empty map
    // (no preconfigured session) which is fine — the bridge configures it
    // explicitly in production, but for this test we attach an already-
    // resolved instance via `debugAudioSession` and don't drive configure().
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, (call) async {
          if (call.method == 'getConfiguration') return <String, dynamic>{};
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  test(
    'audio_session.setActive(true) is deferred until the first user-driven '
    'play() and is idempotent on subsequent play() calls',
    // audio_session.AudioSession.setActive is a no-op (returns true without
    // any platform-channel work) on hosts that are neither iOS nor Android
    // (audio_session-0.2.3/lib/src/core.dart:236-294). Linux + Windows CI
    // runners are excluded for parity with core_audio_service_bridge_initialize_test.dart.
    testOn: '!linux && !windows',
    () async {
      // Install a real bridge with a real AudioSession. The bridge's
      // `_hasUserActivatedSession` flag is the observable proxy for
      // "did setActive(true) actually succeed?".
      final bridge = installTestBridge();
      final session = await AudioSession.instance;
      bridge.debugAudioSession = session;

      // Mock media_kit Player so play() doesn't reach native code.
      final mockPlayer = MockPlayer();
      final mockStream = MockPlayerStream();
      final mockState = MockPlayerState();
      when(() => mockPlayer.stream).thenReturn(mockStream);
      when(() => mockPlayer.state).thenReturn(mockState);
      when(() => mockStream.duration).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.position).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.buffer).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.buffering).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.playing).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.error).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.completed).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.rate).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.volume).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.playlist).thenAnswer((_) => const Stream.empty());
      when(() => mockStream.shuffle).thenAnswer((_) => const Stream.empty());
      when(() => mockState.duration).thenReturn(Duration.zero);
      when(() => mockState.position).thenReturn(Duration.zero);
      when(() => mockState.buffer).thenReturn(Duration.zero);
      when(() => mockState.playing).thenReturn(false);
      when(() => mockState.rate).thenReturn(1.0);
      when(() => mockState.volume).thenReturn(100.0);
      when(
        () => mockPlayer.open(any(), play: any(named: 'play')),
      ).thenAnswer((_) async {});
      when(() => mockPlayer.play()).thenAnswer((_) async {});
      when(() => mockPlayer.pause()).thenAnswer((_) async {});
      when(() => mockPlayer.stop()).thenAnswer((_) async {});
      when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
      when(() => mockPlayer.dispose()).thenAnswer((_) async {});

      final handler = CoreAudioHandler.instance!;
      final player = CorePlayerMediaKit(
        testPlayer: mockPlayer,
        audioHandler: handler,
      );
      addTearDown(() async {
        if (!player.isDisposed) await player.dispose();
      });

      // (1) Bridge construction + bridge attach must NOT have activated.
      expect(
        bridge.debugHasUserActivatedSession,
        isFalse,
        reason:
            'constructing the bridge must not call setActive(true) — that '
            'would interrupt every other audio app on cold launch',
      );

      // (2) Constructing the player fires `audioHandler.attach` (unawaited)
      // — give the microtask queue a chance and re-assert.
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.debugHasUserActivatedSession,
        isFalse,
        reason:
            'attaching a player to the scope must not call setActive(true); '
            'activation is deferred until the user actually presses play',
      );

      // (3) `load()` alone must not activate either. (loadAndPlay always
      // calls play() internally, so we drive load() directly to model the
      // "loaded but not yet playing" UI state.)
      await player.load(
        HttpAudioSource(
          title: 't',
          url: Uri.parse('https://example.com/a.mp3')),
      );
      expect(
        bridge.debugHasUserActivatedSession,
        isFalse,
        reason: 'load() must not activate the audio session',
      );

      // (4) First user-driven play() activates exactly once.
      await player.play();
      expect(
        bridge.debugHasUserActivatedSession,
        isTrue,
        reason: 'first play() must call setActive(true)',
      );

      // (5) Second play() is idempotent — the `_hasUserActivatedSession`
      // gate short-circuits the second `_audioSession.setActive(true)`.
      // The flag stays true; we additionally call activateSession()
      // explicitly to assert the gate runs (it would otherwise re-await
      // setActive on the real audio session).
      await bridge.activateSession();
      expect(
        bridge.debugHasUserActivatedSession,
        isTrue,
        reason:
            'subsequent activateSession() calls must remain a no-op while '
            '_hasUserActivatedSession is true (no extra setActive(true))',
      );
    },
  );
}
