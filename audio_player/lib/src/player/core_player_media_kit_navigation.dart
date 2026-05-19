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
  List<CorePlayerAudioSource> get _sources;
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
}
