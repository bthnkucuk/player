import 'package:equatable/equatable.dart';
import 'package:player_core/src/player/core_audio_source.dart';

/// Typed playback events. Subscribe via `CorePlayer.playbackEventStream`.
///
/// Designed for analytics consumers (royalty reporting, listen-time
/// dashboards) — provides distinct types for "ended naturally" vs "skipped"
/// vs "stopped by user" that aren't derivable from raw position/playing
/// streams alone.
sealed class CorePlaybackEvent extends Equatable {
  const CorePlaybackEvent({required this.source, required this.timestamp});

  /// The source at the time of the event. Null only for events that fire
  /// when no source is active (rare; document per event).
  final CoreAudioSource? source;

  /// Wall-clock time of the event.
  final DateTime timestamp;
}

/// Fired when a source transitions into the playing state. May fire after
/// a pause/resume on the same source (consumer-side deduplication if you
/// only care about "first play").
final class PlaybackStartedEvent extends CorePlaybackEvent {
  const PlaybackStartedEvent({required super.source, required super.timestamp});

  @override
  List<Object?> get props => [source, timestamp];
}

/// Fired when the active source finishes naturally (engine reports
/// `completed=true`). Distinct from [PlaybackEndedBySkipEvent] which is
/// user-driven.
final class PlaybackEndedByCompletionEvent extends CorePlaybackEvent {
  const PlaybackEndedByCompletionEvent({
    required super.source,
    required super.timestamp,
  });

  @override
  List<Object?> get props => [source, timestamp];
}

/// Fired when the user manually advances (skipToNext / skipToPrevious /
/// skipToIndex) before the current source finished naturally. The
/// [skippedFromPosition] is the position at the moment of the skip — useful
/// for "how far in did the user lose interest" analytics.
final class PlaybackEndedBySkipEvent extends CorePlaybackEvent {
  const PlaybackEndedBySkipEvent({
    required super.source,
    required super.timestamp,
    required this.skippedFromPosition,
  });

  final Duration skippedFromPosition;

  @override
  List<Object?> get props => [source, timestamp, skippedFromPosition];
}

/// Fired when [CorePlayer.stop] is called or the player otherwise enters
/// the stopped state without a natural-completion or skip.
final class PlaybackEndedByStopEvent extends CorePlaybackEvent {
  const PlaybackEndedByStopEvent({
    required super.source,
    required super.timestamp,
  });

  @override
  List<Object?> get props => [source, timestamp];
}

/// Fired when [CorePlayer.seek] is invoked. Carries both endpoints so an
/// analytics consumer can compute the seek delta + direction.
final class PlaybackSeekEvent extends CorePlaybackEvent {
  const PlaybackSeekEvent({
    required super.source,
    required super.timestamp,
    required this.fromPosition,
    required this.toPosition,
  });

  final Duration fromPosition;
  final Duration toPosition;

  @override
  List<Object?> get props => [source, timestamp, fromPosition, toPosition];
}

/// Fired when the engine begins a stall (buffering after playback was
/// already underway — NOT the initial load buffering, which is part of
/// PlaybackStarted's lead-up).
final class PlaybackStallStartedEvent extends CorePlaybackEvent {
  const PlaybackStallStartedEvent({
    required super.source,
    required super.timestamp,
  });

  @override
  List<Object?> get props => [source, timestamp];
}

/// Fired when a stall ends (buffer refilled, playback resumed).
/// [stallDuration] is the wall-clock duration of the stall.
final class PlaybackStallEndedEvent extends CorePlaybackEvent {
  const PlaybackStallEndedEvent({
    required super.source,
    required super.timestamp,
    required this.stallDuration,
  });

  final Duration stallDuration;

  @override
  List<Object?> get props => [source, timestamp, stallDuration];
}

/// Periodic "still playing" event. Configured via
/// [CorePlayerConfiguration.heartbeatInterval] — null disables emission.
/// Default null (opt-in to avoid analytics-pipeline cost for apps that
/// don't need royalty heartbeats).
final class PlaybackHeartbeatEvent extends CorePlaybackEvent {
  const PlaybackHeartbeatEvent({
    required super.source,
    required super.timestamp,
    required this.elapsedSinceStart,
  });

  /// Time since the current source started playing — the accumulator a
  /// royalty backend wants.
  final Duration elapsedSinceStart;

  @override
  List<Object?> get props => [source, timestamp, elapsedSinceStart];
}
