import 'package:player_core/player_core.dart';

/// Platform bridge interface. Implemented by platform packages (e.g.
/// `audio_player`) to wire [CoreAudioHandler] into `audio_service` /
/// `audio_session` without leaking those types into the abstraction.
///
/// The bridge owns:
///   - `BaseAudioHandler` registration with `AudioService.init`.
///   - The `AudioSession` configuration + `setActive(true/false)` lifecycle.
///   - Notification / lock-screen `PlaybackState` and `MediaItem` streams
///     (passed through opaquely from the impl via [emitPlaybackState] /
///     [emitMediaItem]).
///
/// All platform-typed values (`PlaybackState`, `MediaItem`) cross the boundary
/// as `Object` / `Object?` so the abstraction does not import `audio_service`.
abstract class CoreAudioServiceBridge {
  /// Install the bridge: register with `AudioService.init`, configure the
  /// `AudioSession`. Called from [CoreAudioHandler.initialize].
  Future<void> initialize(CoreAudioHandler handler);

  /// Activate the audio session (interrupt other audio apps).
  Future<void> activateSession();

  /// Deactivate the audio session (let other audio apps resume).
  Future<void> deactivateSession();

  /// Push a new `PlaybackState` (opaque) onto the bridge's notification stream.
  void emitPlaybackState(Object state);

  /// Push a new `MediaItem` (opaque, nullable) onto the bridge's notification
  /// stream.
  void emitMediaItem(Object? item);

  /// Reset the bridge's PlaybackState + MediaItem to "stopped/empty". Called
  /// from [CoreAudioHandler.onTaskRemoved] and impls' stop-paths.
  void emitStopState();

  /// Current MediaItem (opaque) — needed by impls that mutate it (e.g. to
  /// patch in a duration discovered after `load`).
  Object? get currentMediaItem;

  /// Optional hook fired when the active [CoreAudioHandler] scope changes via
  /// [CoreAudioHandler.requestSystemAudioFocus] / [CoreAudioHandler.releaseSystemAudioFocus].
  /// Default impl is a no-op; bridges that want to re-emit the new active
  /// scope's MediaItem to the lock-screen should override.
  void refreshMediaItemForActiveScope() {}
}
