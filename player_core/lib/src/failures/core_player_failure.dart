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

/// Thrown by [CorePlayer.play] when no [CoreAudioSource] has been
/// supplied to the constructor or to [CorePlayer.load].
final class MediaItemNotSetFailure extends CorePlayerFailure {
  const MediaItemNotSetFailure() : super('Media item is not set');
}

/// Thrown by [CorePlayer.load] when the [CoreAudioSource] subtype carries a
/// payload the engine cannot translate into a native [Media] (e.g. an
/// empty path or a transport not yet supported by the active engine).
///
/// Post-Faz-S1 the sealed hierarchy makes the obvious "neither url nor
/// path" state unrepresentable at the type system — this failure now
/// captures the residual runtime malformedness (empty strings, unsupported
/// transports introduced by future subtypes the engine doesn't know yet).
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

/// Thrown by `CorePlayer.restore(...)` (and the queue/source `fromJson`
/// helpers) when the snapshot's `schemaVersion` is not one this build
/// understands. Future agents bumping the schema MUST add an explicit
/// upgrade path or version check before reading the new shape — silently
/// reusing the old reader would mis-interpret renamed/removed fields.
final class SnapshotSchemaMismatchFailure extends CorePlayerFailure {
  const SnapshotSchemaMismatchFailure(super.message, {this.foundVersion, this.expectedVersion});
  final int? foundVersion;
  final int? expectedVersion;
}

/// Thrown by `CorePlayer.restore(...)` when the snapshot is missing a
/// required field (e.g. `items`, `activeIndex`). The schema check passed,
/// but the payload itself is malformed — we don't silently default since
/// that would resurrect a player into a state the user never asked for.
final class SnapshotMalformedFailure extends CorePlayerFailure {
  const SnapshotMalformedFailure(super.message);
}
