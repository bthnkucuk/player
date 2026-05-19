import 'dart:async';

import 'package:meta/meta.dart';
import 'package:player_core/src/player/core_audio_source.dart';
import 'package:rxdart/rxdart.dart';
import 'package:player_core/src/failures/core_player_failure.dart';
import 'package:player_core/src/observer/core_player_observer.dart';
import 'package:player_core/src/player/core_audio_handler.dart';
import 'package:player_core/src/queue/core_player_queue.dart';

/// Factory used by [CorePlayer.create]. Implementations register one via
/// [CorePlayer.registerFactory] during their bootstrap step. See
/// `audio_player/lib/src/player/core_player_media_kit.dart`
/// for the canonical implementation registration.
typedef CorePlayerFactory =
    CorePlayer Function({
      CorePlayerAudioSource? audioSource,
      CoreAudioHandler? audioHandler,
      bool autoLoad,
    });

// `CorePlayerAudioSource` still uses Equatable below (it's a value type — the
// import stays). `CorePlayer` itself does NOT extend Equatable: instance identity
// is the only equality that makes sense (concrete impls hold many mutable
// stream subjects, subscriptions, native player handles).

enum CorePlayerState { error, loading, ready, idle, completed }

/// Loop mode for [CorePlayer].
enum CorePlayerLoopMode {
  /// No loop. When the queue ends, playback stops.
  off,

  /// Loop the current track indefinitely.
  one,

  /// Loop the entire queue. After the last track, wrap to index 0.
  all,
}

abstract class CorePlayer {
  CorePlayerAudioSource? get audioSource;

  /// Stream of the currently-loaded audio source. Emits null when no
  /// source is loaded (initial state, after [setQueue] with an empty
  /// queue, or after [clearQueue]).
  ValueStream<CorePlayerAudioSource?> get audioSourceStream;

  CoreAudioHandler? get audioHandler;
  bool get autoLoad;

  /// Abstract constructor — subclasses define their own concrete constructor
  /// and back the [audioSource], [audioHandler], [autoLoad] getters with
  /// fields of their choosing. Kept parameterless to avoid implying a
  /// contract the base class does not enforce.
  CorePlayer();

  static CorePlayerFactory? _factory;

  /// Registers the factory that [create] will dispatch to. Implementations
  /// call this during their `ensureInitialized()` step.
  ///
  /// Calling this a second time replaces the previously registered factory —
  /// useful in tests for swapping in a mock.
  static void registerFactory(CorePlayerFactory factory) {
    _factory = factory;
  }

  /// Clears the registered factory. For test isolation only.
  @visibleForTesting
  static void debugClearFactory() {
    _factory = null;
  }

  /// Returns true if an implementation has registered a factory.
  static bool get isFactoryRegistered => _factory != null;

  /// Global lifecycle observer. Set once in app bootstrap to receive
  /// per-instance callbacks (analytics / observability). Set null to clear.
  ///
  /// Inspired by `flutter_bloc`'s `BlocObserver` pattern.
  static CorePlayerObserver? observer;

  /// Creates a [CorePlayer] using the registered factory. Throws a
  /// [StateError] if no factory has been registered. Apps must call
  /// the impl's `ensureInitialized()` (e.g. `CorePlayerMediaKit.ensureInitialized()`)
  /// before using this.
  static CorePlayer create({
    CorePlayerAudioSource? audioSource,
    CoreAudioHandler? audioHandler,
    bool autoLoad = false,
  }) {
    final factory = _factory;
    if (factory == null) {
      throw StateError(
        'No CorePlayer implementation registered. Did you forget to call '
        'CorePlayerMediaKit.ensureInitialized() (or your impl\'s equivalent) '
        'before using CorePlayer.create?',
      );
    }
    return factory(
      audioSource: audioSource,
      audioHandler: audioHandler,
      autoLoad: autoLoad,
    );
  }

  ValueStream<CorePlayerState> get playerStateStream;
  ValueStream<Duration> get positionStream;
  ValueStream<Duration> get durationStream;
  ValueStream<Duration> get bufferStream;
  ValueStream<bool> get playingStream;

  CorePlayerState get playerState;
  Duration get position;
  Duration get duration;
  Duration get buffer;
  bool get isPlaying;

