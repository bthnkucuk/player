import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';

import 'helpers/test_mocks.dart';
import 'test_setup.dart';

Future<void> _detachAll() async {
  for (final p in CoreAudioHandler.attachedPlayers) {
    await CoreAudioHandler.detachPlayer(p);
  }
}

void main() {
  setUpAll(enableEquatableStringify);

  group('CoreAudioHandler', () {
    group('initialization', () {
      test('should expose null instance when not initialized', () {
        CoreAudioHandler.setInitialized(false);

        expect(CoreAudioHandler.instance, isNull);
      });

      test('should expose singleton instance after setInitialized(true)', () {
        CoreAudioHandler.setInitialized(true);

        final handler1 = CoreAudioHandler.instance;
        final handler2 = CoreAudioHandler.instance;

        expect(handler1, isNotNull);
        expect(identical(handler1, handler2), isTrue);
      });

      test(
        'initialize() should be idempotent and return early when already initialized',
        () async {
          CoreAudioHandler.setInitialized(true);

          await expectLater(CoreAudioHandler.initialize(), completes);
          expect(CoreAudioHandler.instance, isNotNull);
        },
      );
    });

    group('attachPlayer', () {
      setUp(() async {
        CoreAudioHandler.setInitialized(true);
        await _detachAll();
      });

      test('should throw when AudioHandler is not initialized', () async {
        CoreAudioHandler.setInitialized(false);
        final player = MockCorePlayer();

        await expectLater(
          CoreAudioHandler.attachPlayer(player),
          throwsA(isA<Exception>()),
        );
      });

      test(
        'should add player to attached set and set it as current when called the first time',
        () async {
          final player = MockCorePlayer();
          when(() => player.isDisposed).thenReturn(false);

          final wasNew = await CoreAudioHandler.attachPlayer(player);

          expect(wasNew, isTrue);
          expect(CoreAudioHandler.currentPlayer, equals(player));
          expect(CoreAudioHandler.attachedPlayers, contains(player));
        },
      );

      test(
        'should return false when re-attaching the already-current player',
        () async {
          final player = MockCorePlayer();
          when(() => player.isDisposed).thenReturn(false);
          await CoreAudioHandler.attachPlayer(player);

          final wasNew = await CoreAudioHandler.attachPlayer(player);

          expect(wasNew, isFalse);
          expect(CoreAudioHandler.currentPlayer, equals(player));
        },
      );

      test(
        'should pause all other non-disposed attached players when a new one becomes current',
        () async {
          final p1 = MockCorePlayer();
          final p2 = MockCorePlayer();
          when(() => p1.isDisposed).thenReturn(false);
          when(() => p2.isDisposed).thenReturn(false);
          when(() => p1.pause()).thenAnswer((_) async {});
          when(() => p2.pause()).thenAnswer((_) async {});

          await CoreAudioHandler.attachPlayer(p1);
          await CoreAudioHandler.attachPlayer(p2);

          verify(() => p1.pause()).called(1);
          verifyNever(() => p2.pause());
          expect(CoreAudioHandler.currentPlayer, equals(p2));
          expect(CoreAudioHandler.attachedPlayers, containsAll([p1, p2]));
        },
      );

      test('should not call pause on disposed players', () async {
        final p1 = MockCorePlayer();
        final p2 = MockCorePlayer();
        when(() => p1.isDisposed).thenReturn(true);
        when(() => p2.isDisposed).thenReturn(false);

        await CoreAudioHandler.attachPlayer(p1);
        await CoreAudioHandler.attachPlayer(p2);

        verifyNever(() => p1.pause());
      });
    });

    group('detachPlayer', () {
      setUp(() async {
        CoreAudioHandler.setInitialized(true);
        await _detachAll();
      });

      test('should throw when not initialized', () async {
        CoreAudioHandler.setInitialized(false);
        final player = MockCorePlayer();

        await expectLater(
          CoreAudioHandler.detachPlayer(player),
          throwsA(isA<Exception>()),
        );
      });

      test(
        'should remove player from attached set and clear current when detaching the current player',
        () async {
          final player = MockCorePlayer();
          when(() => player.isDisposed).thenReturn(false);
          await CoreAudioHandler.attachPlayer(player);

          await CoreAudioHandler.detachPlayer(player);

          expect(CoreAudioHandler.attachedPlayers, isNot(contains(player)));
          expect(CoreAudioHandler.currentPlayer, isNull);
        },
      );

      test(
        'should keep other attached players when detaching a non-current player',
        () async {
          final p1 = MockCorePlayer();
          final p2 = MockCorePlayer();
          when(() => p1.isDisposed).thenReturn(false);
          when(() => p2.isDisposed).thenReturn(false);
          when(() => p1.pause()).thenAnswer((_) async {});
          await CoreAudioHandler.attachPlayer(p1);
          await CoreAudioHandler.attachPlayer(p2);

          await CoreAudioHandler.detachPlayer(p1);

          expect(CoreAudioHandler.attachedPlayers, isNot(contains(p1)));
          expect(CoreAudioHandler.attachedPlayers, contains(p2));
          expect(CoreAudioHandler.currentPlayer, equals(p2));
        },
      );
    });

    group('isCurrentPlayer / getters', () {
      setUp(() async {
        CoreAudioHandler.setInitialized(true);
        await _detachAll();
      });

      test('should return true only for the current player', () async {
        final p1 = MockCorePlayer();
        final p2 = MockCorePlayer();
        when(() => p1.isDisposed).thenReturn(false);
        when(() => p2.isDisposed).thenReturn(false);
        when(() => p1.pause()).thenAnswer((_) async {});

        await CoreAudioHandler.attachPlayer(p1);
        await CoreAudioHandler.attachPlayer(p2);

        expect(CoreAudioHandler.isCurrentPlayer(p2), isTrue);
        expect(CoreAudioHandler.isCurrentPlayer(p1), isFalse);
      });

      test('should expose attached players as a list snapshot', () async {
        final p1 = MockCorePlayer();
        when(() => p1.isDisposed).thenReturn(false);
        await CoreAudioHandler.attachPlayer(p1);

        final attached = CoreAudioHandler.attachedPlayers;

        expect(attached, isA<List<CorePlayer>>());
        expect(attached, contains(p1));
      });

      test('should return null currentPlayer when nothing is attached', () {
        expect(CoreAudioHandler.currentPlayer, isNull);
      });
    });

    group('eventStream', () {
      // After K4, [CoreAudioHandler] no longer extends BaseAudioHandler — the
      // play/pause/seek/stop/fastForward/rewind methods now live on the
      // platform bridge ([CoreAudioServiceBridge]) and emit events INTO the
      // handler via [postEvent]. The abstraction-side contract we test here
      // is just that [eventStream] is a broadcast stream that delivers
      // whatever the bridge pushes through [postEvent] / [debugPostEvent].
      late CoreAudioHandler handler;

      setUp(() async {
        CoreAudioHandler.setInitialized(true);
        await _detachAll();
        handler = CoreAudioHandler.instance!;
      });

      test(
        'eventStream is a broadcast stream that fans events to multiple listeners',
        () async {
          final listenerA = <CoreAudioHandlerEvent?>[];
          final listenerB = <CoreAudioHandlerEvent?>[];
          final subA = handler.eventStream.listen(listenerA.add);
          final subB = handler.eventStream.listen(listenerB.add);

          handler.debugPostEvent(CoreAudioHandlerPlayEvent());
          handler.debugPostEvent(
            CoreAudioHandlerSeekEvent(const Duration(seconds: 4)),
          );

          await Future<void>.delayed(Duration.zero);
          await subA.cancel();
          await subB.cancel();

          expect(listenerA, hasLength(2));
          expect(listenerB, hasLength(2));
          expect(listenerA[0], isA<CoreAudioHandlerPlayEvent>());
          expect(listenerB[0], isA<CoreAudioHandlerPlayEvent>());
          expect(listenerA[1], isA<CoreAudioHandlerSeekEvent>());
          expect(
            (listenerA[1]! as CoreAudioHandlerSeekEvent).position,
            const Duration(seconds: 4),
          );
        },
      );

      test('eventStream preserves event order across event types', () async {
        final events = <CoreAudioHandlerEvent?>[];
        final sub = handler.eventStream.listen(events.add);

        handler.debugPostEvent(CoreAudioHandlerPlayEvent());
        handler.debugPostEvent(CoreAudioHandlerPauseEvent());
        handler.debugPostEvent(CoreAudioHandlerStopEvent());
        handler.debugPostEvent(
          CoreAudioHandlerSeekEvent(const Duration(seconds: 3)),
        );

        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(events, hasLength(4));
        expect(events[0], isA<CoreAudioHandlerPlayEvent>());
        expect(events[1], isA<CoreAudioHandlerPauseEvent>());
        expect(events[2], isA<CoreAudioHandlerStopEvent>());
        expect(events[3], isA<CoreAudioHandlerSeekEvent>());
        expect(
          (events[3]! as CoreAudioHandlerSeekEvent).position,
          const Duration(seconds: 3),
        );
      });
    });

    group('onTaskRemoved', () {
      setUp(() async {
        CoreAudioHandler.setInitialized(true);
        await _detachAll();
      });

      test(
        'should clear current and attached, emit task-removed, and stop non-disposed players',
        () async {
          final handler = CoreAudioHandler.instance!;
          final p1 = MockCorePlayer();
          final p2 = MockCorePlayer();
          when(() => p1.isDisposed).thenReturn(false);
          when(() => p2.isDisposed).thenReturn(false);
          when(() => p1.pause()).thenAnswer((_) async {});
          when(
            () => p1.stop(fromDispose: any(named: 'fromDispose')),
          ).thenAnswer((_) async {});
          when(
            () => p2.stop(fromDispose: any(named: 'fromDispose')),
          ).thenAnswer((_) async {});

          await CoreAudioHandler.attachPlayer(p1);
          await CoreAudioHandler.attachPlayer(p2);

          final taskRemovedFuture = handler.eventStream
              .where((e) => e is CoreAudioHandlerTaskRemovedEvent)
              .first;

          await handler.onTaskRemoved();
          await taskRemovedFuture.timeout(const Duration(seconds: 1));

          expect(CoreAudioHandler.currentPlayer, isNull);
          expect(CoreAudioHandler.attachedPlayers, isEmpty);
          verify(() => p1.stop()).called(1);
          verify(() => p2.stop()).called(1);
        },
      );

      test(
        'should emit CoreAudioHandlerTaskRemovedEvent (not a stop event) when onTaskRemoved is called',
        () async {
          final handler = CoreAudioHandler.instance!;
          final events = <CoreAudioHandlerEvent?>[];
          final sub = handler.eventStream.listen(events.add);

          await handler.onTaskRemoved();
          await Future<void>.delayed(Duration.zero);
          await sub.cancel();

          expect(events, hasLength(1));
          expect(events.single, isA<CoreAudioHandlerTaskRemovedEvent>());
        },
      );

      test('should skip calling stop() on disposed players', () async {
        final handler = CoreAudioHandler.instance!;
        final live = MockCorePlayer();
        final dead = MockCorePlayer();
        when(() => live.isDisposed).thenReturn(false);
        when(() => dead.isDisposed).thenReturn(true);
        when(() => live.pause()).thenAnswer((_) async {});
        when(
          () => live.stop(fromDispose: any(named: 'fromDispose')),
        ).thenAnswer((_) async {});

        await CoreAudioHandler.attachPlayer(dead);
        await CoreAudioHandler.attachPlayer(live);

        await handler.onTaskRemoved();

        verify(() => live.stop()).called(1);
        verifyNever(() => dead.stop(fromDispose: any(named: 'fromDispose')));
        expect(CoreAudioHandler.attachedPlayers, isEmpty);
      });
    });
  });

  group('CoreAudioHandlerEvent toString', () {
    test('CoreAudioHandlerPlayEvent should render its class name', () {
      expect(
        CoreAudioHandlerPlayEvent().toString(),
        'CoreAudioHandlerPlayEvent',
      );
    });

    test('CoreAudioHandlerPauseEvent should render its class name', () {
      expect(
        CoreAudioHandlerPauseEvent().toString(),
        'CoreAudioHandlerPauseEvent',
      );
    });

    test('CoreAudioHandlerStopEvent should render its class name', () {
      expect(
        CoreAudioHandlerStopEvent().toString(),
        'CoreAudioHandlerStopEvent',
      );
    });

    test(
      'CoreAudioHandlerSeekEvent should render its class name and position',
      () {
        final event = CoreAudioHandlerSeekEvent(const Duration(seconds: 7));

        expect(
          event.toString(),
          'CoreAudioHandlerSeekEvent(position: 0:00:07.000000)',
        );
        expect(event.position, const Duration(seconds: 7));
      },
    );

    test('CoreAudioHandlerTaskRemovedEvent should render its class name', () {
      expect(
        CoreAudioHandlerTaskRemovedEvent().toString(),
        'CoreAudioHandlerTaskRemovedEvent',
      );
    });

    test(
      'CoreAudioHandlerInterruptionBeginEvent should render its class name and type',
      () {
        final e = CoreAudioHandlerInterruptionBeginEvent(
          CoreAudioInterruptionType.pause,
        );

        expect(
          e.toString(),
          'CoreAudioHandlerInterruptionBeginEvent(type: CoreAudioInterruptionType.pause)',
        );
        expect(e.type, CoreAudioInterruptionType.pause);
      },
    );

    test(
      'CoreAudioHandlerInterruptionEndEvent should render its class name and shouldResume',
      () {
        final e = CoreAudioHandlerInterruptionEndEvent(shouldResume: true);

        expect(
          e.toString(),
          'CoreAudioHandlerInterruptionEndEvent(shouldResume: true)',
        );
        expect(e.shouldResume, isTrue);
      },
    );

    test('CoreAudioHandlerBecomingNoisyEvent should render its class name', () {
      expect(
        CoreAudioHandlerBecomingNoisyEvent().toString(),
        'CoreAudioHandlerBecomingNoisyEvent',
      );
    });

    test('CoreAudioHandlerAppResumeEvent should render its class name', () {
      expect(
        CoreAudioHandlerAppResumeEvent().toString(),
        'CoreAudioHandlerAppResumeEvent',
      );
    });
  });

  group('Lifecycle events propagate through eventStream', () {
    setUp(() {
      CoreAudioHandler.setInitialized(true);
    });

    test(
      'debugPostEvent forwards interruption/noisy/resume events to listeners in order',
      () async {
        final handler = CoreAudioHandler.instance!;
        final events = <CoreAudioHandlerEvent?>[];
        final sub = handler.eventStream.listen(events.add);

        handler.debugPostEvent(
          CoreAudioHandlerInterruptionBeginEvent(
            CoreAudioInterruptionType.pause,
          ),
        );
        handler.debugPostEvent(
          CoreAudioHandlerInterruptionEndEvent(shouldResume: true),
        );
        handler.debugPostEvent(CoreAudioHandlerBecomingNoisyEvent());
        handler.debugPostEvent(CoreAudioHandlerAppResumeEvent());

        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(events, hasLength(4));
        expect(events[0], isA<CoreAudioHandlerInterruptionBeginEvent>());
        expect(
          (events[0]! as CoreAudioHandlerInterruptionBeginEvent).type,
          CoreAudioInterruptionType.pause,
        );
        expect(events[1], isA<CoreAudioHandlerInterruptionEndEvent>());
        expect(
          (events[1]! as CoreAudioHandlerInterruptionEndEvent).shouldResume,
          isTrue,
        );
        expect(events[2], isA<CoreAudioHandlerBecomingNoisyEvent>());
        expect(events[3], isA<CoreAudioHandlerAppResumeEvent>());
      },
    );
  });
}
