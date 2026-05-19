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

  group('CoreAudioHandler integration', () {
    late CoreAudioHandler handler;

    setUp(() async {
      CoreAudioHandler.setInitialized(true);
      await _detachAll();
      handler = CoreAudioHandler.instance!;
    });

    test(
      'attaching three players sequentially should pause earlier players and promote the latest to current',
      () async {
        final p1 = MockCorePlayer();
        final p2 = MockCorePlayer();
        final p3 = MockCorePlayer();
        for (final p in [p1, p2, p3]) {
          when(() => p.isDisposed).thenReturn(false);
          when(() => p.pause()).thenAnswer((_) async {});
        }

        await CoreAudioHandler.attachPlayer(p1);
        await CoreAudioHandler.attachPlayer(p2);
        await CoreAudioHandler.attachPlayer(p3);

        expect(CoreAudioHandler.currentPlayer, equals(p3));
        expect(CoreAudioHandler.attachedPlayers, containsAll([p1, p2, p3]));
        verify(() => p1.pause()).called(2);
        verify(() => p2.pause()).called(1);
        verifyNever(() => p3.pause());
      },
    );

    test(
      'detaching the current player should null currentPlayer while keeping the rest attached',
      () async {
        final p1 = MockCorePlayer();
        final p2 = MockCorePlayer();
        for (final p in [p1, p2]) {
          when(() => p.isDisposed).thenReturn(false);
          when(() => p.pause()).thenAnswer((_) async {});
        }
        await CoreAudioHandler.attachPlayer(p1);
        await CoreAudioHandler.attachPlayer(p2);

        await CoreAudioHandler.detachPlayer(p2);

        expect(CoreAudioHandler.currentPlayer, isNull);
        expect(CoreAudioHandler.attachedPlayers, contains(p1));
        expect(CoreAudioHandler.attachedPlayers, isNot(contains(p2)));
      },
    );

    test(
      'onTaskRemoved should clear all attached players and stop only the non-disposed ones',
      () async {
        final live = MockCorePlayer();
        final disposed = MockCorePlayer();
        when(() => live.isDisposed).thenReturn(false);
        when(() => disposed.isDisposed).thenReturn(true);
        when(() => live.pause()).thenAnswer((_) async {});
        when(
          () => live.stop(fromDispose: any(named: 'fromDispose')),
        ).thenAnswer((_) async {});

        await CoreAudioHandler.attachPlayer(disposed);
        await CoreAudioHandler.attachPlayer(live);

        await handler.onTaskRemoved();

        expect(CoreAudioHandler.attachedPlayers, isEmpty);
        expect(CoreAudioHandler.currentPlayer, isNull);
        verify(() => live.stop()).called(1);
        verifyNever(
          () => disposed.stop(fromDispose: any(named: 'fromDispose')),
        );
      },
    );

    test(
      'event subject should emit play, pause, seek, stop in order (events pushed by bridge)',
      () async {
        // After K4 the platform-control verbs (play/pause/seek/stop) live on the
        // [CoreAudioServiceBridge] implementation. Cross-package tests in
        // audio_player exercise the full bridge round-trip; here we
        // simulate the bridge's role by pushing events directly into the
        // subject.
        final eventsFuture = handler.eventStream.take(4).toList();

        handler.debugPostEvent(CoreAudioHandlerPlayEvent());
        handler.debugPostEvent(CoreAudioHandlerPauseEvent());
        handler.debugPostEvent(
          CoreAudioHandlerSeekEvent(const Duration(seconds: 5)),
        );
        handler.debugPostEvent(CoreAudioHandlerStopEvent());

        final events = await eventsFuture.timeout(const Duration(seconds: 2));

        expect(events.length, 4);
        expect(events[0], isA<CoreAudioHandlerPlayEvent>());
        expect(events[1], isA<CoreAudioHandlerPauseEvent>());
        expect(events[2], isA<CoreAudioHandlerSeekEvent>());
        expect(
          (events[2]! as CoreAudioHandlerSeekEvent).position,
          const Duration(seconds: 5),
        );
        expect(events[3], isA<CoreAudioHandlerStopEvent>());
      },
    );
  });
}
