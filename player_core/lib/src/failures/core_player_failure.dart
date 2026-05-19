/// Sealed hierarchy of failures thrown by [CorePlayer] implementations.
///
/// Consumers can catch the supertype or pattern-match on specific subtypes:
/// ```dart
/// try { await player.play(); }
/// on CorePlayerFailure catch (e) { ... }
/// ```
///
/// To surface as a localized UI toast, wrap in your app's `LocalizedFailure`
/// adapter. The abstraction stays UI-agnostic.
sealed class CorePlayerFailure implements Exception {
  const CorePlayerFailure(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when any operation is invoked after [CorePlayer.dispose].
final class PlayerDisposedFailure extends CorePlayerFailure {
  const PlayerDisposedFailure() : super('Player disposed');
}

/// Thrown by [CorePlayer.play] when no [CorePlayerAudioSource] has been
/// supplied to the constructor or to [CorePlayer.load].
final class MediaItemNotSetFailure extends CorePlayerFailure {
  const MediaItemNotSetFailure() : super('Media item is not set');
}

/// Thrown by [CorePlayer.load] when the [CorePlayerAudioSource] is malformed
/// (no url and no filePath).
final class InvalidMediaSourceFailure extends CorePlayerFailure {
  const InvalidMediaSourceFailure() : super('Media item is invalid');
}

/// Thrown by [CorePlayer.load] when the underlying impl couldn't open the
/// media (network error, missing file, codec mismatch, etc.). The
/// [cause] is the raw exception from the impl, kept for logging.
final class LoadFailure extends CorePlayerFailure {
  const LoadFailure(super.message, {this.cause});
  final Object? cause;
}

/// Thrown by [CorePlayer.setPlaybackSpeed] when the impl rejects the rate.
final class PlaybackSpeedFailure extends CorePlayerFailure {
  const PlaybackSpeedFailure(super.message, {this.cause});
  final Object? cause;
}

/// Thrown by [CorePlayer.play] when the underlying impl can't begin playback
/// (e.g. session attach failed, native player rejected start). The [cause]
/// is the raw exception from the impl, kept for logging.
final class PlayFailure extends CorePlayerFailure {
  const PlayFailure(super.message, {this.cause});
  final Object? cause;
}

/// Thrown by [CorePlayer.skipToNext], [CorePlayer.skipToPrevious], or
/// [CorePlayer.skipToIndex] when the requested target is out of range
/// (and, for skipToNext/Previous, the queue is not configured to wrap
/// around via [CorePlayerLoopMode.all]).
final class QueueOutOfBoundsFailure extends CorePlayerFailure {
  const QueueOutOfBoundsFailure(super.message);
}
