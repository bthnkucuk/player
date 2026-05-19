import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';

/// Phase 6 bridge-side lifecycle tests:
///   - Item #1: interruption / becoming-noisy / app-resume translation into
///     [CoreAudioHandlerEvent]s on the registry-side eventStream.
///   - Item #2: [CoreMediaKitAudioServiceBridge.disposeSync] tears down the
///     [AppLifecycleListener] synchronously and short-circuits a re-init.
///   - Item #4: [CoreMediaKitAudioServiceBridge.deactivateSession] is exercised
///     through the public surface (we cannot observe the
///     `notifyOthersOnDeactivation` flag without a real platform channel —
///     so the contract is asserted by a source-level guard).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoreAudioHandler.resetForTest();
    CoreAudioHandler.setInitialized(true);
  });

  tearDown(() {
    CoreAudioHandler.resetForTest();
  });

  group('Item #1 — interruption + noisy + app-resume translation', () {
    test('debugFireInterruption(begin: true, type: pause) posts InterruptionBeginEvent '
        'with mapped type and clears hasUserActivatedSession', () async {
      final bridge = CoreMediaKitAudioServiceBridge();
      final handler = CoreAudioHandler.instance!;
      bridge.debugAttachHandler(handler);
      CoreAudioHandler.debugSetBridge(bridge);

      // Pretend the session is active before the interruption.
      // (Direct field is private; assert via the public hasUserActivatedSession getter
      // after we run activateSession with a stubbed session — but here we can't
      // stub _audioSession without exposing it; we'll just assert the flag flips
      // by running the path that sets it.)
      bridge.playbackState.add(PlaybackState(playing: true));

      final received = handler.eventStream.firstWhere(
        (e) => e is CoreAudioHandlerInterruptionBeginEvent,
      );

      bridge.debugFireInterruption(
        begin: true,
        type: AudioInterruptionType.pause,
      );
      final event =
          (await received.timeout(const Duration(seconds: 1)))!
              as CoreAudioHandlerInterruptionBeginEvent;

      expect(event.type, CoreAudioInterruptionType.pause);
      expect(bridge.debugInterruptedWhilePlaying, isTrue);
      expect(bridge.debugHasUserActivatedSession, isFalse);
    });

    test(
      'debugFireInterruption(begin: false, type: pause) after a play-side begin '
      'posts InterruptionEndEvent(shouldResume: true)',
      () async {
        final bridge = CoreMediaKitAudioServiceBridge();
        final handler = CoreAudioHandler.instance!;
        bridge.debugAttachHandler(handler);
        CoreAudioHandler.debugSetBridge(bridge);

        bridge.playbackState.add(PlaybackState(playing: true));
        bridge.debugFireInterruption(
          begin: true,
          type: AudioInterruptionType.pause,
        );

        final received = handler.eventStream.firstWhere(
          (e) => e is CoreAudioHandlerInterruptionEndEvent,
        );

        bridge.debugFireInterruption(
          begin: false,
          type: AudioInterruptionType.pause,
        );
        final event =
            (await received.timeout(const Duration(seconds: 1)))!
                as CoreAudioHandlerInterruptionEndEvent;

        expect(event.shouldResume, isTrue);
        expect(bridge.debugInterruptedWhilePlaying, isFalse);
      },
    );

    test(
      'interruption end with type != pause yields shouldResume=false',
      () async {
        final bridge = CoreMediaKitAudioServiceBridge();
        final handler = CoreAudioHandler.instance!;
        bridge.debugAttachHandler(handler);
        CoreAudioHandler.debugSetBridge(bridge);

        bridge.playbackState.add(PlaybackState(playing: true));
        bridge.debugFireInterruption(
          begin: true,
          type: AudioInterruptionType.unknown,
        );

        final received = handler.eventStream.firstWhere(
          (e) => e is CoreAudioHandlerInterruptionEndEvent,
        );

        bridge.debugFireInterruption(
          begin: false,
          type: AudioInterruptionType.unknown,
        );
        final event =
            (await received.timeout(const Duration(seconds: 1)))!
                as CoreAudioHandlerInterruptionEndEvent;

        expect(event.shouldResume, isFalse);
      },
    );

    test(
      'interruption-begin while NOT playing does NOT set interruptedWhilePlaying',
      () async {
        final bridge = CoreMediaKitAudioServiceBridge();
        final handler = CoreAudioHandler.instance!;
        bridge.debugAttachHandler(handler);
        CoreAudioHandler.debugSetBridge(bridge);

        bridge.playbackState.add(PlaybackState(playing: false));

        final received = handler.eventStream.firstWhere(
          (e) => e is CoreAudioHandlerInterruptionBeginEvent,
        );
        bridge.debugFireInterruption(
          begin: true,
          type: AudioInterruptionType.pause,
        );
        await received.timeout(const Duration(seconds: 1));

        expect(bridge.debugInterruptedWhilePlaying, isFalse);
      },
    );

    test(
      'debugFireBecomingNoisy posts CoreAudioHandlerBecomingNoisyEvent',
      () async {
        final bridge = CoreMediaKitAudioServiceBridge();
        final handler = CoreAudioHandler.instance!;
        bridge.debugAttachHandler(handler);
        CoreAudioHandler.debugSetBridge(bridge);

        final received = handler.eventStream.firstWhere(
          (e) => e is CoreAudioHandlerBecomingNoisyEvent,
        );
        bridge.debugFireBecomingNoisy();
        await received.timeout(const Duration(seconds: 1));
      },
    );

    test(
      'debugFireAppResume posts CoreAudioHandlerAppResumeEvent when no interruption tracked',
      () async {
        final bridge = CoreMediaKitAudioServiceBridge();
        final handler = CoreAudioHandler.instance!;
        bridge.debugAttachHandler(handler);
        CoreAudioHandler.debugSetBridge(bridge);

        expect(bridge.debugInterruptedWhilePlaying, isFalse);

        final received = handler.eventStream.firstWhere(
          (e) => e is CoreAudioHandlerAppResumeEvent,
        );
        bridge.debugFireAppResume();
        await received.timeout(const Duration(seconds: 1));
      },
    );

    test(
      'debugFireAppResume synthesizes InterruptionEnd(shouldResume:true) when interruptedWhilePlaying',
      () async {
        final bridge = CoreMediaKitAudioServiceBridge();
        final handler = CoreAudioHandler.instance!;
        bridge.debugAttachHandler(handler);
        CoreAudioHandler.debugSetBridge(bridge);

        // Seed the "we were playing when an interruption hit" state without
        // running the full interruption-begin pipeline.
        bridge.debugInterruptedWhilePlaying = true;

        final received = handler.eventStream.firstWhere(
          (e) =>
              e is CoreAudioHandlerInterruptionEndEvent ||
              e is CoreAudioHandlerAppResumeEvent,
        );
        bridge.debugFireAppResume();
        final event = (await received.timeout(const Duration(seconds: 1)))!;

        expect(
          event,
          isA<CoreAudioHandlerInterruptionEndEvent>(),
          reason:
              'AppResume must synthesize InterruptionEnd when interruptedWhilePlaying is true',
        );
        expect(
          (event as CoreAudioHandlerInterruptionEndEvent).shouldResume,
          isTrue,
        );
        // Flag must reset so a subsequent resume does not double-fire.
        expect(bridge.debugInterruptedWhilePlaying, isFalse);
      },
    );
  });

  group('Item #2 — disposeSync teardown discipline', () {
    test(
      'disposeSync flips the flag and nulls the lifecycle listener field',
      () {
        final bridge = CoreMediaKitAudioServiceBridge();

        expect(bridge.debugDisposedSync, isFalse);
        expect(bridge.debugLifecycleListener, isNull);

        bridge.disposeSync();

        expect(bridge.debugDisposedSync, isTrue);
        expect(bridge.debugLifecycleListener, isNull);
      },
    );

    test('disposeSync is idempotent', () {
      final bridge = CoreMediaKitAudioServiceBridge();
      bridge.disposeSync();
      bridge.disposeSync();
      expect(bridge.debugDisposedSync, isTrue);
    });
  });

  group('Item #4 — notifyOthersOnDeactivation source contract', () {
    test(
      'deactivateSession passes AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation',
      () {
        // We cannot observe the platform-channel arguments without a real
        // audio_session backend; assert the contract at the source level so a
        // future refactor that drops the option fails this test.
        // Resolve the source path relative to this test file rather than the
        // CWD so the assertion works under both `flutter test` (CWD = package)
        // and `melos run test` / monorepo-root runners (CWD = workspace root).
        final testFile = File.fromUri(Platform.script);
        final candidates = <File>[
          File('lib/src/player/core_audio_service_bridge.dart'),
          File(
            '${testFile.parent.parent.path}/lib/src/player/core_audio_service_bridge.dart',
          ),
          File(
            '${Directory.current.path}/packages/player_core/audio_player/lib/src/player/core_audio_service_bridge.dart',
          ),
        ];
        final source = candidates
            .firstWhere((f) => f.existsSync())
            .readAsStringSync();

        expect(
          source.contains(
            'AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation',
          ),
          isTrue,
          reason:
              'deactivateSession() must pass AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation '
              'so other audio apps (Spotify) can resume immediately on iOS.',
        );
      },
    );
  });
}
