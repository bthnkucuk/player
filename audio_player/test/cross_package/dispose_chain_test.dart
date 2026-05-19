import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import '../helpers/test_mocks.dart';
import '_helpers/stream_harness.dart';

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

  group('End-to-end dispose chain across handler + media_kit player', () {
    test(
      'disposing one of two attached players removes only that one from '
      'attachedPlayers and updates currentPlayer correctly',
      () async {
        final mp1 = MockPlayer();
        final ms1 = MockPlayerStream();
        final mst1 = MockPlayerState();
        final h1 = StreamHarness();
        wirePlayer(mp1, ms1, mst1, h1);
        final p1 = CorePlayerMediaKit(testPlayer: mp1, audioHandler: handler);

        final mp2 = MockPlayer();
        final ms2 = MockPlayerStream();
        final mst2 = MockPlayerState();
        final h2 = StreamHarness();
        wirePlayer(mp2, ms2, mst2, h2);
        final p2 = CorePlayerMediaKit(testPlayer: mp2, audioHandler: handler);

        addTearDown(() async {
          if (!p1.isDisposed) await p1.dispose();
          if (!p2.isDisposed) await p2.dispose();
          await h1.close();
          await h2.close();
        });

        expect(CoreAudioHandler.attachedPlayers.length, 2);
        expect(CoreAudioHandler.isCurrentPlayer(p2), isTrue);

        await p1.dispose();

        expect(CoreAudioHandler.attachedPlayers, isNot(contains(p1)));
        expect(CoreAudioHandler.attachedPlayers, contains(p2));
        expect(CoreAudioHandler.isCurrentPlayer(p2), isTrue);
        verify(() => mp1.dispose()).called(1);
      },
    );

    test(
      'disposing the LAST attached player leaves currentPlayer null and '
      'attachedPlayers empty',
      () async {
        final mp = MockPlayer();
        final ms = MockPlayerStream();
        final mst = MockPlayerState();
        final harness = StreamHarness();
        wirePlayer(mp, ms, mst, harness);
        final p = CorePlayerMediaKit(testPlayer: mp, audioHandler: handler);
        addTearDown(() async {
          await harness.close();
        });

        expect(CoreAudioHandler.attachedPlayers, [p]);
        await p.dispose();

        expect(CoreAudioHandler.attachedPlayers, isEmpty);
        expect(CoreAudioHandler.currentPlayer, isNull);
        expect(p.isDisposed, isTrue);
      },
    );

    test(
      'dispose() is idempotent: a second invocation is a no-op and does not '
      'throw',
      () async {
        final mp = MockPlayer();
        final ms = MockPlayerStream();
        final mst = MockPlayerState();
        final harness = StreamHarness();
        wirePlayer(mp, ms, mst, harness);
        final p = CorePlayerMediaKit(testPlayer: mp, audioHandler: handler);
        addTearDown(() async {
          await harness.close();
        });

        await p.dispose();
        await expectLater(p.dispose(), completes);
        verify(() => mp.dispose()).called(1);
      },
    );

    test(
      'after dispose, the player\'s observable streams emit done',
      () async {
        final mp = MockPlayer();
        final ms = MockPlayerStream();
        final mst = MockPlayerState();
        final harness = StreamHarness();
        wirePlayer(mp, ms, mst, harness);
        final p = CorePlayerMediaKit(testPlayer: mp, audioHandler: handler);
        addTearDown(() async {
          await harness.close();
        });

        final stateDone = expectLater(p.playerStateStream, emitsThrough(emitsDone));
        final positionDone = expectLater(p.positionStream, emitsThrough(emitsDone));
        final durationDone = expectLater(p.durationStream, emitsThrough(emitsDone));
        final bufferDone = expectLater(p.bufferStream, emitsThrough(emitsDone));
        final playingDone = expectLater(p.playingStream, emitsThrough(emitsDone));
        final speedDone = expectLater(p.playbackSpeedStream, emitsThrough(emitsDone));

        await p.dispose();

        await Future.wait([
          stateDone,
          positionDone,
          durationDone,
          bufferDone,
          playingDone,
          speedDone,
        ]);
      },
    );
  });
}
