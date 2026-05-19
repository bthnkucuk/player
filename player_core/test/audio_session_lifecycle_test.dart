import 'package:test/test.dart';

import 'test_setup.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';

import 'helpers/test_mocks.dart';

/// K5 — audio_session lifecycle.
///
/// Phase 16 deferred session activation one further step:
///   - Phase 5 moved activation from [CoreAudioHandler.initialize] to the first
///     [CoreAudioHandler.attachPlayer].
///   - Phase 16 moves it from `attach` to [CoreAudioHandler.requestActiveSession],
///     which impls call from inside [CorePlayer.play]. Opening a screen with a
///     `CorePlayer` no longer interrupts other apps' audio — only actual
///     playback intent does. This matches Spotify/YouTube behavior.
///
/// The abstraction-side contract verified here is:
///   - `attachPlayer` does NOT call `bridge.activateSession()` anymore.
///   - `requestActiveSession` (called by impls from `play()`) calls
///     `bridge.activateSession()`. Idempotence is owned by the bridge's
///     `_hasUserActivatedSession` gate, so it's safe to call repeatedly.
///   - `detachPlayer` / `onTaskRemoved` still calls `bridge.deactivateSession()`
///     only when no players remain in the active scope (unchanged).
class _MockBridge extends Mock implements CoreAudioServiceBridge {}

