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

/// Mirrors media_kit's native `move(from, to)` semantics on a wrapper-side
/// `List<CorePlayerAudioSource>`: removes the item at [from] then re-inserts
/// it so it ends up at the position before the original [to] index
/// (equivalent to mpv's `playlist-move <from> <to>`).
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
  // media_kit's SplayTreeMap trick inserts at `to - 0.5` AFTER removing
  // `from`. Re-deriving here: if `to > from`, the removal shifted later
  // items left by one, so the insertion position is `to - 1`. Otherwise
  // it's `to` unchanged. This matches the `playlist-move` semantics
  // observed in media_kit's `real.dart`.
  final insertAt = to > from ? to - 1 : to;
  list.insert(insertAt, item);
}
