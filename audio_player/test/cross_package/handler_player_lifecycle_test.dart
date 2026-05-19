import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import '../helpers/test_mocks.dart';
import '_helpers/stream_harness.dart';

class _PlayerFixture {
  _PlayerFixture()
    : mockPlayer = MockPlayer(),
      mockStream = MockPlayerStream(),
      mockState = MockPlayerState(),
      harness = StreamHarness() {
    wirePlayer(mockPlayer, mockStream, mockState, harness);
  }

  final MockPlayer mockPlayer;
  final MockPlayerStream mockStream;
  final MockPlayerState mockState;
  final StreamHarness harness;

  late final CorePlayerMediaKit corePlayer;

  void build({CoreAudioHandler? audioHandler}) {
    corePlayer = CorePlayerMediaKit(testPlayer: mockPlayer, audioHandler: audioHandler);
  }

  void rearm() {
    reset(mockPlayer);
    wirePlayer(mockPlayer, mockStream, mockState, harness);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerMediaKitTestFallbacks();
    CoreAudioHandler.setInitialized(true);
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
  });

  late CoreAudioHandler handler;

  setUp(() {
    detachAllPlayers();
    handler = CoreAudioHandler.instance!;
  });

  tearDown(() {
    detachAllPlayers();
  });

  group('Multi-player coordination via CoreAudioHandler singleton', () {
    test(
      'attaching a second CorePlayerMediaKit pauses the first via the handler '
      'while only the new instance receives subsequent handler events',
      () async {
        final f1 = _PlayerFixture()..build(audioHandler: handler);
        final f2 = _PlayerFixture()..build(audioHandler: handler);
        addTearDown(() async {
          if (!f1.corePlayer.isDisposed) await f1.corePlayer.dispose();
          if (!f2.corePlayer.isDisposed) await f2.corePlayer.dispose();
          await f1.harness.close();
          await f2.harness.close();
        });

        verify(() => f1.mockPlayer.pause()).called(1);
        verifyNever(() => f2.mockPlayer.pause());
        expect(CoreAudioHandler.isCurrentPlayer(f2.corePlayer), isTrue);
        expect(CoreAudioHandler.isCurrentPlayer(f1.corePlayer), isFalse);

        await f2.corePlayer.load(
          HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')),
        );
        f1.rearm();
        f2.rearm();

        handler.debugPostEvent(CoreAudioHandlerPlayEvent());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        verifyNever(() => f1.mockPlayer.play());
        verify(() => f2.mockPlayer.play()).called(1);

        f1.rearm();
        f2.rearm();
        handler.debugPostEvent(CoreAudioHandlerPauseEvent());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        verifyNever(() => f1.mockPlayer.pause());
        verify(() => f2.mockPlayer.pause()).called(1);

        f1.rearm();
        f2.rearm();
        when(() => f2.mockState.duration).thenReturn(const Duration(seconds: 60));
        handler.debugPostEvent(CoreAudioHandlerSeekEvent(const Duration(seconds: 4)));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        verifyNever(() => f1.mockPlayer.seek(any()));
        verify(() => f2.mockPlayer.seek(const Duration(seconds: 4))).called(1);
      },
    );

    test(
      'disposing the current player nulls handler.currentPlayer; subsequent '
      'handler events do not reach the disposed player',
      () async {
        final f1 = _PlayerFixture()..build(audioHandler: handler);
        addTearDown(() async {
          if (!f1.corePlayer.isDisposed) await f1.corePlayer.dispose();
          await f1.harness.close();
        });
        expect(CoreAudioHandler.isCurrentPlayer(f1.corePlayer), isTrue);

        await f1.corePlayer.dispose();

        expect(CoreAudioHandler.currentPlayer, isNull);
        expect(CoreAudioHandler.attachedPlayers, isEmpty);

        f1.rearm();
        handler.debugPostEvent(CoreAudioHandlerPlayEvent());
        handler.debugPostEvent(CoreAudioHandlerPauseEvent());
        await Future<void>.delayed(const Duration(milliseconds: 50));

        verifyNever(() => f1.mockPlayer.play());
        verifyNever(() => f1.mockPlayer.pause());
      },
    );

    test(
      'disposing the current player while a second is attached leaves the '
      'attached set sized 1; surviving player can be promoted to current',
      () async {
        final f1 = _PlayerFixture()..build(audioHandler: handler);
        final f2 = _PlayerFixture()..build(audioHandler: handler);
        addTearDown(() async {
          if (!f1.corePlayer.isDisposed) await f1.corePlayer.dispose();
          if (!f2.corePlayer.isDisposed) await f2.corePlayer.dispose();
          await f1.harness.close();
          await f2.harness.close();
        });

        expect(CoreAudioHandler.isCurrentPlayer(f2.corePlayer), isTrue);
        await f2.corePlayer.dispose();

        expect(CoreAudioHandler.attachedPlayers.length, 1);
        expect(CoreAudioHandler.attachedPlayers, contains(f1.corePlayer));
        expect(CoreAudioHandler.currentPlayer, isNull);

        await f1.corePlayer.load(
          HttpAudioSource(title: 't', url: Uri.parse('https://example.com/a.mp3')),
        );
        await f1.corePlayer.play();
        expect(CoreAudioHandler.isCurrentPlayer(f1.corePlayer), isTrue);
        verify(() => f1.mockPlayer.play()).called(1);
      },
    );

    test(
      'onTaskRemoved stops every non-disposed attached player AND clears the '
      'singleton attached set',
      () async {
        final f1 = _PlayerFixture()..build(audioHandler: handler);
        final f2 = _PlayerFixture()..build(audioHandler: handler);
        addTearDown(() async {
          if (!f1.corePlayer.isDisposed) await f1.corePlayer.dispose();
          if (!f2.corePlayer.isDisposed) await f2.corePlayer.dispose();
          await f1.harness.close();
          await f2.harness.close();
        });

        expect(CoreAudioHandler.attachedPlayers, containsAll([f1.corePlayer, f2.corePlayer]));

        await handler.onTaskRemoved();

        verify(() => f1.mockPlayer.seek(Duration.zero)).called(1);
        verify(() => f1.mockPlayer.pause()).called(2);
        verify(() => f2.mockPlayer.seek(Duration.zero)).called(1);
        verify(() => f2.mockPlayer.pause()).called(1);

        expect(CoreAudioHandler.attachedPlayers, isEmpty);
        expect(CoreAudioHandler.currentPlayer, isNull);
      },
    );
  });
}