void main() {
  setUpAll(() {
    enableEquatableStringify();
    registerTuPlayerTestFallbacks();
  });

  late _MockBridge bridge;

  setUp(() {
    bridge = _MockBridge();
    when(() => bridge.activateSession()).thenAnswer((_) async {});
    when(() => bridge.deactivateSession()).thenAnswer((_) async {});
    when(() => bridge.emitStopState()).thenReturn(null);

    CoreAudioHandler.resetForTest();
    CoreAudioHandler.setInitialized(true);
    CoreAudioHandler.debugSetBridge(bridge);
  });

  tearDown(() {
    CoreAudioHandler.resetForTest();
  });

  group('K5 audio_session lifecycle — attach no longer activates', () {
    test('first attachPlayer does NOT activate the audio session', () async {
      final player = MockTuPlayer();
      when(() => player.isDisposed).thenReturn(false);

      await CoreAudioHandler.attachPlayer(player);

      verifyNever(() => bridge.activateSession());
    });

    test(
      'second attachPlayer (while another is attached) does NOT activate',
      () async {
        final p1 = MockTuPlayer();
        final p2 = MockTuPlayer();
        when(() => p1.isDisposed).thenReturn(false);
        when(() => p2.isDisposed).thenReturn(false);
        when(() => p1.pause()).thenAnswer((_) async {});

        await CoreAudioHandler.attachPlayer(p1);
        await CoreAudioHandler.attachPlayer(p2);

        verifyNever(() => bridge.activateSession());
        verifyNever(() => bridge.deactivateSession());
      },
    );

    test('last detachPlayer deactivates the audio session', () async {
      final player = MockTuPlayer();
      when(() => player.isDisposed).thenReturn(false);
      await CoreAudioHandler.attachPlayer(player);

      clearInteractions(bridge);

      await CoreAudioHandler.detachPlayer(player);

      verify(() => bridge.deactivateSession()).called(1);
    });

    test(
      'detachPlayer with other players still attached does NOT deactivate',
      () async {
        final p1 = MockTuPlayer();
        final p2 = MockTuPlayer();
        when(() => p1.isDisposed).thenReturn(false);
        when(() => p2.isDisposed).thenReturn(false);
        when(() => p1.pause()).thenAnswer((_) async {});

        await CoreAudioHandler.attachPlayer(p1);
        await CoreAudioHandler.attachPlayer(p2);
        clearInteractions(bridge);

        await CoreAudioHandler.detachPlayer(p2);

        verifyNever(() => bridge.deactivateSession());
        expect(CoreAudioHandler.attachedPlayers, contains(p1));
      },
    );

    test('onTaskRemoved deactivates the audio session', () async {
      final handler = CoreAudioHandler.instance!;
      final p1 = MockTuPlayer();
      when(() => p1.isDisposed).thenReturn(false);
      when(() => p1.pause()).thenAnswer((_) async {});
      when(
        () => p1.stop(fromDispose: any(named: 'fromDispose')),
      ).thenAnswer((_) async {});

      await CoreAudioHandler.attachPlayer(p1);
      clearInteractions(bridge);
      when(() => bridge.emitStopState()).thenReturn(null);

      await handler.onTaskRemoved();

      verify(() => bridge.deactivateSession()).called(1);
      expect(CoreAudioHandler.attachedPlayers, isEmpty);
    });

    test(
      'attach/detach are no-ops on the bridge session calls when no bridge is configured',
      () async {
        CoreAudioHandler.debugSetBridge(null);
        final player = MockTuPlayer();
        when(() => player.isDisposed).thenReturn(false);

        await CoreAudioHandler.attachPlayer(player);
        await CoreAudioHandler.detachPlayer(player);

        verifyNever(() => bridge.activateSession());
        verifyNever(() => bridge.deactivateSession());
      },
    );
  });

  group('K5 requestActiveSession — deferred activation on play() intent', () {
    test(
      'requestActiveSession after attach activates the audio session',
      () async {
        final handler = CoreAudioHandler.instance!;
        final player = MockTuPlayer();
        when(() => player.isDisposed).thenReturn(false);

        await handler.attach(player);
        await handler.requestActiveSession();

        verify(() => bridge.activateSession()).called(1);
      },
    );

    test(
      'requestActiveSession with no players attached does NOT activate',
      () async {
        final handler = CoreAudioHandler.instance!;

        await handler.requestActiveSession();

        verifyNever(() => bridge.activateSession());
      },
    );

    test(
      'requestActiveSession on a non-active scope does NOT activate',
      () async {
        final preview = CoreAudioHandler(debugName: 'preview');
        final player = MockTuPlayer();
        when(() => player.isDisposed).thenReturn(false);

        await preview.attach(player);
        await preview.requestActiveSession();

        // preview is not the active scope (the default scope is) → no-op.
        verifyNever(() => bridge.activateSession());
      },
    );

    test('requestActiveSession with no bridge configured is a no-op', () async {
      CoreAudioHandler.debugSetBridge(null);
      final handler = CoreAudioHandler.instance!;
      final player = MockTuPlayer();
      when(() => player.isDisposed).thenReturn(false);

      await handler.attach(player);
      await handler.requestActiveSession();

      // No bridge installed → no throw, no calls.
      verifyNever(() => bridge.activateSession());
    });

    test(
      'requestActiveSession called twice still activates (idempotence is the bridge\'s job)',
      () async {
        final handler = CoreAudioHandler.instance!;
        final player = MockTuPlayer();
        when(() => player.isDisposed).thenReturn(false);

        await handler.attach(player);
        await handler.requestActiveSession();
        await handler.requestActiveSession();

        // The handler forwards every call; the bridge's _hasUserActivatedSession
        // gate deduplicates at the platform layer.
        verify(() => bridge.activateSession()).called(2);
      },
    );

    test(
      'full attach -> requestActiveSession -> detach cycle: activate=1, deactivate=1',
      () async {
        final handler = CoreAudioHandler.instance!;
        final p1 = MockTuPlayer();
        final p2 = MockTuPlayer();
        when(() => p1.isDisposed).thenReturn(false);
        when(() => p2.isDisposed).thenReturn(false);
        when(() => p1.pause()).thenAnswer((_) async {});

        await handler.attach(p1);
        await handler.requestActiveSession();
        await handler.attach(p2);
        // p2's play() would also call requestActiveSession; bridge gates it.
        await handler.requestActiveSession();
        await handler.detach(p1);
        await handler.detach(p2);

        // Handler forwards both requestActiveSession calls; deactivate fires once
        // on the last detach (only when scope becomes empty).
        verify(() => bridge.activateSession()).called(2);
        verify(() => bridge.deactivateSession()).called(1);
      },
    );
  });

  group('K5 initialize() does NOT activate the audio session eagerly', () {
    test(
      'initialize() never calls activateSession — only requestActiveSession does',
      () async {
        // Drive initialize() against a fresh bridge mock.
        CoreAudioHandler.resetForTest();
        final freshBridge = _MockBridge();
        when(() => freshBridge.initialize(any())).thenAnswer((_) async {});
        when(() => freshBridge.activateSession()).thenAnswer((_) async {});
        when(() => freshBridge.deactivateSession()).thenAnswer((_) async {});
        CoreAudioHandler.debugSetBridge(freshBridge);

        await CoreAudioHandler.initialize();

        verify(() => freshBridge.initialize(any())).called(1);
        verifyNever(() => freshBridge.activateSession());
      },
    );
  });
}