  bool get isDisposed;

  Future<void> load(CorePlayerAudioSource audioSource);

  /// Current queue. Defaults to [CorePlayerQueue.empty] until [setQueue] or
  /// [load] is called. After [load], it holds a single-item queue wrapping
  /// the loaded source.
  CorePlayerQueue get queue;

  /// Stream of queue changes. Seeded with the current value.
  ValueStream<CorePlayerQueue> get queueStream;

  /// Replaces the current queue. The track at the queue's `currentIndex`
  /// becomes the active source and is opened. Does NOT auto-play; call
  /// [play] or use [loadAndPlay] to wrap stop+load+play.
  ///
  /// Passing an empty queue resets the active source to null; the next
  /// [play] call will throw [MediaItemNotSetFailure].
  Future<void> setQueue(CorePlayerQueue queue);

  /// Empties the queue and stops playback. Equivalent to
  /// `setQueue(CorePlayerQueue.empty())`.
  Future<void> clearQueue() => setQueue(const CorePlayerQueue.empty());

  /// Advances to the next track. If the queue is at its last index and
  /// [loopMode] is [CorePlayerLoopMode.all], wraps to index 0; otherwise
  /// throws [QueueOutOfBoundsFailure]. Throws on empty queues.
  Future<void> skipToNext();

  /// Goes to the previous track. If at index 0 and [loopMode] is
  /// [CorePlayerLoopMode.all], wraps to the last index; otherwise throws
  /// [QueueOutOfBoundsFailure]. Throws on empty queues.
  Future<void> skipToPrevious();

  /// Jumps to the specified queue index. Throws [QueueOutOfBoundsFailure]
  /// if [index] is out of range. Opens the source but does not auto-play.
  Future<void> skipToIndex(int index);

  Future<void> play({Duration? position});

  /// Single-flight convenience for the common stop → load → play sequence.
  ///
  /// Concurrent invocations are coalesced — a second call while the first is
  /// still in flight returns the same Future, so rapid double-taps on a
  /// play-button no longer race the native player. Once the in-flight call
  /// settles, a subsequent invocation starts fresh.
  ///
  /// Apps should prefer this over hand-rolled `await stop(); await load();
  /// await play();` chains, which are vulnerable to re-entrancy when wired to
  /// gesture handlers.
  Future<void> loadAndPlay(CorePlayerAudioSource audioSource);

  Future<void> pause();

  Future<void> seek(Duration position);

  /// Playback speed multiplier (1.0 = normal). Implementations may not support
  /// arbitrary values; consult the underlying platform docs for valid ranges.
  double get playbackSpeed;

  ValueStream<double> get playbackSpeedStream;

  Future<void> setPlaybackSpeed(double speed);

  /// Current volume in [0.0, 1.0]. Defaults to 1.0.
  double get volume;

  /// Stream of volume changes. Seeded with the current value.
  ValueStream<double> get volumeStream;

  /// Sets the volume. Values are clamped to [0.0, 1.0].
  Future<void> setVolume(double volume);

  /// Current loop mode. Defaults to [CorePlayerLoopMode.off].
  CorePlayerLoopMode get loopMode;

  /// Stream of loop-mode changes. Seeded with the current value.
  ValueStream<CorePlayerLoopMode> get loopModeStream;

  /// Sets the loop mode.
  Future<void> setLoopMode(CorePlayerLoopMode mode);

  /// Whether playback is currently shuffled. Defaults to false.
  bool get shuffle;

  /// Stream of shuffle changes. Seeded with the current value.
  ValueStream<bool> get shuffleStream;

  /// Enables or disables shuffle. When enabled, [skipToNext] and
  /// auto-advance traverse the queue in a randomized order until either
  /// the queue is replaced or shuffle is disabled.
  Future<void> setShuffle(bool enabled);

