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
  CoreAudioSource? get _audioSource;
  bool get needToLoad;
  set needToLoad(bool value);
  CoreAudioHandler? get currentAudioHandler;
  BehaviorSubject<double> get _rateSubject;
  BehaviorSubject<double> get _volumeSubject;
  Never _throwAndEmit(CorePlayerFailure failure);
  MediaItem _toMediaItem(CoreAudioSource audioSource);
  // Provided by [CorePlayerMediaKitNetwork]. A user-driven transport call
  // must drop the network auto-resume eligibility flag so a pending
  // resume-on-reconnect does not fight an explicit pause/play action.
  void _clearNetworkAutoResume();

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) _throwAndEmit(const PlayerDisposedFailure());
    final clamped = volume.clamp(0.0, 1.0);
    await runOnNative(() => player.setVolume(clamped * 100)); // media_kit uses 0-100 scale
    _volumeSubject.add(clamped);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    try {
      await runOnNative(() => player.setRate(speed));
    } catch (e) {
      _throwAndEmit(PlaybackSpeedFailure('Failed to set speed $speed', cause: e));
    }
    // stream.rate often does not emit on programmatic setRate; keep UI in sync.
    _rateSubject.add(player.state.rate);
  }

  @override
  Future<void> pause() async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    // User-initiated pause invalidates any pending auto-resume. The
    // [_clearNetworkAutoResume] hook is a no-op when called from inside a
    // network-policy dispatch (the dispatcher manages the flag directly).
    _clearNetworkAutoResume();
    await runOnNative(() => player.pause());
    CorePlayer.observer?.onPause(this);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    Duration positionToSeek = position;
    final Duration dur = player.state.duration;
    if (position > dur - CorePlayerMediaKit.seekEndThreshold) {
      return;
    }

    if (position < CorePlayerMediaKit.seekStartThreshold) {
      positionToSeek = Duration.zero;
    }

    final platform = player.platform;
    if (platform is NativePlayer && dur.inMilliseconds > 0) {
      // Bypass libavformat's slow mp3_seek path on HTTP-streamed MP3 by
      // routing through libmpv's SEEK_FACTOR / AVSEEK_FLAG_BYTE path. See
      // `audio_player/example/lib/demos/raw_media_kit.dart`
      // (_seekByPercent) for the full rationale. `as dynamic` is required
      // because NativePlayer is a stub on web without `command()`.
      final double pct = (positionToSeek.inMilliseconds / dur.inMilliseconds * 100).clamp(0.0, 100.0);
      await runOnNative(() async {
        await (platform as dynamic).command(['seek', pct.toString(), 'absolute-percent+keyframes']);
      });
    } else {
      await runOnNative(() => player.seek(positionToSeek));
    }
    CorePlayer.observer?.onSeek(this, positionToSeek);
  }

  @override
  Future<void> stop({bool fromDispose = false}) async {
    if (_disposed && !fromDispose) {
      _throwAndEmit(const PlayerDisposedFailure());
    }

    needToLoad = true;

    if (!fromDispose) {
      await runOnNative(() => player.seek(Duration.zero));
      await runOnNative(() => player.pause());
    } else {
      await runOnNative(() => player.stop());
    }
    currentAudioHandler?.emitPlaybackState(PlaybackState());
    currentAudioHandler?.emitMediaItem(null);
    CorePlayer.observer?.onStop(this);
  }

  @override
  Future<void> play({Duration? position}) async {
    if (_audioSource == null) {
      _throwAndEmit(const MediaItemNotSetFailure());
    }

    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }

    // Explicit play from the user/UI invalidates a pending policy-driven
    // resume — the user already resumed, the wrapper shouldn't re-fire.
    _clearNetworkAutoResume();

    if (needToLoad) {
      await load(_audioSource!);
    }

    if (audioHandler != null) {
      try {
        // Attach to OUR scope, not the default scope. `currentAudioHandler`
        // below additionally gates on `isActiveScope` so non-active scopes
        // don't push their MediaItem to the lock-screen.
        final isAttached = await audioHandler!.attach(this);
        // Request OS audio focus BEFORE emitting the MediaItem. On Android
        // 8+ the foreground service must be live for audio_service to
        // bridge MediaItem writes into the platform MediaSession — emitting
        // first leaves the bridged value to be silently dropped on some
        // Android versions, so the OS lock-screen / Now Playing surface
        // never switches off whichever app last claimed it (e.g. YouTube).
        // requestActiveSession is also where iOS's AVAudioSession is set
        // active; MPNowPlayingInfoCenter writes after that point land.
        // Idempotent via the bridge's _hasUserActivatedSession gate, so it
        // doesn't pause other apps' audio on repeated play() calls.
        await audioHandler!.requestActiveSession();
        if (isAttached) {
          currentAudioHandler?.emitMediaItem(_toMediaItem(_audioSource!));
        }
      } on Object catch (e) {
        _throwAndEmit(PlayFailure('Failed to attach player: $e', cause: e));
      }
    }

    if (position != null) {
      await runOnNative(() => player.seek(position));
    }

    await runOnNative(() => player.play());
    CorePlayer.observer?.onPlay(this);
  }
}
