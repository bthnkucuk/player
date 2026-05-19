import 'package:player_core/src/player/core_audio_source.dart';

/// Signature for the logger callback wired through
/// [CorePlayerConfiguration.logCallback]. Pass an adapter that forwards into
/// talker / logging / your own observer so the wrapper doesn't bind consumers
/// to a specific logging library.
typedef CorePlayerLogCallback =
    void Function(String message, {Object? error, StackTrace? stackTrace});

/// Signature for the queue-exhaustion callback wired through
/// [CorePlayerConfiguration.onQueueExhausted]. Returning a non-null,
/// non-empty list appends the sources to the active queue and continues
/// playback; returning null or an empty list lets the player stop
/// naturally.
typedef CorePlayerOnQueueExhausted =
    Future<List<CoreAudioSource>>? Function();

/// Wrapper-level configuration for [CorePlayer] implementations. Pass to the
/// impl's `ensureInitialized()` to override defaults.
///
/// All fields are optional — defaults match the wrapper's voice-note /
/// single-stream tuning.
class CorePlayerConfiguration {
  const CorePlayerConfiguration({
    this.bufferSizeBytes = 5 * 1024 * 1024,
    this.androidNotificationChannelId = 'player_core.audio.default',
    this.androidNotificationChannelName,
    this.androidNotificationOngoing = true,
    this.androidStopForegroundOnPause = true,
    this.androidResumeOnClick = false,
    this.androidNotificationIcon = 'mipmap/ic_launcher',
    this.loadRetry = const LoadRetryConfig.disabled(),
    this.logCallback,
    this.internalPositionThrottle = const Duration(milliseconds: 200),
    this.libmpvOptions,
    this.onQueueExhausted,
    this.heartbeatInterval,
  });

  /// Native player buffer size in bytes. Larger = smoother streaming over
  /// flaky networks at the cost of memory. Default 5 MiB suits voice notes
  /// and short-form audio.
  final int bufferSizeBytes;

  /// Android notification channel ID used by audio_service to surface the
  /// foreground-service notification (lock-screen / Now Playing).
  ///
  /// Default `'player_core.audio.default'` (non-null) — Android 8+ refuses to
  /// start a foreground service without a valid notification channel. With a
  /// null ID, audio_service's foreground service silently fails to start and
  /// the OS lock-screen / Now Playing surface never switches to our
  /// `MediaItem` (it stays on whatever app last claimed it — e.g. YouTube).
  ///
  /// Consumers can still override with their own app-specific channel ID
  /// (e.g. `'com.myapp.audio'`); only the null case is no longer the
  /// default, because it is functionally broken on real devices.
  final String androidNotificationChannelId;

  /// Android notification channel display name. If null, the underlying
  /// audio_service default is used.
  final String? androidNotificationChannelName;

  /// Forwarded to `AudioServiceConfig.androidNotificationOngoing`.
  ///
  /// Default `true` — Android requires foreground-service notifications to
  /// be "ongoing" (non-dismissable while the service runs) for the
  /// foreground-service contract to hold. With `ongoing: false`, the
  /// notification is dismissable and Android may silently demote the
  /// service back to a regular background service, disconnecting the
  /// `MediaSession` from the lock-screen.
  final bool androidNotificationOngoing;

  /// Forwarded to `AudioServiceConfig.androidStopForegroundOnPause`.
  final bool androidStopForegroundOnPause;

  /// Forwarded to `AudioServiceConfig.androidResumeOnClick`.
  final bool androidResumeOnClick;

