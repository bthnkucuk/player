part of 'core_player_media_kit.dart';

/// Auto-radio / queue-exhaustion logic for [CorePlayerMediaKit].
///
/// Extracted into its own part file so [CorePlayerMediaKit] stays under the
/// 1100-line readability budget. The detector is wired in the main
/// constructor (subscription to `player.stream.completed`); this file owns
/// the dispatch policy + the internal "append to running queue" path used
/// by the auto-radio recommendation flow.
///
/// Append intentionally bypasses any public queue-mutation method. Faz Q1
/// (parallel branch) will introduce `appendToQueue` on [CorePlayer]; once
/// merged, [_appendForAutoRadio] should be re-pointed at the public method
/// so the two code paths share a single implementation. Until then this
/// file talks directly to `media_kit.Player.add` / `.jump` under the
/// concurrency-mixin locks to avoid colliding with Q1's work.
extension _CorePlayerMediaKitAutoRadio on CorePlayerMediaKit {
  /// Detects and dispatches a "queue exhausted" event. Called on every
  /// `player.stream.completed == true` emission.
  ///
  /// Fires the configured [CorePlayerConfiguration.onQueueExhausted]
  /// callback iff:
  ///  - the wrapper currently owns a non-empty queue, AND
  ///  - the last item just completed (`playlist.index == length - 1`).
  ///
  /// The re-entrancy guard ([_queueExhaustedHandled]) absorbs duplicate
  /// `completed=true` ticks for the same end-of-stream so the callback is
  /// invoked exactly once per natural exhaustion. The guard resets when
  /// [setQueue] replaces the queue or after a successful append.
  void _maybeFireQueueExhausted() {
    if (_disposed) return;
    if (_queueExhaustedHandled) return;
    if (_sources.isEmpty) return;
    // Loop modes auto-advance / wrap at the media_kit layer, so we'd
    // never see a "real" end-of-queue when looping. Defensive guard.
    if (loopMode != CorePlayerLoopMode.off) return;
    // Source of truth for the active index is the wrapper-projected
    // [_queueStreamBacking], kept in sync via the playlist subscription.
    // Reading from `player.state.playlist` here would re-cross the FFI
    // and (in tests) break callers that mock streams but not state.
    final activeIndex = _queueStreamBacking.hasValue
        ? _queueStreamBacking.value.currentIndex
        : -1;
    if (activeIndex != _sources.length - 1) return;

    _queueExhaustedHandled = true;

    final cb = CorePlayerMediaKit._configuration.onQueueExhausted;
    if (cb == null) return;

    _trackPending(_runQueueExhausted(cb));
  }

  /// Async body of the queue-exhaustion dispatch. Kept separate so the
  /// `completed` listener stays non-async — broadcast listener callbacks
  /// can swallow uncaught errors silently.
  Future<void> _runQueueExhausted(CorePlayerOnQueueExhausted cb) async {
    List<CoreAudioSource>? appended;
    try {
      appended = await cb();
    } on Object catch (e, s) {
      CorePlayerMediaKit.log(
        'onQueueExhausted callback threw',
        error: e,
        stackTrace: s,
      );
      return;
    }
    if (_disposed) return;
    if (appended == null || appended.isEmpty) return;
    await _appendForAutoRadio(appended);
  }

  /// Append [sources] to the active queue and advance to the first
  /// appended item. Delegates the per-source `player.add` + wrapper-side
  /// `_sources.add` to the Faz Q1 queue-mutation helper [_appendAllLocked]
  /// so both paths share a single growable-list invariant — the auto-radio
  /// flow must never reassign `_sources` to an unmodifiable list (would
  /// brick all later [appendToQueue]/[insertNext]/[removeAt] calls).
  ///
  /// Holds [queueLock] for the whole operation so a concurrent [setQueue]
  /// does not interleave with the auto-radio append, and the post-append
  /// `jump` + `play` happen against the freshly-extended queue.
  Future<void> _appendForAutoRadio(List<CoreAudioSource> sources) {
    return runOnQueue(() async {
      if (_disposed) return;
      if (_sources.isEmpty) return;
      // Snapshot the pre-append length so we know where to jump once
      // [_appendAllLocked] has grown the queue.
      final firstAppendedIndex = _sources.length;
      await _appendAllLocked(sources);
      if (_disposed) return;
      await runOnNative(() => player.jump(firstAppendedIndex));
      await runOnNative(() => player.play());
    });
  }
}
