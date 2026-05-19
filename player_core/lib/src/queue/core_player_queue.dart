import 'package:player_core/src/failures/core_player_failure.dart';
import 'package:player_core/src/player/core_audio_source.dart';

/// Top-level schema version emitted on queue / snapshot JSON. Bump when the
/// envelope (or any nested shape) changes in a non-additive way. Faz Q
/// ships v1; Faz S will bump to v2 when sealed audio-source subtypes land
/// (e.g. live / HLS sources with their own discriminator extensions).
const int kCorePlayerQueueSchemaVersion = 1;

/// Map key used for the schema version both on queue JSON and on the
/// player snapshot envelope.
const String kCorePlayerSchemaVersionKey = 'schemaVersion';

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

  /// Serialises this queue to JSON. The envelope carries the schema version
  /// so [fromJson] can reject mismatched payloads without first having to
  /// parse the items array.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      kCorePlayerSchemaVersionKey: kCorePlayerQueueSchemaVersion,
      'items': [for (final s in sources) s.toJson()],
      'activeIndex': currentIndex,
    };
  }

  /// Rehydrates a queue previously produced by [toJson]. Throws
  /// [SnapshotSchemaMismatchFailure] when the envelope version is
  /// unrecognized, and [SnapshotMalformedFailure] when required fields are
  /// missing (no silent defaulting — see `CorePlayer.restore` rationale).
  static CorePlayerQueue fromJson(Map<String, Object?> json) {
    final version = json[kCorePlayerSchemaVersionKey];
    if (version != kCorePlayerQueueSchemaVersion) {
      throw SnapshotSchemaMismatchFailure(
        'Unrecognized queue schemaVersion: $version (expected '
        '$kCorePlayerQueueSchemaVersion)',
        foundVersion: version is int ? version : null,
        expectedVersion: kCorePlayerQueueSchemaVersion,
      );
    }
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const SnapshotMalformedFailure('Queue JSON missing "items" array');
    }
    final rawIndex = json['activeIndex'];
    if (rawIndex is! int) {
      throw const SnapshotMalformedFailure('Queue JSON missing "activeIndex" int');
    }
    final items = <CorePlayerAudioSource>[
      for (final raw in rawItems)
        if (raw is Map)
          CorePlayerAudioSource.fromJson(raw.cast<String, Object?>())
        else
          throw const SnapshotMalformedFailure('Queue item is not a Map'),
    ];
    // Clamp activeIndex into range for non-empty queues; empty queues
    // accept any index value (the cursor is meaningless then).
    final clamped = items.isEmpty ? 0 : rawIndex.clamp(0, items.length - 1);
    return CorePlayerQueue(items, currentIndex: clamped);
  }
}
