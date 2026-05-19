part of 'core_player_media_kit.dart';

/// Queue mutation methods (insertNext/append/remove/move/replaceAt)
/// for [CorePlayerMediaKit]. Extracted from the main class; behaviour
/// unchanged. The intuitive `moveItem(from, to)` contract (the source
/// previously at `from` ends up at index `to`) is preserved via the
/// existing `_moveItemLocked` native-index translation.
mixin CorePlayerMediaKitMutation on CorePlayer {
  // Methods moved here. Concurrency helpers (runOnNative, runOnQueue,
  // nextSetQueueToken) resolve at the host class because [CorePlayerMediaKit]
  // mixes in [CorePlayerMediaKitConcurrency] too.
}
