part of 'core_player_media_kit.dart';

/// Queue mutation methods (insertNext/append/remove/move/replaceAt)
/// for [CorePlayerMediaKit]. Extracted from the main class; behaviour
/// unchanged. The intuitive `moveItem(from, to)` contract (the source
/// previously at `from` ends up at index `to`) is preserved via the
/// existing `_moveItemLocked` native-index translation.
mixin CorePlayerMediaKitMutation on CorePlayer {
  // Methods moved here. Concurrency helpers (runOnNative, runOnQueue,
  // nextSetQueueToken) resolve at the host class because [CorePlayerMediaKit]
  // mixes in [CorePlayerMediaKitConcurrency] too. Library-private host
  // members are surfaced as abstract declarations so the analyzer can
  // type-check the mixin body without losing access through the
  // `on CorePlayer` constraint.
  Player get player;
  bool get _disposed;
  List<CorePlayerAudioSource> get _sources;
  BehaviorSubject<CorePlayerQueue> get _queueStreamBacking;

  Never _throwAndEmit(CorePlayerFailure failure);
  Media _toMedia(CorePlayerAudioSource src);
  Future<void> _setQueueLocked(CorePlayerQueue queue, int token);
  int nextSetQueueToken();
  Future<T> runOnNative<T>(Future<T> Function() action);
  Future<T> runOnQueue<T>(Future<T> Function() action);

  @override
  Future<void> removeAt(int index) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (index < 0 || index >= _sources.length) {
      _throwAndEmit(
        QueueOutOfBoundsFailure(
          'Index $index out of bounds [0, ${_sources.length})',
        ),
      );
    }
    return runOnQueue(() => _removeAtLocked(index));
  }

  Future<void> _removeAtLocked(int index) async {
    if (_disposed) return;
    if (index < 0 || index >= _sources.length) return;
    // Mirror before native so the playlist subscription sees aligned
    // `_sources.length` when media_kit's `remove()` broadcasts.
    _sources.removeAt(index);
    await runOnNative(() => player.remove(index));
  }

  @override
  Future<void> insertNext(CorePlayerAudioSource source) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    return runOnQueue(() => _insertNextLocked(source));
  }

  Future<void> _insertNextLocked(CorePlayerAudioSource source) async {
    if (_disposed) return;
    if (_sources.isEmpty) {
      // No active queue → degenerate to a single-item set. setQueue acquires
      // queueLock too; call the underlying body directly to avoid re-entry
      // (loadAndPlay uses the same trick).
      await _setQueueLocked(
        CorePlayerQueue.single(source),
        nextSetQueueToken(),
      );
      return;
    }
    final media = _toMedia(source);
    final currentIndex = _queueStreamBacking.hasValue
        ? _queueStreamBacking.value.currentIndex
        : 0;
    // Insertion target is "right after the active item". Past-the-end is
    // legal here — degenerates to a plain append.
    final insertAt = (currentIndex + 1).clamp(0, _sources.length);
    final preAddLength = _sources.length;
    // Wrapper-side mirror BEFORE the native call: media_kit broadcasts
    // its playlist event synchronously from inside `add()` before the
    // libmpv command awaits, so `_sources` must already match.
    _sources.insert(insertAt, source);
    await runOnNative(() => player.add(media));
    if (_disposed) return;
    if (insertAt != preAddLength) {
      // `player.add` always appends; re-order so the new item lands at
      // [insertAt]. `_sources` already reflects the post-move state, so
      // the playlist subscription's clamp + projection stay consistent.
      await runOnNative(() => player.move(preAddLength, insertAt));
    }
  }

  @override
  Future<void> appendToQueue(CorePlayerAudioSource source) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    return runOnQueue(() => _appendOneLocked(source));
  }

  Future<void> _appendOneLocked(CorePlayerAudioSource source) async {
    if (_disposed) return;
    if (_sources.isEmpty) {
      await _setQueueLocked(
        CorePlayerQueue.single(source),
        nextSetQueueToken(),
      );
      return;
    }
    final media = _toMedia(source);
    _sources.add(source);
    await runOnNative(() => player.add(media));
  }

  @override
  Future<void> moveItem(int from, int to) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (_sources.isEmpty) return;
    return runOnQueue(() => _moveItemLocked(from, to));
  }

  Future<void> _moveItemLocked(int from, int to) async {
    if (_disposed) return;
    final length = _sources.length;
    final clampedFrom = _clampQueueIndex(from, length);
    final clampedTo = _clampQueueIndex(to, length);
    if (clampedFrom == clampedTo) return;
    _moveInPlace(_sources, clampedFrom, clampedTo);
    // Public contract: source at [from] ends up at index [to]. mpv's
    // `playlist-move <from> <to>` inserts the item at position `to - 0.5`
    // AFTER the removal, so to land it at final index [clampedTo] we
    // must pass `clampedTo + 1` when moving forward (the removal shifts
    // later items left by one). Backward moves use [clampedTo] unchanged.
    final nativeTo = clampedTo >= clampedFrom ? clampedTo + 1 : clampedTo;
    await runOnNative(() => player.move(clampedFrom, nativeTo));
  }

  @override
  Future<void> replaceAt(
    int index,
    CorePlayerAudioSource source, {
    bool preservePosition = false,
  }) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (index < 0 || index >= _sources.length) {
      _throwAndEmit(
        QueueOutOfBoundsFailure(
          'Index $index out of bounds [0, ${_sources.length})',
        ),
      );
    }
    return runOnQueue(
      () => _replaceAtLocked(
        index,
        source,
        preservePosition: preservePosition,
      ),
    );
  }

  Future<void> _replaceAtLocked(
    int index,
    CorePlayerAudioSource source, {
    required bool preservePosition,
  }) async {
    if (_disposed) return;
    if (index < 0 || index >= _sources.length) return;
    final currentIndex = _queueStreamBacking.hasValue
        ? _queueStreamBacking.value.currentIndex
        : 0;
    final isActive = index == currentIndex;
    // Position restoration is best-effort: capture before the swap, replay
    // after the new source's first position emission. Tests assert within
    // [kReplacePreservePositionTolerance].
    final Duration? capturedPosition = (isActive && preservePosition)
        ? player.state.position
        : null;

    final media = _toMedia(source);
    // Strategy: add(new) → end, move(end, index) → new lands at [index]
    // and old shifts to [index + 1], remove(index + 1) → drop the old. For
    // the active row this means the new media is decoded by media_kit
    // before the old is dropped, so the audio device is not torn down
    // (matches the gapless path also used for next/previous).
    final preAddLength = _sources.length;
    _sources.insert(index, source);
    await runOnNative(() => player.add(media));
    if (_disposed) return;
    await runOnNative(() => player.move(preAddLength, index));
    if (_disposed) return;
    // Old item is now at [index + 1] in BOTH the wrapper mirror and the
    // native playlist; the remove() call drops it in lock-step.
    _sources.removeAt(index + 1);
    await runOnNative(() => player.remove(index + 1));
    if (_disposed) return;

    if (isActive) {
      // The active row swapped under our feet — jump to ensure libmpv is
      // decoding the new media (rather than the about-to-be-removed
      // duplicate it had been continuing). Idempotent if media_kit already
      // landed on the new index after move/remove.
      await runOnNative(() => player.jump(index));
      if (_disposed) return;
      if (capturedPosition != null && capturedPosition > Duration.zero) {
        // Best-effort seek: if the new source's duration is unknown yet,
        // we still issue the seek — libmpv accepts an absolute target and
        // clamps after demuxing. The actual realised position lands on
        // the next position-stream emission (see
        // [kReplacePreservePositionTolerance]).
        await runOnNative(() => player.seek(capturedPosition));
      }
    }
  }

  @override
  Future<void> appendAllToQueue(List<CorePlayerAudioSource> sources) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (sources.isEmpty) return;
    return runOnQueue(() => _appendAllLocked(sources));
  }

  Future<void> _appendAllLocked(List<CorePlayerAudioSource> sources) async {
    if (_disposed) return;
    // Empty-queue fast path: bootstrap with setQueue so the playlist stream
    // wiring + audioSource projection take the same code path as a fresh
    // open instead of N appends against an empty native playlist.
    if (_sources.isEmpty) {
      await _setQueueLocked(CorePlayerQueue(sources), nextSetQueueToken());
      return;
    }
    for (final source in sources) {
      if (_disposed) return;
      final media = _toMedia(source);
      _sources.add(source);
      await runOnNative(() => player.add(media));
    }
  }
}