  /// Small icon shown in the Android notification + lock-screen surface.
  /// Format: `'drawable/<name>'` or `'mipmap/<name>'` referencing a resource
  /// in the consuming app's `android/app/src/main/res/`.
  ///
  /// **Strongly recommended** to set this explicitly. Without it,
  /// audio_service falls back to a generic icon, and on some Android
  /// OEMs (Samsung One UI, Xiaomi MIUI) the foreground service
  /// notification is treated as malformed — MediaSession then fails to
  /// claim the lock-screen / Now Playing surface, and whichever app
  /// last held it (YouTube, Spotify) remains the visible player even
  /// though our audio is playing.
  ///
  /// Default: 'mipmap/ic_launcher' — matches the launcher icon that
  /// `flutter create` ships by default. Override per-app if your icon
  /// has a different name or you want a dedicated playback glyph.
  final String androidNotificationIcon;

  /// Retry policy for `load()`. Defaults to disabled (single attempt).
  final LoadRetryConfig loadRetry;

  /// Optional logger. If null, the package falls back to `developer.log`.
  /// Wire to talker / logging / your own observer in app bootstrap.
  final CorePlayerLogCallback? logCallback;

  /// Throttle window applied to the INTERNAL position input that feeds the
  /// playerState combineLatest5. The public `positionStream` is NOT throttled —
  /// UI scrubbers still see emissions at native rate (~30 Hz on media_kit).
  ///
  /// Default 200ms. Set [Duration.zero] to disable the throttle (used by tests
  /// that synchronously drive the state machine off a single position emit).
  final Duration internalPositionThrottle;

  /// libmpv property overrides applied at [CorePlayer] construction time.
  ///
  /// Backend-specific knobs forwarded to libmpv via `setProperty`. Keys are
  /// libmpv property names (see https://mpv.io/manual/master/), values are
  /// their string representations. Overrides are merged on top of the
  /// backend's sensible defaults — pass an explicit empty string to disable
  /// a default.
  ///
  /// Example — opt out of the default fastseek workaround:
  /// ```dart
  /// CorePlayerConfiguration(libmpvOptions: {'demuxer-lavf-o': ''})
  /// ```
  ///
  /// Only honored by the media_kit-based backend; ignored elsewhere.
  final Map<String, String>? libmpvOptions;

  /// Called when the player exhausts the active queue (last item finishes
  /// naturally — NOT when the user pauses/stops). The future's resolved
  /// value, if non-null and non-empty, is appended to the queue and
  /// playback continues; otherwise the player remains in the completed
  /// state.
  ///
  /// Wrapper is intentionally opinion-free: the app's recommendation
  /// engine decides what plays next.
  final CorePlayerOnQueueExhausted? onQueueExhausted;

  /// Heartbeat interval for [PlaybackHeartbeatEvent] emission. Null
  /// disables heartbeats (default). Typical analytics value: 30 seconds.
  ///
  /// Opt-in to avoid analytics-pipeline cost for apps that don't need
  /// royalty heartbeats; royalty / "minutes listened" pipelines wire this
  /// to a non-null value and consume the resulting periodic event.
  final Duration? heartbeatInterval;
}

/// Retry policy for `CorePlayer.load()`. When [maxAttempts] is 1 the wrapper
/// performs no retries — the first failure surfaces immediately as a
/// `LoadFailure`. For `maxAttempts > 1`, each retry waits
/// [initialBackoff] (subsequently multiplied by [backoffMultiplier], clamped
/// to [maxBackoff]) before the next attempt.
class LoadRetryConfig {
  const LoadRetryConfig({
    required this.maxAttempts,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.backoffMultiplier = 2.0,
    this.maxBackoff = const Duration(seconds: 8),
  });

  /// Convenience constructor for the "no retries" default.
  const LoadRetryConfig.disabled() : this(maxAttempts: 1);

  /// Total attempt count including the first. Set to 1 to disable retry.
  final int maxAttempts;

  /// Backoff before the first retry. Doubled (subject to [backoffMultiplier])
  /// for each subsequent attempt up to [maxBackoff].
  final Duration initialBackoff;

  /// Multiplier applied to the previous backoff after each failed attempt.
  final double backoffMultiplier;

  /// Upper bound on the per-attempt backoff.
  final Duration maxBackoff;
}
