import 'dart:async';

import 'package:synchronized/synchronized.dart';

/// Concurrency-hardening primitives for [CorePlayerMediaKit].
///
/// Locking contract — read before adding a new native verb call:
///
///   * `nativeLock` serializes every direct mutation of the underlying
///     `media_kit.Player` (`open`, `play`, `pause`, `stop`, `seek`,
///     `setVolume`, `setRate`, `setPlaylistMode`, `setShuffle`, `jump`,
///     `next`, `previous`, `dispose`). Interleaving these at the libmpv
///     layer produced undefined state in production (Faz H bug #2). The
///     lock is non-reentrant: never call into another `nativeLock`-guarded
///     method while holding it.
///
///   * `queueLock` serializes the bodies of `setQueue` and `loadAndPlay`.
///     The 25 s timeout matches the production-validated value used in the
///     source codebase — a `_openWithRetry` that hangs longer than that is
///     pathological and we'd rather surface a `TimeoutException` than
///     freeze the queue subsystem.
///
///   * `nextSetQueueToken()` is bumped at the entry of every `setQueue` /
///     `loadAndPlay` call. After each `await` boundary in those flows the
///     caller compares its captured token against
///     [latestSetQueueToken]; a mismatch means a newer caller has
///     superseded this one, and the stale completion silently bails out
///     before writing back to subjects. This is the Faz H bug #1 fix.
///
/// Never acquire either lock from inside a `media_kit` stream-subscriber
/// callback (e.g. `player.stream.playing.listen(...)`). Event-driven
/// mutations from the `audioHandler` event stream go through
/// `unawaited(...)` already, so they don't block the listener and they
/// queue behind the active native operation.
mixin CorePlayerMediaKitConcurrency {
  static const Duration queueLockTimeout = Duration(seconds: 25);

  final Lock _nativeLock = Lock();
  final Lock _queueLock = Lock();

  int _setQueueGeneration = 0;

  Lock get nativeLock => _nativeLock;
  Lock get queueLock => _queueLock;

  int get latestSetQueueToken => _setQueueGeneration;

  int nextSetQueueToken() => ++_setQueueGeneration;

  /// Runs [action] under [nativeLock]. Use for every direct call to a
  /// `media_kit.Player` mutating verb.
  Future<T> runOnNative<T>(Future<T> Function() action) {
    return _nativeLock.synchronized<T>(action);
  }

  /// Runs [action] under [queueLock] with a fixed [queueLockTimeout].
  /// Throws [TimeoutException] when a prior queue operation hangs beyond
  /// the timeout window — see locking contract above.
  Future<T> runOnQueue<T>(Future<T> Function() action) {
    return _queueLock.synchronized<T>(action, timeout: queueLockTimeout);
  }
}