  /// Stream of failures emitted by this player.
  ///
  /// **Fires on every [CorePlayerFailure]**, regardless of whether the
  /// caller catches it at the call site. Methods like [load], [play],
  /// and [setVolume] still throw on failure — the stream is an
  /// additional notification channel, not a replacement.
  ///
  /// Pick one strategy:
  /// - **Passive observers** (analytics, retry coordinators, global
  ///   toast surfaces): subscribe to this stream and let calls throw
  ///   uncaught; the stream sees everything.
  /// - **Per-call handling**: try/catch around individual operations
  ///   and ignore this stream — failures surface at the call site.
  ///
  /// Doing both will produce duplicate notifications.
  ///
  /// Also fires on async errors surfaced via `player.stream.error`
  /// (e.g. mid-stream network drops) as synthetic [LoadFailure]s.
  Stream<CorePlayerFailure> get errorStream;

  Future<void> stop({bool fromDispose = false});

  Future<void> dispose();

  /// Resolves when the player reaches [CorePlayerState.ready] for the
  /// currently-loaded source. Throws [LoadFailure] (with the current
  /// error message) if the player transitions to [CorePlayerState.error]
  /// before ready.
  ///
  /// If the player is already ready, returns immediately.
  ///
  /// If [timeout] is supplied, completes with a [TimeoutException] if
  /// the state doesn't reach ready within the duration. Default: no
  /// timeout.
  Future<void> waitForReady({Duration? timeout});

  /// Captures enough state to restore the player after a cold-launch.
  ///
  /// The snapshot envelope:
  /// ```
  /// {
  ///   'schemaVersion': 1,
  ///   'queue':       <queue.toJson()>,
  ///   'positionMs':  <player.position.inMilliseconds>,
  ///   'playing':     <player.isPlaying>,  // captured for diagnostics only
  /// }
  /// ```
  ///
  /// [restore] always re-materialises the player in a paused state
  /// regardless of `playing` — auto-resume is a UX call the consumer makes,
  /// and the field is retained purely so a debugger / logs can answer
  /// "was the user listening when we snapshotted?".
  ///
  /// The default implementation reads [queue], [position], and [isPlaying]
  /// via the public surface so any [CorePlayer] subclass works out of the
  /// box. Subclasses with engine-specific scratch can override to capture
  /// more — but anything captured here must be re-applied in [restore].
  Map<String, Object?> snapshot() {
    return <String, Object?>{
      'schemaVersion': 1,
      'queue': queue.toJson(),
      'positionMs': position.inMilliseconds,
      'playing': isPlaying,
    };
  }

  /// Builds a player from a [snapshot] previously produced by [snapshot].
  ///
  /// Wires the new player to [audioHandler] (same construction path as
  /// [CorePlayer.create]) and pre-applies [setQueue] + [seek] before
  /// returning — but does NOT call [play]. Always paused on return; the
  /// consumer decides whether to auto-resume.
  ///
  /// Throws [SnapshotSchemaMismatchFailure] when the top-level
  /// `schemaVersion` is unrecognized, and [SnapshotMalformedFailure] when
  /// required fields (`queue`, `positionMs`) are missing.
  static Future<CorePlayer> restore(
    Map<String, Object?> snapshot, {
    CoreAudioHandler? audioHandler,
  }) async {
    final version = snapshot['schemaVersion'];
    if (version != 1) {
      throw SnapshotSchemaMismatchFailure(
        'Unrecognized player snapshot schemaVersion: $version (expected 1)',
        foundVersion: version is int ? version : null,
        expectedVersion: 1,
      );
    }
    final rawQueue = snapshot['queue'];
    if (rawQueue is! Map) {
      throw const SnapshotMalformedFailure('Player snapshot missing "queue"');
    }
    final positionMs = snapshot['positionMs'];
    if (positionMs is! int) {
      throw const SnapshotMalformedFailure(
        'Player snapshot missing "positionMs" int',
      );
    }
    final queue = CorePlayerQueue.fromJson(rawQueue.cast<String, Object?>());
    final player = CorePlayer.create(audioHandler: audioHandler);
    // Order matters: setQueue first (opens native handle for the active
    // source), then seek the playhead. Skip the seek on empty queues —
    // there's nothing to position. Leave paused; consumer calls play().
    if (queue.isNotEmpty) {
      await player.setQueue(queue);
      final position = Duration(milliseconds: positionMs);
      if (position > Duration.zero) {
        await player.seek(position);
      }
    }
    return player;
  }
}
