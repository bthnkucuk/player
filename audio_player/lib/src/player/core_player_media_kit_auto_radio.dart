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
    final playlistState = player.state.playlist;
    final activeIndex = playlistState.index;
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
    List<CorePlayerAudioSource>? appended;
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
  /// appended item. Implemented directly against `media_kit.Player.add` so
  /// it does NOT collide with Faz Q1's public `appendToQueue` work in
  /// progress on a parallel branch — when Q1 lands, this can be replaced
  /// with a call to the public method.
  ///
  /// Holds [queueLock] for the whole operation so a concurrent [setQueue]
  /// does not interleave with the auto-radio append. Native verbs go
  /// through [runOnNative] to serialize against in-flight seek/play/etc.
  Future<void> _appendForAutoRadio(List<CorePlayerAudioSource> sources) {
    return runOnQueue(() async {
      if (_disposed) return;
      if (_sources.isEmpty) return;
      // Pre-compute the next index BEFORE adding so we know where to
      // jump after the native append completes.
      final firstAppendedIndex = _sources.length;
      final merged = <CorePlayerAudioSource>[..._sources, ...sources];
      _sources = List.unmodifiable(merged);
      for (final src in sources) {
        if (_disposed) return;
        final media = _toMedia(src);
        await runOnNative(() => player.add(media));
      }
      if (_disposed) return;
      // Jump to the first appended item. media_kit's playlist subscription
      // will mirror the index back through [_queueStreamBacking].
      await runOnNative(() => player.jump(firstAppendedIndex));
      await runOnNative(() => player.play());
    });
  }
}
