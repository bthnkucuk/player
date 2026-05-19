part of 'core_player_media_kit.dart';

/// Playback-transport methods (play / pause / stop / seek / playback-speed /
/// volume) for [CorePlayerMediaKit]. Extracted from the main class;
/// behaviour unchanged.
mixin CorePlayerMediaKitPlayback on CorePlayer, CorePlayerMediaKitConcurrency {
  // Host-class members accessed from this mixin. These are satisfied by
  // [CorePlayerMediaKit]'s real fields/methods at mix-in time; declaring
  // them here lets the analyzer resolve identifiers without changing
  // visibility or moving any state.
  Player get player;
  bool get _disposed;
  CorePlayerAudioSource? get _audioSource;
  bool get needToLoad;
  CoreAudioHandler? get currentAudioHandler;
  BehaviorSubject<double> get _rateSubject;
  BehaviorSubject<double> get _volumeSubject;
  Never _throwAndEmit(CorePlayerFailure failure);
  MediaItem _toMediaItem(CorePlayerAudioSource audioSource);

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) _throwAndEmit(const PlayerDisposedFailure());
    final clamped = volume.clamp(0.0, 1.0);
    await runOnNative(() => player.setVolume(clamped * 100)); // media_kit uses 0-100 scale
    _volumeSubject.add(clamped);
  }
}
