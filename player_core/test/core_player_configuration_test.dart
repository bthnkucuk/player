import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerConfiguration', () {
    group('defaults (Phase 17)', () {
      // These defaults are the contract that makes audio_service's
      // foreground service / MediaSession actually work out of the box on
      // Android 8+. Treat any change here as a behavioral change requiring
      // a changelog entry — null channel id and dismissable notifications
      // both silently break the lock-screen MediaItem on real devices.
      test('androidNotificationChannelId defaults toplayer.audio.default', () {
        const config = CorePlayerConfiguration();
        expect(
          config.androidNotificationChannelId,
          'player_core.audio.default',
        );
      });

      test('androidNotificationOngoing defaults to true', () {
        const config = CorePlayerConfiguration();
        expect(config.androidNotificationOngoing, isTrue);
      });

      test('other Android flags retain documented defaults', () {
        const config = CorePlayerConfiguration();
        expect(config.androidStopForegroundOnPause, isTrue);
        expect(config.androidResumeOnClick, isFalse);
        expect(config.androidNotificationChannelName, isNull);
      });

      // Phase 18: explicit icon default. Without this, audio_service's
      // foreground service notification is treated as malformed on some
      // Android OEMs (Samsung, Xiaomi), preventing the MediaSession from
      // claiming the OS lock-screen / Now Playing surface.
      test('androidNotificationIcon defaults to mipmap/ic_launcher', () {
        const config = CorePlayerConfiguration();
        expect(config.androidNotificationIcon, 'mipmap/ic_launcher');
      });
    });

    group('overrides (Phase 18)', () {
      test('consumer can override androidNotificationIcon', () {
        const config = CorePlayerConfiguration(
          androidNotificationIcon: 'drawable/custom_icon',
        );
        expect(config.androidNotificationIcon, 'drawable/custom_icon');
      });

      test('non-Android defaults unchanged', () {
        const config = CorePlayerConfiguration();
        expect(config.bufferSizeBytes, 5 * 1024 * 1024);
        expect(config.loadRetry.maxAttempts, 1);
        expect(config.logCallback, isNull);
        expect(
          config.internalPositionThrottle,
          const Duration(milliseconds: 200),
        );
      });
    });

    group('overrides', () {
      test('consumer can override channel id with an app-specific value', () {
        const config = CorePlayerConfiguration(
          androidNotificationChannelId: 'com.myapp.audio',
          androidNotificationChannelName: 'MyApp playback',
        );
        expect(config.androidNotificationChannelId, 'com.myapp.audio');
        expect(config.androidNotificationChannelName, 'MyApp playback');
      });

      test('consumer can opt out of ongoing notification', () {
        const config = CorePlayerConfiguration(
          androidNotificationOngoing: false,
        );
        expect(config.androidNotificationOngoing, isFalse);
      });
    });
  });
}
