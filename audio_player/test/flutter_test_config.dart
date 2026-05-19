import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:equatable/equatable.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Strategy §8.6: global Equatable stringify so bloc_test failure diffs
  // show field values, not just "MyState". Per-class `stringify => true` overrides
  // are no longer needed.
  EquatableConfig.stringify = true;

  // Phase 9d #3: disable the internal position throttle for tests so the
  // playerState combineLatest5 fires synchronously off single position emits.
  // Production default remains 200ms.
  CorePlayerMediaKit.debugSetConfigurationForTest(const CorePlayerConfiguration(internalPositionThrottle: Duration.zero));

  LeakTesting.enable();
  LeakTesting.settings = LeakTesting.settings
      .withTracked(allNotDisposed: true, experimentalAllNotGCed: true)
      .withCreationStackTrace()
      .withIgnored(
        classes: const [
          // media_kit wraps a native player + isolate; tests mock `Player` via
          // mocktail, but `PlayerStream`/`PlayerStateStream` BehaviorSubjects
          // and internal Timers can leak when test harness tears the binding
          // down before all rxdart broadcast listeners drain. Extend this list
          // if Phase C surfaces additional classes (e.g. `NativePlayer`,
          // `PlatformPlayer`, `VideoController`, `MediaKitController`).
          'Player',
          'PlayerStream',
        ],
      );

  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(
      platformGoldensConfig: PlatformGoldensConfig(enabled: false),
      ciGoldensConfig: CiGoldensConfig(enabled: true, obscureText: false, renderShadows: true),
    ),
    run: testMain,
  );
}
