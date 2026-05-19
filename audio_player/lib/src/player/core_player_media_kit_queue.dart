part of 'core_player_media_kit.dart';

/// Clamps an index into `[0, length)`. Returns `0` when the queue is empty
/// so callers using the result for read-only diagnostics don't trip
/// negative-index assertions; pair with an emptiness check at the call
/// site before issuing native verbs that require a non-empty queue.
int _clampQueueIndex(int index, int length) {
  if (length <= 0) return 0;
  if (index < 0) return 0;
  if (index >= length) return length - 1;
  return index;
}

/// Wrapper-side mirror of the public [CorePlayer.moveItem] contract:
/// after the call, the item previously at [from] occupies index [to] in
/// [list]. Implemented as `removeAt(from)` then `insert(to, item)`; both
/// indices are assumed pre-clamped into `[0, list.length)` by the caller.
///
/// Mutates [list] in place. The wrapper-side mirror is necessary because
/// the platform broadcasts `playlistController.add(...)` synchronously
/// inside its own body BEFORE the `await libmpv-command` boundary — the
/// playlist-subscription must observe `_sources` already updated to the
/// post-move layout, otherwise the derived [CorePlayerQueue] indexes
/// against a stale source list (and the active-source projection lags by
/// one platform emission).
void _moveInPlace(List<CorePlayerAudioSource> list, int from, int to) {
  if (from == to) return;
  final item = list.removeAt(from);
  list.insert(to, item);
}
