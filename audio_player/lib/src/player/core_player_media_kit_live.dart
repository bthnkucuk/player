part of 'core_player_media_kit.dart';

/// Live-source plumbing for [CorePlayerMediaKit]. A [LiveAudioSource] sits
/// in the queue like any other source but its content (the playable URLs)
/// arrives asynchronously over `LiveAudioSource.segmentUrlStream`. The
/// wrapper subscribes to the stream and appends each emitted URL to the
/// active playlist as a sibling [HttpAudioSource]-shaped entry. media_kit's
/// native [Playlist] primitive provides gapless transitions across the
/// appended segments — the same machinery that powers next/previous.
///
/// Design contract:
/// - One subscription per live source instance; tracked in
///   [_liveSubscriptions] so [dispose] drains them before the native
///   player goes away.
/// - On each emission, the wrapper appends an [HttpAudioSource] to
///   [_sources] AND issues `player.add(Media(...))` under `runOnNative`.
///   The wrapper-side mirror is updated synchronously BEFORE the native
///   call so the [Player.stream.playlist] listener observes a consistent
///   length when media_kit broadcasts the addition.
/// - On stream `done`, the subscription is removed from [_liveSubscriptions]
///   and the live source becomes "exhausted" — no more appends. The normal
///   queue-exhaustion lifecycle (driven by `player.stream.completed`) then
///   takes over once the last appended segment finishes.
/// - On stream error: log via [CorePlayerMediaKit.log], emit a [LoadFailure]
///   on [errorStream], keep previously-appended segments playable.
/// - [setQueue]ing past a live source cancels its subscription. [dispose]
///   cancels all remaining subscriptions.
///
/// The wrapper exposes each appended segment as an [HttpAudioSource] entry
/// in `queueStream` (rather than hiding them behind the parent
/// [LiveAudioSource]) so consumers' queue UI shows the granular state —
/// users can see "currently at segment 3 of 5 emitted so far" and skip
/// between segments the same way as any other queue.
mixin CorePlayerMediaKitLive on CorePlayer, CorePlayerMediaKitConcurrency {
  // Host-class seams. [CorePlayerMediaKit] satisfies these via its real
  // fields/methods at mix-in time.
  Player get player;
  bool get _disposed;
  List<CoreAudioSource> get _sources;
  StreamController<CorePlayerFailure> get _errorController;
  CoreAudioHandler? get currentAudioHandler;
  Media _toMedia(CoreAudioSource src);
  void _trackPending(Future<void> op);

  /// One [StreamSubscription] per attached [LiveAudioSource]. Identity-keyed
  /// (the same source instance is not double-attached because the spec
  /// pins the stream as single-subscription).
  final Map<LiveAudioSource, StreamSubscription<Uri>> _liveSubscriptions = {};

  /// Attach a live source: subscribe to its segment stream and append
  /// each emitted URL as an [HttpAudioSource] sibling in the queue. Safe
  /// to call multiple times for the same source — re-attach is a no-op.
  ///
  /// Called from [CorePlayerMediaKit._setQueueLocked] after the native
  /// [Player.open] resolves, so by the time emissions land the playlist
  /// is live and `player.add(Media(...))` slots them in without a re-open.
  void _attachLiveSegmentStream(LiveAudioSource source) {
    if (_disposed) return;
    if (_liveSubscriptions.containsKey(source)) return;

    final sub = source.segmentUrlStream.listen(
      (uri) => _onLiveSegmentEmit(source, uri),
      onError: (Object e, StackTrace s) {
        if (_disposed) return;
        CorePlayerMediaKit.log(
          'LiveAudioSource segment stream error',
          error: e,
          stackTrace: s,
        );
        if (!_errorController.isClosed) {
          _errorController.add(
            LoadFailure('Live segment stream error: $e', cause: e),
          );
        }
        // Previously appended segments remain in the playlist and playable;
        // we deliberately do NOT tear down the live source on a single
        // error — the upstream may recover.
      },
      onDone: () {
        if (_disposed) return;
        _liveSubscriptions.remove(source);
      },
      cancelOnError: false,
    );
    _liveSubscriptions[source] = sub;
  }

  /// Append [uri] (emitted by [source]'s segment stream) to the wrapper's
  /// queue + the native playlist. The wrapper-side append (`_sources.add`)
  /// runs BEFORE the native call so media_kit's synchronous
  /// `playlistController.add(...)` inside `player.add()` lands on an
  /// already-aligned `_sources.length`.
  void _onLiveSegmentEmit(LiveAudioSource source, Uri uri) {
    if (_disposed) return;
    // Each emitted segment becomes a sibling HttpAudioSource entry.
    // Title carries the parent live-source title + a segment counter
    // (computed from the segment's position in `_sources`) so the
    // queue UI shows a stable progression rather than a single "Live"
    // row that mutates duration.
    final segment = HttpAudioSource(
      url: uri,
      title: _segmentTitle(source),
      artist: source.artist,
      artUri: source.artUri,
      headers: source.headers,
    );
    final media = _toMedia(segment);
    _sources.add(segment);
    _trackPending(
      runOnNative(() => player.add(media)).catchError((Object e, StackTrace s) {
        if (_disposed) return;
        CorePlayerMediaKit.log(
          'LiveAudioSource player.add failed',
          error: e,
          stackTrace: s,
        );
        if (!_errorController.isClosed) {
          _errorController.add(
            LoadFailure('Live segment append failed: $e', cause: e),
          );
        }
      }),
    );
  }

  String _segmentTitle(LiveAudioSource source) {
    // 1-based counter for end-user display. The wrapper has no way to know
    // the parent's planned segment count (the stream length is unknown
    // until `done`), so we count appends as they happen.
    final liveAppendIndex = _liveAppendCount(source) + 1;
    return '${source.title} (segment $liveAppendIndex)';
  }

  /// Counts entries already appended on behalf of [source]. Conservative:
  /// any HttpAudioSource whose title starts with `${source.title} (segment `
  /// is treated as a sibling append. Correct for the v1 model where one
  /// live source feeds one playlist; multi-live queues still produce
  /// monotonically-increasing counters per parent.
  int _liveAppendCount(LiveAudioSource source) {
    var n = 0;
    final prefix = '${source.title} (segment ';
    for (final s in _sources) {
      if (s is HttpAudioSource && s.title.startsWith(prefix)) n++;
    }
    return n;
  }

  /// Cancel any live subscriptions whose source is not present in
  /// [retained]. Called from [_setQueueLocked] when a new queue replaces
  /// the prior live source(s).
  Future<void> _cancelLiveSubscriptionsNotIn(
    Iterable<CoreAudioSource> retained,
  ) async {
    if (_liveSubscriptions.isEmpty) return;
    final keep = retained.whereType<LiveAudioSource>().toSet();
    final toDrop = _liveSubscriptions.keys
        .where((s) => !keep.contains(s))
        .toList(growable: false);
    for (final source in toDrop) {
      final sub = _liveSubscriptions.remove(source);
      await sub?.cancel();
    }
  }

  /// Cancel ALL live subscriptions. Called from [dispose] before the
  /// native player teardown, so a late emission cannot land against a
  /// disposed player.
  Future<void> _cancelAllLiveSubscriptions() async {
    if (_liveSubscriptions.isEmpty) return;
    final subs = List<StreamSubscription<Uri>>.from(_liveSubscriptions.values);
    _liveSubscriptions.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }

  /// Number of attached live subscriptions — exposed for tests so they can
  /// assert the cleanup invariants without reaching into private state.
  @visibleForTesting
  int get debugLiveSubscriptionCount => _liveSubscriptions.length;
}
