part of 'core_player_media_kit.dart';

/// Typed playback-event emission for [CorePlayerMediaKit].
///
/// Owns the broadcast controller behind [CorePlayer.playbackEventStream]
/// and the bookkeeping that turns engine-level signals (playing,
/// completed, buffering) into the higher-level [CorePlaybackEvent] taxonomy
/// analytics consumers want. Kept in its own part file so the main file
/// stays focused on the queue / playback contract.
///
/// Lifecycle wiring:
///   * `_initPlaybackEvents()` is called from the main constructor AFTER
///     the engine-stream subscriptions are installed. It attaches the
///     three derived subscriptions (playing → started, completed →
///     completion, buffering → stall) and seeds the heartbeat timer state.
///   * Skip / stop / seek emissions live in their respective methods
///     ([CorePlayerMediaKitNavigation], [CorePlayerMediaKitPlayback]) so
///     the captured `position` is the one observed *at the call site*,
///     before the native verb lands.
///   * `_disposePlaybackEvents()` is called from [dispose] before the
///     local subjects close, so a late engine emission can no longer
///     synthesize an event into a torn-down controller.
mixin CorePlayerMediaKitEvents on CorePlayer {
  // Host-class members accessed from this mixin. [CorePlayerMediaKit]
  // satisfies these via its real fields/methods at mix-in time.
  Player get player;
  bool get _disposed;
  CoreAudioSource? get _audioSource;
  StreamController<CorePlaybackEvent> get _playbackEventController;

  // Mutable per-instance event-pipeline state. Declared as abstract
  // getter/setter pairs so the concrete host class owns the storage.
  StreamSubscription<bool>? get _eventsPlayingSub;
  set _eventsPlayingSub(StreamSubscription<bool>? v);
  StreamSubscription<bool>? get _eventsCompletedSub;
  set _eventsCompletedSub(StreamSubscription<bool>? v);
  StreamSubscription<bool>? get _eventsBufferingSub;
  set _eventsBufferingSub(StreamSubscription<bool>? v);
  Timer? get _eventsHeartbeatTimer;
  set _eventsHeartbeatTimer(Timer? v);
  bool get _eventsLastPlaying;
  set _eventsLastPlaying(bool v);
  DateTime? get _eventsStartTimestamp;
  set _eventsStartTimestamp(DateTime? v);
  DateTime? get _eventsStallStartedAt;
  set _eventsStallStartedAt(DateTime? v);

  @override
  Stream<CorePlaybackEvent> get playbackEventStream =>
      _playbackEventController.stream;

  /// Attach the derived subscriptions that turn raw engine signals into
  /// typed playback events. Called from the host constructor AFTER the
  /// other engine subscriptions are installed.
  void _initPlaybackEvents() {
    // Started: emit on every false→true playing transition while a source
    // is loaded. We also start the heartbeat timer here. Pause/resume on
    // the same source is allowed to re-emit started — consumers that only
    // care about "first play" dedupe on their side.
    _eventsPlayingSub = player.stream.playing.listen((playing) {
      if (_disposed) return;
      if (playing) {
        if (!_eventsLastPlaying) {
          _eventsLastPlaying = true;
          final src = _audioSource;
          if (src != null) {
            final ts = DateTime.now();
            _eventsStartTimestamp = ts;
            _emitPlaybackEvent(
              PlaybackStartedEvent(source: src, timestamp: ts),
            );
            _startHeartbeatTimer();
          }
        }
      } else {
        if (_eventsLastPlaying) {
          _eventsLastPlaying = false;
          _stopHeartbeatTimer();
        }
      }
    });

    // EndedByCompletion: media_kit's completed fires on every track end.
    // We capture the source identity from `_audioSource` synchronously
    // here — the playlist subscription that swaps `_audioSource` to the
    // next track runs on a separate event-loop step, so reading the
    // pre-advance source is reliable.
    _eventsCompletedSub = player.stream.completed.listen((completed) {
      if (_disposed) return;
      if (!completed) return;
      final src = _audioSource;
      if (src == null) return;
      _emitPlaybackEvent(
        PlaybackEndedByCompletionEvent(
          source: src,
          timestamp: DateTime.now(),
        ),
      );
    });

    // Stall: a mid-playback `buffering == true` is the engine telling us
    // playback has paused for re-buffer. The initial-load buffering window
    // also surfaces here as `true`, but is excluded by gating on
    // `_eventsLastPlaying` — started has not yet fired during initial load.
    _eventsBufferingSub = player.stream.buffering.listen((buffering) {
      if (_disposed) return;
      if (buffering) {
        if (!_eventsLastPlaying) return;
        if (_eventsStallStartedAt != null) return;
        final now = DateTime.now();
        _eventsStallStartedAt = now;
        _emitPlaybackEvent(
          PlaybackStallStartedEvent(source: _audioSource, timestamp: now),
        );
      } else {
        final startedAt = _eventsStallStartedAt;
        if (startedAt == null) return;
        _eventsStallStartedAt = null;
        final now = DateTime.now();
        _emitPlaybackEvent(
          PlaybackStallEndedEvent(
            source: _audioSource,
            timestamp: now,
            stallDuration: now.difference(startedAt),
          ),
        );
      }
    });
  }

  /// Pushes [event] onto the broadcast controller if it has not yet been
  /// closed. Best-effort: a late emission during dispose is dropped rather
  /// than producing an `add after close` zone error.
  void _emitPlaybackEvent(CorePlaybackEvent event) {
    if (_playbackEventController.isClosed) return;
    _playbackEventController.add(event);
  }

  /// Captures the playhead, then emits a [PlaybackEndedBySkipEvent] for
  /// the current source. Called from the three skip entry points
  /// ([skipToNext], [skipToPrevious], [skipToIndex]) — they pass us the
  /// pre-skip position so the value reflects the call site, not whatever
  /// the position stream has settled on after the native jump.
  ///
  /// Looks unused to the analyzer because the call sites live in sibling
  /// mixins ([CorePlayerMediaKitNavigation]) that declare this as an
  /// abstract seam; runtime dispatch via the host class's linearized
  /// mixin chain routes the call here.
  // ignore: unused_element
  void _emitSkipEvent(Duration skippedFromPosition) {
    final src = _audioSource;
    if (src == null) return;
    _emitPlaybackEvent(
      PlaybackEndedBySkipEvent(
        source: src,
        timestamp: DateTime.now(),
        skippedFromPosition: skippedFromPosition,
      ),
    );
  }

  /// Emits a [PlaybackEndedByStopEvent] for the current source. Called
  /// from [stop] when invoked by the consumer (the dispose-driven path
  /// skips the emission so dispose doesn't double-fire stop + the natural
  /// teardown).
  ///
  /// See [_emitSkipEvent] for the cross-mixin-dispatch note that
  /// explains the analyzer's `unused_element` false positive.
  // ignore: unused_element
  void _emitStopEvent() {
    final src = _audioSource;
    _emitPlaybackEvent(
      PlaybackEndedByStopEvent(source: src, timestamp: DateTime.now()),
    );
    // A stop terminates the active playing window; clear the heartbeat
    // anchor so a subsequent play() starts the elapsed counter fresh.
    _eventsStartTimestamp = null;
    _stopHeartbeatTimer();
  }

  /// Emits a [PlaybackSeekEvent] capturing the seek's from + to endpoints.
  /// [fromPosition] is captured at the call site (before the native seek
  /// lands), [toPosition] is the requested target.
  ///
  /// See [_emitSkipEvent] for the cross-mixin-dispatch note.
  // ignore: unused_element
  void _emitSeekEvent({
    required Duration fromPosition,
    required Duration toPosition,
  }) {
    final src = _audioSource;
    _emitPlaybackEvent(
      PlaybackSeekEvent(
        source: src,
        timestamp: DateTime.now(),
        fromPosition: fromPosition,
        toPosition: toPosition,
      ),
    );
  }

  /// Starts (or restarts) the heartbeat timer if configured. Idempotent —
  /// the existing timer (if any) is left in place so the interval cadence
  /// survives any pause/resume that did not drop `_eventsLastPlaying`.
  void _startHeartbeatTimer() {
    final interval = CorePlayerMediaKit._configuration.heartbeatInterval;
    if (interval == null) return;
    if (_eventsHeartbeatTimer != null) return;
    _eventsHeartbeatTimer = Timer.periodic(interval, (_) {
      if (_disposed) return;
      if (!_eventsLastPlaying) return;
      final startedAt = _eventsStartTimestamp;
      if (startedAt == null) return;
      final src = _audioSource;
      if (src == null) return;
      final now = DateTime.now();
      _emitPlaybackEvent(
        PlaybackHeartbeatEvent(
          source: src,
          timestamp: now,
          elapsedSinceStart: now.difference(startedAt),
        ),
      );
    });
  }

  /// Cancels the heartbeat timer if running. Safe to call multiple times.
  void _stopHeartbeatTimer() {
    _eventsHeartbeatTimer?.cancel();
    _eventsHeartbeatTimer = null;
  }

  /// Tear down the event subscriptions + timer. Called from [dispose]
  /// BEFORE the broadcast controller closes, so a final in-flight emission
  /// queued in the same microtask still lands on the live controller.
  Future<void> _disposePlaybackEvents() async {
    _stopHeartbeatTimer();
    await _eventsPlayingSub?.cancel();
    await _eventsCompletedSub?.cancel();
    await _eventsBufferingSub?.cancel();
    _eventsPlayingSub = null;
    _eventsCompletedSub = null;
    _eventsBufferingSub = null;
  }
}
