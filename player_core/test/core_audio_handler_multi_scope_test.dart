import 'package:test/test.dart';

import 'test_setup.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';

import 'helpers/test_mocks.dart';

/// Phase 13 — multi-scope [CoreAudioHandler].
///
/// Verifies that:
///   - The default scope (back-compat) and explicit scopes coexist correctly.
///   - Within a scope, attaching a new player auto-pauses other players
///     (intra-scope behavior preserved from pre-Phase-13).
///   - Across scopes, players play simultaneously — attaching to scope B
///     does NOT pause players in scope A.
///   - Only the active scope drives audio_session activate/deactivate and
///     receives lock-screen events from the bridge.
///   - [CoreAudioHandler.requestSystemAudioFocus] / [releaseSystemAudioFocus]
///     transfer ownership of the OS surface without pausing the previously-
///     active scope's players.
///   - Each scope's [eventStream] is isolated from the others.
class _MockBridge extends Mock implements CoreAudioServiceBridge {
  int refreshMediaItemCallCount = 0;

  @override
  void refreshMediaItemForActiveScope() {
    refreshMediaItemCallCount++;
  }
}

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
    when(() => bridge.emitMediaItem(any())).thenReturn(null);
    when(() => bridge.emitPlaybackState(any())).thenReturn(null);

    CoreAudioHandler.resetForTest();
    CoreAudioHandler.setInitialized(true);
    CoreAudioHandler.debugSetBridge(bridge);
  });

  tearDown(() {
    CoreAudioHandler.resetForTest();
  });

  group('CoreAudioHandler multi-scope — default scope identity', () {
    test(
      'CoreAudioHandler.instance is the same object as activeScope after initialize',
      () {
        final inst = CoreAudioHandler.instance;
        final active = CoreAudioHandler.activeScope;

        expect(inst, isNotNull);
        expect(active, isNotNull);
        expect(identical(inst, active), isTrue);
      },
    );

    test('default scope is active by default', () {
      final inst = CoreAudioHandler.instance!;
      expect(inst.isActiveScope, isTrue);
    });

    test('default scope debugName is "default"', () {
      expect(CoreAudioHandler.instance!.debugName, 'default');
    });
  });

  group('CoreAudioHandler multi-scope — construction', () {
    test(
      'constructing a new scope yields a distinct instance from the default scope',
      () {
        final defaultScope = CoreAudioHandler.instance!;
        final preview = CoreAudioHandler(debugName: 'preview');

        expect(identical(defaultScope, preview), isFalse);
        expect(preview.debugName, 'preview');
      },
    );

    test('newly-constructed scope is NOT the active scope', () {
      final preview = CoreAudioHandler(debugName: 'preview');
      expect(preview.isActiveScope, isFalse);
      expect(CoreAudioHandler.activeScope, isNot(same(preview)));
    });

    test('constructor without debugName synthesizes a name', () {
      final scope = CoreAudioHandler();
      expect(scope.debugName, startsWith('scope-'));
    });
  });

  group('CoreAudioHandler multi-scope — intra-scope behavior preserved', () {
    test(
      'attaching a second player to the SAME scope auto-pauses the first',
      () async {
        final scope = CoreAudioHandler.instance!;
        final p1 = MockTuPlayer();
        final p2 = MockTuPlayer();
        when(() => p1.isDisposed).thenReturn(false);
        when(() => p2.isDisposed).thenReturn(false);
        when(() => p1.pause()).thenAnswer((_) async {});
        when(() => p2.pause()).thenAnswer((_) async {});

        await scope.attach(p1);
        await scope.attach(p2);
        // pause is fire-and-forget — give microtasks a chance to flush.
        await Future<void>.delayed(Duration.zero);

        verify(() => p1.pause()).called(1);
        expect(scope.current, equals(p2));
        expect(scope.isCurrent(p2), isTrue);
        expect(scope.isCurrent(p1), isFalse);
      },
    );
  });

  group('CoreAudioHandler multi-scope — cross-scope independence', () {
    test(
      'attaching a player to scope B does NOT pause players in scope A',
      () async {
        final scopeA = CoreAudioHandler.instance!;
        final scopeB = CoreAudioHandler(debugName: 'B');

        final pA = MockTuPlayer();
        final pB = MockTuPlayer();
        when(() => pA.isDisposed).thenReturn(false);
        when(() => pB.isDisposed).thenReturn(false);
        when(() => pA.pause()).thenAnswer((_) async {});
        when(() => pB.pause()).thenAnswer((_) async {});

        await scopeA.attach(pA);
        await scopeB.attach(pB);
        await Future<void>.delayed(Duration.zero);

        // pA must NOT be paused: it's in a different scope from pB.
        verifyNever(() => pA.pause());

        // Both scopes carry their own current player.
        expect(scopeA.current, equals(pA));
        expect(scopeB.current, equals(pB));
        expect(scopeA.isCurrent(pA), isTrue);
        expect(scopeB.isCurrent(pB), isTrue);
        expect(scopeA.isCurrent(pB), isFalse);
        expect(scopeB.isCurrent(pA), isFalse);
      },
    );

    test('players getter is per-scope, not global', () async {
      final scopeA = CoreAudioHandler.instance!;
      final scopeB = CoreAudioHandler(debugName: 'B');
      final pA = MockTuPlayer();
      final pB = MockTuPlayer();
      when(() => pA.isDisposed).thenReturn(false);
      when(() => pB.isDisposed).thenReturn(false);

      await scopeA.attach(pA);
      await scopeB.attach(pB);

      expect(scopeA.players, contains(pA));
      expect(scopeA.players, isNot(contains(pB)));
      expect(scopeB.players, contains(pB));
      expect(scopeB.players, isNot(contains(pA)));
    });
  });

  group('CoreAudioHandler multi-scope — audio session ownership', () {
    test(
      'attach on the ACTIVE scope (default) does NOT activate the session (deferred to play)',
      () async {
        final scope = CoreAudioHandler.instance!;
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);

        await scope.attach(p);

        // Phase 16: attach no longer activates. requestActiveSession (called
        // from impls' play()) does.
        verifyNever(() => bridge.activateSession());
      },
    );

    test(
      'requestActiveSession on the ACTIVE scope activates the session',
      () async {
        final scope = CoreAudioHandler.instance!;
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);

        await scope.attach(p);
        await scope.requestActiveSession();

        verify(() => bridge.activateSession()).called(1);
      },
    );

    test(
      'requestActiveSession on a NON-ACTIVE scope does NOT activate the session',
      () async {
        final preview = CoreAudioHandler(debugName: 'preview');
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);

        await preview.attach(p);
        await preview.requestActiveSession();

        verifyNever(() => bridge.activateSession());
      },
    );

    test(
      'detach on the ACTIVE scope (last player) deactivates the session',
      () async {
        final scope = CoreAudioHandler.instance!;
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);

        await scope.attach(p);
        await scope.detach(p);

        verify(() => bridge.deactivateSession()).called(1);
      },
    );

    test(
      'detach on a NON-ACTIVE scope does NOT deactivate the session',
      () async {
        final preview = CoreAudioHandler(debugName: 'preview');
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);

        await preview.attach(p);
        await preview.detach(p);

        verifyNever(() => bridge.deactivateSession());
      },
    );
  });

  group('CoreAudioHandler multi-scope — focus transfer', () {
    test(
      'requestSystemAudioFocus on a non-active scope makes it the active scope',
      () async {
        final defaultScope = CoreAudioHandler.instance!;
        final preview = CoreAudioHandler(debugName: 'preview');

        expect(defaultScope.isActiveScope, isTrue);
        expect(preview.isActiveScope, isFalse);

        await preview.requestSystemAudioFocus();

        expect(preview.isActiveScope, isTrue);
        expect(defaultScope.isActiveScope, isFalse);
        expect(CoreAudioHandler.activeScope, same(preview));
      },
    );

    test(
      'requestSystemAudioFocus calls bridge.refreshMediaItemForActiveScope',
      () async {
        final preview = CoreAudioHandler(debugName: 'preview');
        bridge.refreshMediaItemCallCount = 0;

        await preview.requestSystemAudioFocus();

        expect(bridge.refreshMediaItemCallCount, 1);
      },
    );

    test(
      'requestSystemAudioFocus is a no-op when the scope is already active',
      () async {
        final defaultScope = CoreAudioHandler.instance!;
        bridge.refreshMediaItemCallCount = 0;

        await defaultScope.requestSystemAudioFocus();

        expect(bridge.refreshMediaItemCallCount, 0);
      },
    );

    test(
      'requestSystemAudioFocus does NOT pause players in the previously-active scope',
      () async {
        final scopeA = CoreAudioHandler.instance!;
        final scopeB = CoreAudioHandler(debugName: 'B');
        final pA = MockTuPlayer();
        when(() => pA.isDisposed).thenReturn(false);
        when(() => pA.pause()).thenAnswer((_) async {});
        await scopeA.attach(pA);

        // Clear earlier interactions so we can verify the focus transfer doesn't
        // touch pA.
        clearInteractions(pA);

        await scopeB.requestSystemAudioFocus();
        await Future<void>.delayed(Duration.zero);

        verifyNever(() => pA.pause());
        // pA is still attached to scopeA.
        expect(scopeA.players, contains(pA));
        expect(scopeA.current, equals(pA));
      },
    );

    test(
      'releaseSystemAudioFocus falls back to default scope when called with no argument',
      () async {
        final defaultScope = CoreAudioHandler.instance!;
        final preview = CoreAudioHandler(debugName: 'preview');
        await preview.requestSystemAudioFocus();
        expect(preview.isActiveScope, isTrue);

        await preview.releaseSystemAudioFocus();

        expect(preview.isActiveScope, isFalse);
        expect(defaultScope.isActiveScope, isTrue);
      },
    );

    test('releaseSystemAudioFocus respects an explicit fallbackTo', () async {
      final scopeB = CoreAudioHandler(debugName: 'B');
      final scopeC = CoreAudioHandler(debugName: 'C');
      await scopeB.requestSystemAudioFocus();

      await scopeB.releaseSystemAudioFocus(fallbackTo: scopeC);

      expect(scopeC.isActiveScope, isTrue);
      expect(scopeB.isActiveScope, isFalse);
    });

    test(
      'releaseSystemAudioFocus is a no-op when the scope is not active',
      () async {
        final preview = CoreAudioHandler(debugName: 'preview');
        bridge.refreshMediaItemCallCount = 0;

        await preview.releaseSystemAudioFocus();

        expect(bridge.refreshMediaItemCallCount, 0);
      },
    );
  });

  group('CoreAudioHandler multi-scope — event stream isolation', () {
    test(
      'events posted to scope A do not appear on scope B eventStream',
      () async {
        final scopeA = CoreAudioHandler.instance!;
        final scopeB = CoreAudioHandler(debugName: 'B');

        final aEvents = <CoreAudioHandlerEvent?>[];
        final bEvents = <CoreAudioHandlerEvent?>[];
        final aSub = scopeA.eventStream.listen(aEvents.add);
        final bSub = scopeB.eventStream.listen(bEvents.add);

        scopeA.debugPostEvent(CoreAudioHandlerPlayEvent());
        // Flush microtasks / broadcast queue.
        await Future<void>.delayed(Duration.zero);

        expect(aEvents, hasLength(1));
        expect(aEvents.single, isA<CoreAudioHandlerPlayEvent>());
        expect(bEvents, isEmpty);

        await aSub.cancel();
        await bSub.cancel();
      },
    );
  });

  group('CoreAudioHandler multi-scope — activeScopeStream (Phase 15)', () {
    test('initialize seeds activeScopeStream with the default scope', () async {
      // Bypass the shared setUp() which sets _initialized=true without going
      // through initialize(). Reset and call initialize() so the subject sees
      // a fresh transition from null -> default scope.
      CoreAudioHandler.resetForTest();
      await CoreAudioHandler.initialize();

      final emitted = <CoreAudioHandler?>[];
      final sub = CoreAudioHandler.activeScopeStream.listen(emitted.add);
      await Future<void>.delayed(Duration.zero);

      // ValueStream replays the latest value to new subscribers.
      expect(emitted.isNotEmpty, isTrue);
      expect(emitted.last, same(CoreAudioHandler.instance));

      await sub.cancel();
    });

    test('requestSystemAudioFocus emits the new active scope', () async {
      final preview = CoreAudioHandler(debugName: 'preview');
      final emitted = <CoreAudioHandler?>[];
      final sub = CoreAudioHandler.activeScopeStream.listen(emitted.add);
      await Future<void>.delayed(Duration.zero);
      emitted.clear();

      await preview.requestSystemAudioFocus();
      await Future<void>.delayed(Duration.zero);

      expect(emitted.last, same(preview));
      await sub.cancel();
    });

    test('releaseSystemAudioFocus emits the fallback scope', () async {
      final defaultScope = CoreAudioHandler.instance!;
      final preview = CoreAudioHandler(debugName: 'preview');
      await preview.requestSystemAudioFocus();

      final emitted = <CoreAudioHandler?>[];
      final sub = CoreAudioHandler.activeScopeStream.listen(emitted.add);
      await Future<void>.delayed(Duration.zero);
      emitted.clear();

      await preview.releaseSystemAudioFocus();
      await Future<void>.delayed(Duration.zero);

      expect(emitted.last, same(defaultScope));
      await sub.cancel();
    });

    test('resetForTest emits null', () async {
      // Make sure something non-null was seeded first.
      final preview = CoreAudioHandler(debugName: 'preview');
      await preview.requestSystemAudioFocus();
      await Future<void>.delayed(Duration.zero);

      final emitted = <CoreAudioHandler?>[];
      final sub = CoreAudioHandler.activeScopeStream.listen(emitted.add);
      await Future<void>.delayed(Duration.zero);
      emitted.clear();

      CoreAudioHandler.resetForTest();
      await Future<void>.delayed(Duration.zero);

      expect(emitted.last, isNull);
      await sub.cancel();
    });
  });

  group('CoreAudioHandler multi-scope — back-compat statics', () {
    test(
      'legacy static attachPlayer routes through the default scope',
      () async {
        final defaultScope = CoreAudioHandler.instance!;
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);

        await CoreAudioHandler.attachPlayer(p);

        expect(defaultScope.players, contains(p));
        expect(defaultScope.current, equals(p));
        expect(CoreAudioHandler.attachedPlayers, contains(p));
        expect(CoreAudioHandler.currentPlayer, equals(p));
        expect(CoreAudioHandler.isCurrentPlayer(p), isTrue);
      },
    );

    test(
      'legacy static detachPlayer routes through the default scope',
      () async {
        final defaultScope = CoreAudioHandler.instance!;
        final p = MockTuPlayer();
        when(() => p.isDisposed).thenReturn(false);
        await CoreAudioHandler.attachPlayer(p);

        await CoreAudioHandler.detachPlayer(p);

        expect(defaultScope.players, isNot(contains(p)));
        expect(CoreAudioHandler.currentPlayer, isNull);
      },
    );

    test(
      'static attachedPlayers does NOT include players from non-default scopes',
      () async {
        final scopeB = CoreAudioHandler(debugName: 'B');
        final pDefault = MockTuPlayer();
        final pB = MockTuPlayer();
        when(() => pDefault.isDisposed).thenReturn(false);
        when(() => pB.isDisposed).thenReturn(false);

        await CoreAudioHandler.attachPlayer(pDefault);
        await scopeB.attach(pB);

        expect(CoreAudioHandler.attachedPlayers, contains(pDefault));
        expect(CoreAudioHandler.attachedPlayers, isNot(contains(pB)));
        expect(CoreAudioHandler.currentPlayer, equals(pDefault));
      },
    );
  });
}
