import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';

/// Regression test for the iOS short-form-video (Reels / TikTok) recovery
/// edge case: when an audio interruption ends silently after the app is
/// foregrounded, the [CoreMediaKitAudioServiceBridge] uses an `AppResume`
/// lifecycle event as a fallback signal to synthesize an InterruptionEnd
/// and resume playback.
///
/// The bridge MUST reset `_interruptedWhilePlaying` after that synthetic
/// resume — otherwise a later unrelated foreground transition (e.g. user
/// briefly background-checks Settings while the player is idle) would
/// falsely restart playback.
///
/// Lives in its own file because [CoreAudioHandler] is a process-wide
/// singleton; isolating this scenario keeps other lifecycle tests from
/// observing the second synthesized resume.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoreAudioHandler.resetForTest();
    CoreAudioHandler.setInitialized(true);
  });

  tearDown(() {
    CoreAudioHandler.resetForTest();
  });

  test(
    'AppResume after stale interruption resets _interruptedWhilePlaying so a '
    'later unrelated AppResume does not falsely restart playback',
    // audio_service_platform_interface routes to NoOpAudioService on Linux
    // and Windows (audio_service_platform_interface.dart:18-21). While this
    // test doesn't drive AudioService.init directly, it shares a process
    // with the rest of the suite; gating on the same platforms keeps CI
    // behaviour uniform with core_audio_service_bridge_initialize_test.dart.
    testOn: '!linux && !windows',
    () async {
      final bridge = CoreMediaKitAudioServiceBridge();
      final handler = CoreAudioHandler.instance!;
      bridge.debugAttachHandler(handler);
      CoreAudioHandler.debugSetBridge(bridge);

      // Collect every event so we can assert on the SECOND AppResume below.
      final received = <CoreAudioHandlerEvent?>[];
      final sub = handler.eventStream.listen(received.add);
      addTearDown(sub.cancel);

      // Stage A — interruption-begin while playing flips the flag.
      bridge.playbackState.add(PlaybackState(playing: true));
      bridge.debugFireInterruption(
        begin: true,
        type: AudioInterruptionType.pause,
      );
      expect(bridge.debugInterruptedWhilePlaying, isTrue);

      // Stage B — AppResume fires the synthetic InterruptionEnd path AND
      // resets the flag so subsequent resumes are treated as unrelated.
      bridge.debugFireAppResume();
      await Future<void>.delayed(Duration.zero);

      final synthesizedEnd = received.whereType<
        CoreAudioHandlerInterruptionEndEvent
      >();
      expect(
        synthesizedEnd, hasLength(1),
        reason:
            'first AppResume after a stale interruption must synthesize one '
            'InterruptionEnd(shouldResume:true) to recover playback',
      );
      expect(synthesizedEnd.single.shouldResume, isTrue);
      expect(
        bridge.debugInterruptedWhilePlaying,
        isFalse,
        reason:
            'the synthesized resume must reset _interruptedWhilePlaying so a '
            'later unrelated AppResume is treated as a normal foreground',
      );

      // Stage C — a SECOND AppResume (no fresh interruption between) must
      // emit an AppResumeEvent, NOT another synthetic InterruptionEnd.
      received.clear();
      bridge.debugFireAppResume();
      await Future<void>.delayed(Duration.zero);

      expect(
        received.whereType<CoreAudioHandlerAppResumeEvent>(),
        hasLength(1),
        reason:
            'second AppResume must surface as AppResumeEvent because the '
            'interruption flag was reset by the first resume',
      );
      expect(
        received.whereType<CoreAudioHandlerInterruptionEndEvent>(),
        isEmpty,
        reason:
            'second AppResume must NOT falsely re-fire InterruptionEnd '
            '(that is the regression this test prevents)',
      );
    },
  );
}
