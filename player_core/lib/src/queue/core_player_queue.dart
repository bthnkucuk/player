import 'package:player_core/src/player/core_audio_source.dart';

/// Immutable ordered collection of [CorePlayerAudioSource]s with a
/// "current" index. Acts as the unit of work for [CorePlayer.setQueue].
///
/// Zero-cost extension type over a `(List, int)` record for ergonomic
/// iteration; pair with the [currentIndex] field for cursor semantics.
///
/// Records compare structurally, so two queues with the same source list
/// and same current index are `==`. The backing list is wrapped — callers
/// passing a mutable list and mutating it after construction will observe
/// changes through this view; treat instances as immutable.
extension type const CorePlayerQueue._(
  (List<CorePlayerAudioSource> sources, int currentIndex) _
)
    implements Object {
  /// Constructs a queue from [sources] with the active cursor at [currentIndex].
  const CorePlayerQueue(
    List<CorePlayerAudioSource> sources, {
    int currentIndex = 0,
  }) : this._((sources, currentIndex));

  /// Single-item queue at index 0. Convenience for callers wrapping a
  /// single source — used by [CorePlayer.load] to preserve the legacy
  /// single-track contract.
  CorePlayerQueue.single(CorePlayerAudioSource source) : this._(([source], 0));

  /// Empty queue. Useful as an initial state placeholder.
  const CorePlayerQueue.empty() : this._((const <CorePlayerAudioSource>[], 0));

  /// The backing source list. Treat as immutable.
  List<CorePlayerAudioSource> get sources => _.$1;

  /// Index of the active source. Always in `[0, length)` for non-empty
  /// queues; for an empty queue it is `0` (placeholder) and [current] is
  /// `null`.
  int get currentIndex => _.$2;

  /// Number of sources in the queue.
  int get length => sources.length;

  /// True when the queue carries no sources.
  bool get isEmpty => sources.isEmpty;

  /// True when the queue has at least one source.
  bool get isNotEmpty => sources.isNotEmpty;

  /// The source at [currentIndex], or `null` when the queue is empty.
  CorePlayerAudioSource? get current => isEmpty ? null : sources[currentIndex];

  /// Indexed read into [sources]. Throws if [index] is out of range.
  CorePlayerAudioSource operator [](int index) => sources[index];

  /// Returns a new queue with the same [sources] and the cursor moved to
  /// [newIndex]. Asserts in debug that [newIndex] is in range.
  CorePlayerQueue withIndex(int newIndex) {
    assert(
      newIndex >= 0 && newIndex < length,
      'Index $newIndex out of bounds [0, $length)',
    );
    return CorePlayerQueue(sources, currentIndex: newIndex);
  }
}
