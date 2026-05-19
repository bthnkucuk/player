part of 'core_player_media_kit.dart';

/// Queue-navigation methods (skip / shuffle / loop mode) for
/// [CorePlayerMediaKit]. Extracted from the main class; behaviour unchanged.
mixin CorePlayerMediaKitNavigation on CorePlayer
    implements CorePlayerMediaKitConcurrency {
  // Host-class members accessed from this mixin. [CorePlayerMediaKit]
  // satisfies these via its real fields/methods at mix-in time.
  Player get player;
  bool get _disposed;
  BehaviorSubject<CorePlayerQueue> get _queueStreamBacking;
  BehaviorSubject<CorePlayerLoopMode> get _loopModeSubject;
  BehaviorSubject<bool> get _shuffleSubject;
  List<CoreAudioSource> get _sources;
  Never _throwAndEmit(CorePlayerFailure failure);

  @override
  Future<void> setLoopMode(CorePlayerLoopMode mode) async {
    if (_disposed) _throwAndEmit(const PlayerDisposedFailure());
    final PlaylistMode native;
    switch (mode) {
      case CorePlayerLoopMode.off:
        native = PlaylistMode.none;
      case CorePlayerLoopMode.one:
        native = PlaylistMode.single;
      case CorePlayerLoopMode.all:
        native = PlaylistMode.loop;
    }
    await runOnNative(() => player.setPlaylistMode(native));
    _loopModeSubject.add(mode);
  }

  @override
  Future<void> skipToNext() async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (_sources.isEmpty) {
      _throwAndEmit(const QueueOutOfBoundsFailure('Cannot skip in an empty queue'));
    }
    // Read the latest observed index from [_queueStreamBacking] — kept in
    // sync via the playlist subscription. Falls back to 0 when no playlist
    // emission has landed yet (e.g. immediately after setQueue, before the
    // platform acknowledges the open).
    final currentIndex = _queueStreamBacking.value.currentIndex;
    final atEnd = currentIndex >= _sources.length - 1;
    if (atEnd && loopMode != CorePlayerLoopMode.all) {
      _throwAndEmit(const QueueOutOfBoundsFailure('Already at last track'));
    }
    // media_kit owns wrap-around when [PlaylistMode.loop] is set. The wrapper
    // index + observer.onLoad are updated by the [player.stream.playlist]
    // listener installed in the constructor.
    final wasPlaying = isPlaying;
    if (wasPlaying) {
      // Fix 3 (Layer 1) / PROBE-B1: re-claim AVAudioSession BEFORE libmpv's
      // AudioUnit swap so a contested app (e.g. backgrounded YouTube) doesn't
      // grab focus during the momentary teardown. Mirrors play().
      await audioHandler?.requestActiveSession();
    }
    await runOnNative(() => player.next());
    if (wasPlaying) {
      // Idempotent post-jump re-activation: claw the session back if iOS
      // handed it away during the AU swap, before libmpv resumes output.
      await audioHandler?.requestActiveSession();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (_sources.isEmpty) {
      _throwAndEmit(const QueueOutOfBoundsFailure('Cannot skip in an empty queue'));
    }
    final currentIndex = _queueStreamBacking.value.currentIndex;
    final atStart = currentIndex <= 0;
    if (atStart && loopMode != CorePlayerLoopMode.all) {
      _throwAndEmit(const QueueOutOfBoundsFailure('Already at first track'));
    }
    final wasPlaying = isPlaying;
    if (wasPlaying) {
      // Fix 3 (Layer 1) / PROBE-B1: re-claim AVAudioSession around libmpv's
      // AudioUnit swap so a contested app can't grab focus mid-switch.
      await audioHandler?.requestActiveSession();
    }
    await runOnNative(() => player.previous());
    if (wasPlaying) {
      // Idempotent post-jump re-activation.
      await audioHandler?.requestActiveSession();
    }
  }

  @override
  Future<void> skipToIndex(int index) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (index < 0 || index >= _sources.length) {
      _throwAndEmit(QueueOutOfBoundsFailure('Index $index out of bounds [0, ${_sources.length})'));
    }
    final wasPlaying = isPlaying;
    if (wasPlaying) {
      // Fix 3 (Layer 1) / PROBE-B1: re-claim AVAudioSession around libmpv's
      // AudioUnit swap so a contested app can't grab focus mid-switch.
      await audioHandler?.requestActiveSession();
    }
    await runOnNative(() => player.jump(index));
    if (wasPlaying) {
      // Idempotent post-jump re-activation.
      await audioHandler?.requestActiveSession();
    }
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    await runOnNative(() => player.setShuffle(enabled));
    _shuffleSubject.add(enabled);
  }
}
