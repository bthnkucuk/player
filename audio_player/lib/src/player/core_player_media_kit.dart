import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';
import 'package:audio_player/src/player/core_player_media_kit_concurrency.dart';

part 'core_player_media_kit_libmpv.dart';

class CorePlayerMediaKit extends CorePlayer with CorePlayerMediaKitConcurrency {
  /// Seeks within this distance of the start are snapped to zero
  /// (avoids triggering a buffer flush for cosmetic micro-seeks).
  static const Duration seekStartThreshold = Duration(milliseconds: 300);

  /// Seeks within this distance of the end are ignored (would otherwise
  /// cause an immediate "completed" + race with the natural end-of-stream).
  static const Duration seekEndThreshold = Duration(milliseconds: 300);

  /// Initialise platform-side dependencies. Idempotent: safe to call multiple
  /// times. Installs the `audio_service` / `audio_session` bridge into
  /// [CoreAudioHandler] so the abstraction package does not import either.
  ///
  /// Pass [configuration] to override defaults (native buffer size, Android
  /// notification channel metadata, foreground / resume policy, and the
  /// `load()` retry policy). When omitted, the wrapper defaults are used —
  /// see [CorePlayerConfiguration].
  static void ensureInitialized({CorePlayerConfiguration? configuration}) {
    _configuration = configuration ?? const CorePlayerConfiguration();
    MediaKit.ensureInitialized();
    CoreAudioHandler.registerBridge(CoreMediaKitAudioServiceBridge());
    CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
      return CorePlayerMediaKit(audioSource: audioSource, audioHandler: audioHandler, autoLoad: autoLoad);
    });
  }

  /// Active wrapper configuration. Reflects the value passed to the most
  /// recent [ensureInitialized] call (or the default if none was passed).
  static CorePlayerConfiguration get configuration => _configuration;

  static CorePlayerConfiguration _configuration = const CorePlayerConfiguration();

  /// Test seam: replace the active [configuration] without going through the
  /// real [ensureInitialized] (which touches MediaKit + AudioService natives).
  @visibleForTesting
  static void debugSetConfigurationForTest(CorePlayerConfiguration configuration) {
    _configuration = configuration;
  }

  /// Centralised log dispatch. Routes through the configured
  /// [CorePlayerConfiguration.logCallback] when present, falling back to
  /// `dart:developer`'s `log` otherwise. Public so the sibling
  /// `core_audio_service_bridge.dart` can reuse the same indirection.
  @internal
  static void log(String message, {Object? error, StackTrace? stackTrace, String? name}) {
    final cb = _configuration.logCallback;
    if (cb != null) {
      cb(message, error: error, stackTrace: stackTrace);
    } else {
      developer.log(message, error: error, stackTrace: stackTrace, name: name ?? 'audio_player');
    }
  }

  /// Test seam: drive the same dispatch path as production log calls so the
  /// `logCallback` plumbing is verifiable without faking a native failure.
  @visibleForTesting
  static void debugLog(String message) {
    log(message);
  }

  /// Returns this player's [audioHandler] only when:
  ///   1. The handler scope considers this player its `current` player, AND
  ///   2. The handler scope is the active scope (the one owning the OS
  ///      surface — lock-screen, MediaSession, audio_session).
  ///
  /// Used as a gate before forwarding `MediaItem` / `PlaybackState` to the
  /// bridge: only the active scope's current player should drive the
  /// lock-screen. Players in non-active scopes still play (mixed audio) but
  /// don't appear in the system UI.
  CoreAudioHandler? get currentAudioHandler {
    final scope = audioHandler;
    if (scope == null) return null;
    return scope.isCurrent(this) && scope.isActiveScope ? scope : null;
  }

  CorePlayerAudioSource? _audioSource;
  @override
  CorePlayerAudioSource? get audioSource => _audioSource;

  /// Mutate [_audioSource] and broadcast on [audioSourceStream]. All
  /// assignments to [_audioSource] route through this helper so the
  /// subject and the field cannot drift.
  void _setAudioSource(CorePlayerAudioSource? source) {
    _audioSource = source;
    if (!_audioSourceSubject.isClosed) {
      _audioSourceSubject.add(source);
    }
  }

  late final BehaviorSubject<CorePlayerAudioSource?> _audioSourceSubject = BehaviorSubject<CorePlayerAudioSource?>.seeded(
    _audioSource,
  );

  @override
  late final ValueStream<CorePlayerAudioSource?> audioSourceStream = _audioSourceSubject.stream;

  @override
  final CoreAudioHandler? audioHandler;

  final bool? _autoLoad;
  @override
  bool get autoLoad => _autoLoad ?? false;

  final Player player;

  /// Direct construction is internal — use [CorePlayer.create] after
  /// [CorePlayerMediaKit.ensureInitialized]. The constructor is retained
  /// for internal use and tests; external callers will receive a lint
  /// warning.
  @internal
  @override
  CorePlayerMediaKit({
    CorePlayerAudioSource? audioSource,
    this.audioHandler,
    bool autoLoad = false,
    @visibleForTesting Player? testPlayer,
  }) : player = testPlayer ?? Player(configuration: PlayerConfiguration(bufferSize: _configuration.bufferSizeBytes)),
       _audioSource = audioSource,
       _autoLoad = autoLoad {
    // Apply libmpv property overrides (defaults + consumer overrides from
    // [CorePlayerConfiguration.libmpvOptions]) as soon as the [Player] exists.
    // Tracked via [_trackPending] so [dispose] drains a stale setProperty
    // before tearing down the native player (mpv#6537 `+fastseek`).
    _trackPending(_applyLibmpvOptions());
    if (audioHandler != null) {
      // Constructor cannot be async; fire-and-forget the attach. The session
      // activation inside `attach` is best-effort — if it fails, surface
      // the error through the existing player error stream. Attach to the
      // SCOPE the player was constructed with (via `audioHandler`), not the
      // default scope — this is how multi-scope usage works.
      _trackPending(
        audioHandler!.attach(this).then<void>((_) {}).catchError((Object e, StackTrace s) {
          if (_disposed) return;
          _playerErrorSubject.add('attachPlayer failed: $e');
        }),
      );
    }
    _playerErrorSubscription = player.stream.error.listen((error) {
      _playerErrorSubject.add(error.toString());
      _errorController.add(LoadFailure('Player error: $error', cause: error));
    });

    _durationSubscription = player.stream.duration.listen(_durationSubject.add);
    _positionSubscription = player.stream.position.listen(_positionSubject.add);
    _bufferSubscription = player.stream.buffer.listen(_bufferSubject.add);
    _playingSubscription = player.stream.playing.listen(_playingSubject.add);

    _rateSubject.add(player.state.rate);
    _rateSubscription = player.stream.rate.listen((a) {
      _rateSubject.add(a);
    });

    // media_kit's volume is on a [0, 100] scale. Normalize to our [0.0, 1.0]
    // API contract both on initial seed and on every stream emission.
    _volumeSubject.add((player.state.volume / 100).clamp(0.0, 1.0));
    _volumeSubscription = player.stream.volume.listen((v) {
      _volumeSubject.add((v / 100).clamp(0.0, 1.0));
    });

    // Auto-advance / gapless: media_kit owns the playlist after [setQueue]
    // calls [player.open(Playlist(...))]. Whenever it moves to a new index
    // (auto-advance on track end, [player.next/previous/jump], or shuffle),
    // it emits a new [Playlist] here. We derive a fresh [CorePlayerQueue]
    // from our parallel [_sources] list (keyed by playlist.index) and push
    // it onto [_queueStreamBacking]. Communication is strictly native →
    // wrapper; the wrapper never writes back into media_kit's playlist.
    //
    // Single source of truth: media_kit owns playback queue state. The
    // wrapper holds only [_sources] (the typed-source mapping) to round-
    // trip Playlist → CorePlayerQueue, and [_queueStreamBacking] which is a
    // pure projection of player.stream.playlist.
    _playlistSubscription = player.stream.playlist.listen((playlist) {
      if (_disposed) return;
      if (_sources.isEmpty) {
        // setQueue(empty) already pushed an empty queue; ignore any stale
        // platform emissions that may arrive after stop().
        return;
      }
      final index = playlist.index.clamp(0, _sources.length - 1);
      final newQueue = CorePlayerQueue(_sources, currentIndex: index);
      final previousIndex = _queueStreamBacking.hasValue ? _queueStreamBacking.value.currentIndex : -1;
      _queueStreamBacking.add(newQueue);
      if (previousIndex != index) {
        final newSource = _sources[index];
        _setAudioSource(newSource);
        CorePlayer.observer?.onLoad(this, newSource);
        currentAudioHandler?.emitMediaItem(_toMediaItem(newSource));
      }
    });

    // Shuffle: media_kit emits the canonical value on its stream after a
    // [player.setShuffle] call. Mirror into our seeded BehaviorSubject so
    // [shuffle] / [shuffleStream] stay in sync with the native state.
    _shuffleSubscription = player.stream.shuffle.listen(_shuffleSubject.add);

    // INTERNAL position input is throttled (default 200ms, trailing) so the
    // playerState combineLatest5 doesn't churn at native rate (~30 Hz). The
    // public [positionStream] remains at native rate for UI scrubbers — only
    // the internal pipeline is rate-limited. Throttle is configurable via
    // [CorePlayerConfiguration.internalPositionThrottle]; pass [Duration.zero]
    // to opt out (e.g. tests that drive single position emits synchronously).
    final positionThrottle = _configuration.internalPositionThrottle;
    final throttledPosition = positionThrottle == Duration.zero
        ? player.stream.position
        : player.stream.position.throttleTime(positionThrottle, leading: true, trailing: true);
    _playerStateSubscription = Rx.combineLatest5(
      player.stream.buffer,
      player.stream.playing,
      throttledPosition,
      _playerErrorSubject.stream,
      player.stream.completed.startWith(false),
      (buffer, playing, position, error, completed) {
        if (_audioSource == null) {
          return CorePlayerState.idle;
        }
        if (error != null) {
          needToLoad = true;
          return CorePlayerState.error;
        } else if (buffer > position) {
          return CorePlayerState.ready;
        } else if (completed) {
          return CorePlayerState.completed;
        } else {
          return CorePlayerState.loading;
        }
      },
    ).listen(_updatePlayerState);
    _playbackStateSubscription =
        Rx.combineLatest4(
          player.stream.duration.startWith(Duration.zero),
          player.stream.playing.startWith(false),
          player.stream.buffer.startWith(Duration.zero),
          _playerStateSubject.stream,
          (duration, playing, buffer, state) => _playbackStateValue(
            position: position,
            duration: duration,
            playing: playing,
            buffer: buffer,
            processingState: _toProcessingState(state),
          ),
        ).listen((state) {
          // Only forward PlaybackState to the bridge when we're the current
          // player in our own scope AND that scope is active. Non-active
          // scopes still play but don't drive the lock-screen.
          if (currentAudioHandler != null) {
            audioHandler?.emitPlaybackState(state);
          }
        });
    _audioHandlerEventSubscription = audioHandler?.eventStream.listen((event) {
      // Each scope has its own eventStream; this player only reacts when
      // it's the current player in its own scope.
      if (_disposed) return;
      if (!(audioHandler?.isCurrent(this) ?? false)) return;

      // Lock-screen / interruption reactions are tracked so dispose drains
      // any in-flight dispatch landing in the same microtask.
      switch (event) {
        case CoreAudioHandlerPlayEvent():
          _trackPending(_swallowDisposed(play()));
        case CoreAudioHandlerPauseEvent():
          _trackPending(_swallowDisposed(pause()));
        case CoreAudioHandlerStopEvent():
          _trackPending(_swallowDisposed(stop()));
        case CoreAudioHandlerTaskRemovedEvent():
          // System tore down our task — react the same way as a stop. The
          // handler-level onTaskRemoved() already clears attached players
          // and emits stop state; this arm is the per-player reaction.
          _trackPending(_swallowDisposed(stop()));
        case CoreAudioHandlerSeekEvent():
          _trackPending(_swallowDisposed(seek(event.position)));
        case CoreAudioHandlerInterruptionBeginEvent():
          // Other audio app / phone call grabbed focus — pause so we don't
          // mix audio. The bridge remembered we were playing, so a later
          // interruption-end with shouldResume=true will play() again.
          if (isPlaying) _trackPending(_swallowDisposed(pause()));
        case CoreAudioHandlerInterruptionEndEvent(:final shouldResume):
          if (shouldResume) _trackPending(_swallowDisposed(play()));
        case CoreAudioHandlerBecomingNoisyEvent():
          // Headphones unplugged — avoid blasting through speakers.
          if (isPlaying) _trackPending(_swallowDisposed(pause()));
        case CoreAudioHandlerAppResumeEvent():
          // Generic app-resume signal. The bridge already synthesizes
          // [CoreAudioHandlerInterruptionEndEvent(shouldResume: true)] when it
          // tracked an interruption-while-playing, so the recovery semantic
          // flows through the InterruptionEnd arm above. We deliberately do
          // not re-trigger playback on every foregrounding here.
          break;
        case CoreAudioHandlerSkipToNextEvent():
          // Lock-screen / notification "next" — advance the queue. Errors
          // (e.g. out-of-bounds) are visible via [errorStream]; we swallow
          // the thrown failure here to avoid an uncaught async error from
          // the system-control surface.
          _trackPending(
            skipToNext().catchError((Object _) {
              // QueueOutOfBoundsFailure already emitted on errorStream.
            }),
          );
        case CoreAudioHandlerSkipToPreviousEvent():
          _trackPending(
            skipToPrevious().catchError((Object _) {
              // ditto
            }),
          );
      }
    });
    if (audioSource != null && autoLoad) {
      _trackPending(
        load(audioSource).catchError((Object e, StackTrace s) {
          if (_disposed) return;
          _playerErrorSubject.add(e.toString());
        }),
      );
    }
    CorePlayer.observer?.onCreate(this);
  }

  /// Drained at the top of [dispose] before subscriptions cancel so an
  /// in-flight setProperty / attach / autoLoad does not land against a
  /// torn-down player.
  final Set<Future<void>> _pendingOps = <Future<void>>{};

  void _trackPending(Future<void> op) {
    _pendingOps.add(op);
    op.whenComplete(() => _pendingOps.remove(op));
  }

  /// Absorbs PlayerDisposedFailure so a system-control event that lands in
  /// the same microtask as [dispose] does not surface as an uncaught zone
  /// error.
  Future<void> _swallowDisposed(Future<void> op) {
    return op.catchError((Object e) {
      if (e is PlayerDisposedFailure) return;
      throw e;
    });
  }

  /// Build the effective libmpv option map (defaults overlaid with
  /// [CorePlayerConfiguration.libmpvOptions]) and forward it through
  /// [_libmpvOptionsApplier]. An empty-string override skips that key
  /// (consumer disabled a default). `cache-dir` is resolved lazily via
  /// `path_provider.getApplicationCacheDirectory()`; failures are swallowed
  /// and logged via [log] so a missing cache dir never blocks playback.
  Future<void> _applyLibmpvOptions() async {
    if (_disposed) return;
    final overrides = _configuration.libmpvOptions ?? const <String, String>{};
    final effective = <String, String>{};
    // Defaults first, then consumer overrides — empty-string values from
    // either source are treated as "skip this property".
    for (final entry in _kDefaultLibmpvOptions.entries) {
      if (!overrides.containsKey(entry.key)) {
        effective[entry.key] = entry.value;
      }
    }
    for (final entry in overrides.entries) {
      if (entry.value.isEmpty) continue;
      effective[entry.key] = entry.value;
    }

    // cache-dir: resolved async unless the consumer pinned a value (or
    // explicitly disabled it with the empty-string sentinel).
    if (!overrides.containsKey('cache-dir')) {
      try {
        final base = await getApplicationCacheDirectory();
        // Re-check: the platform-channel round-trip can outlive a fast
        // dispose; setProperty past this point races with player.dispose().
        if (_disposed) return;
        final dir = Directory('${base.path}/libmpv-cache');
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        effective['cache-dir'] = dir.path;
      } on Object catch (e, s) {
        if (_disposed) return;
        log('libmpv cache-dir resolution skipped', error: e, stackTrace: s);
      }
    } else if (overrides['cache-dir']!.isNotEmpty) {
      effective['cache-dir'] = overrides['cache-dir']!;
    }

    if (_disposed) return;
    if (effective.isEmpty) return;
    try {
      await _libmpvOptionsApplier(player, effective);
    } on Object catch (e, s) {
      if (_disposed) return;
      log('libmpv options applier failed', error: e, stackTrace: s);
    }
  }

  StreamSubscription<CorePlayerState>? _playerStateSubscription;
  StreamSubscription<String?>? _playerErrorSubscription;

  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  StreamSubscription<CoreAudioHandlerEvent?>? _audioHandlerEventSubscription;

  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _bufferSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<double>? _rateSubscription;
  StreamSubscription<double>? _volumeSubscription;
  StreamSubscription<Playlist>? _playlistSubscription;
  StreamSubscription<bool>? _shuffleSubscription;

  final BehaviorSubject<String?> _playerErrorSubject = BehaviorSubject<String?>.seeded(null);
  final BehaviorSubject<CorePlayerState> _playerStateSubject = BehaviorSubject<CorePlayerState>.seeded(CorePlayerState.idle);
  final BehaviorSubject<Duration> _durationSubject = BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _positionSubject = BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _bufferSubject = BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<bool> _playingSubject = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<double> _rateSubject = BehaviorSubject<double>.seeded(1.0);
  final BehaviorSubject<double> _volumeSubject = BehaviorSubject<double>.seeded(1.0);
  final BehaviorSubject<CorePlayerLoopMode> _loopModeSubject = BehaviorSubject<CorePlayerLoopMode>.seeded(
    CorePlayerLoopMode.off,
  );

  /// Derived from `player.stream.playlist` — DO NOT add directly except
  /// from the playlist subscription, or from the explicit empty-queue
  /// fast path in [setQueue]. [setQueue] mutates [_sources] and calls
  /// [player.open]; the playlist stream then drives this subject. Single
  /// source of truth: media_kit owns playback queue state, the wrapper
  /// only stores the typed-source mapping in [_sources].
  final BehaviorSubject<CorePlayerQueue> _queueStreamBacking = BehaviorSubject<CorePlayerQueue>.seeded(
    const CorePlayerQueue.empty(),
  );

  /// Parallel list of [CorePlayerAudioSource] matching the [Media] list in
  /// media_kit's current [Playlist]. Indexed by position. Used to round-
  /// trip from a media_kit [Playlist] back to a typed [CorePlayerQueue].
  /// Only mutated inside [setQueue] BEFORE `player.open(...)` is awaited;
  /// every queue change is then observed via the playlist subscription.
  List<CorePlayerAudioSource> _sources = const [];

  final BehaviorSubject<bool> _shuffleSubject = BehaviorSubject<bool>.seeded(false);

  final StreamController<CorePlayerFailure> _errorController = StreamController<CorePlayerFailure>.broadcast();

  @override
  Stream<CorePlayerFailure> get errorStream => _errorController.stream;

  /// Emits [failure] to [errorStream] then throws it. Used at every synchronous
  /// throw site so passive observers see the same failure as direct callers.
  /// The emit is best-effort — if the controller has already been closed (post
  /// dispose), only the throw runs.
  Never _throwAndEmit(CorePlayerFailure failure) {
    if (!_errorController.isClosed) {
      _errorController.add(failure);
    }
    CorePlayer.observer?.onError(this, failure);
    throw failure;
  }

  @override
  CorePlayerState get playerState => _playerStateSubject.value;
  @override
  Duration get position => _positionSubject.value;
  @override
  Duration get duration => _durationSubject.value;
  @override
  Duration get buffer => _bufferSubject.value;
  @override
  bool get isPlaying => _playingSubject.value;

  @override
  late final ValueStream<CorePlayerState> playerStateStream = _playerStateSubject.stream;
  @override
  late final ValueStream<Duration> positionStream = _positionSubject.stream;
  @override
  late final ValueStream<Duration> durationStream = _durationSubject.stream;
  @override
  late final ValueStream<Duration> bufferStream = _bufferSubject.stream;
  @override
  late final ValueStream<bool> playingStream = _playingSubject.stream;

  @override
  double get playbackSpeed => _rateSubject.value;

  @override
  late final ValueStream<double> playbackSpeedStream = _rateSubject.stream;

  @override
  double get volume => _volumeSubject.value;

  @override
  late final ValueStream<double> volumeStream = _volumeSubject.stream;

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) _throwAndEmit(const PlayerDisposedFailure());
    final clamped = volume.clamp(0.0, 1.0);
    await runOnNative(() => player.setVolume(clamped * 100)); // media_kit uses 0-100 scale
    _volumeSubject.add(clamped);
  }

  @override
  CorePlayerLoopMode get loopMode => _loopModeSubject.value;

  @override
  late final ValueStream<CorePlayerLoopMode> loopModeStream = _loopModeSubject.stream;

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

  void _updatePlayerState(CorePlayerState state) {
    final previous = _playerStateSubject.value;
    _playerStateSubject.add(state);
    if (previous != state) {
      CorePlayer.observer?.onStateChange(this, previous, state);
      // Auto-advance is handled by media_kit's Playlist primitive — the
      // active [PlaylistMode] (none/single/loop, set via [setLoopMode]) drives
      // gapless track transitions natively. The wrapper observes the
      // resulting index changes through [player.stream.playlist]; no manual
      // completion handler is needed here.
    }
  }

  @visibleForTesting
  bool needToLoad = true;

  @override
  Future<void> load(CorePlayerAudioSource audioSource) {
    // Backward-compat: a single-source load is a single-item queue.
    // `setQueue` hands media_kit's native [Playlist] primitive directly
    // to the player, preserving the single-track contract end-to-end.
    return setQueue(CorePlayerQueue.single(audioSource));
  }

  /// Maps a [CorePlayerAudioSource] into a media_kit [Media]. Network sources
  /// carry their [CorePlayerAudioSource.httpHeaders]; local file sources use
  /// the bare path. Throws [InvalidMediaSourceFailure] when neither field is
  /// set.
  Media _toMedia(CorePlayerAudioSource src) {
    if (src.url != null) {
      return Media(src.url!, httpHeaders: src.httpHeaders);
    } else if (src.filePath != null) {
      return Media(src.filePath!);
    } else {
      _throwAndEmit(const InvalidMediaSourceFailure());
    }
  }

  @override
  CorePlayerQueue get queue => _queueStreamBacking.value;

  @override
  late final ValueStream<CorePlayerQueue> queueStream = _queueStreamBacking.stream;

  @override
  Future<void> setQueue(CorePlayerQueue queue) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    return runOnQueue(() => _setQueueLocked(queue, nextSetQueueToken()));
  }

  /// Body of [setQueue] executed while holding [queueLock]. [token] is the
  /// generation captured at the public entry point; checked after each
  /// `await` so a superseded call abandons its observable writes instead of
  /// overwriting the active caller's state (Faz H bug #1).
  Future<void> _setQueueLocked(CorePlayerQueue queue, int token) async {
    if (_disposed) return;
    _playerErrorSubject.add(null);

    // Mutate the parallel typed-source list FIRST. The playlist stream
    // subscription will then produce the derived CorePlayerQueue once
    // media_kit acknowledges the open. Single source of truth: we never
    // push to `_queueStreamBacking` directly from setQueue (except the
    // explicit empty-queue path below, since stop() does not necessarily
    // emit a playlist index that maps to an empty queue).
    _sources = List.unmodifiable(queue.sources);

    if (queue.isEmpty) {
      _setAudioSource(null);
      await runOnNative(() => player.stop());
      if (token != latestSetQueueToken) return;
      _queueStreamBacking.add(const CorePlayerQueue.empty());
      _durationSubject.add(Duration.zero);
      _positionSubject.add(Duration.zero);
      _bufferSubject.add(Duration.zero);
      _playingSubject.add(false);
      currentAudioHandler?.emitMediaItem(null);
      return;
    }

    final activeSource = queue.current!;
    _setAudioSource(activeSource);

    // Build the media_kit Playlist for the full queue. After this open(),
    // media_kit owns track-to-track transitions: auto-advance, [next],
    // [previous], [jump], and shuffle all go through its native pipeline,
    // which is what gives us gapless playback. The playlist stream
    // subscription mirrors the resulting index into [_queueStreamBacking].
    final medias = queue.sources.map(_toMedia).toList();
    final playlist = Playlist(medias, index: queue.currentIndex);
    await _openWithRetry(playlist);
    if (token != latestSetQueueToken) return;

    needToLoad = false;
    _rateSubject.add(player.state.rate);
    _durationSubject.add(Duration.zero);
    _positionSubject.add(Duration.zero);
    _bufferSubject.add(Duration.zero);
    _playingSubject.add(false);
    currentAudioHandler?.emitMediaItem(_toMediaItem(activeSource));
    CorePlayer.observer?.onLoad(this, activeSource);
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
  bool get shuffle => _shuffleSubject.value;

  @override
  late final ValueStream<bool> shuffleStream = _shuffleSubject.stream;

  @override
  Future<void> setShuffle(bool enabled) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    await runOnNative(() => player.setShuffle(enabled));
    _shuffleSubject.add(enabled);
  }

  /// Open [playable] (a [Media] or [Playlist]) with the retry policy
  /// configured via [CorePlayerConfiguration]. Network/native-open failures
  /// are retried per [LoadRetryConfig]; the final failure surfaces as a
  /// [LoadFailure] both as a thrown exception and on [errorStream].
  Future<void> _openWithRetry(Playable playable) async {
    final retry = CorePlayerMediaKit._configuration.loadRetry;
    var attempt = 0;
    var backoff = retry.initialBackoff;
    while (true) {
      attempt++;
      try {
        await runOnNative(() => player.open(playable, play: false));
        return;
      } on Object catch (e) {
        if (attempt >= retry.maxAttempts) {
          _throwAndEmit(LoadFailure('Failed to load media after $attempt attempts: $e', cause: e));
        }
        await Future<void>.delayed(backoff);
        final nextMillis = (backoff.inMilliseconds * retry.backoffMultiplier).round();
        final next = Duration(milliseconds: nextMillis);
        backoff = next > retry.maxBackoff ? retry.maxBackoff : next;
      }
    }
  }

  @override
  Future<void> play({Duration? position}) async {
    if (_audioSource == null) {
      _throwAndEmit(const MediaItemNotSetFailure());
    }

    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }

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

  @override
  Future<void> loadAndPlay(CorePlayerAudioSource audioSource) {
    if (_disposed) {
      // Match other ops: throw the typed failure rather than returning a
      // rejected Future via async syntax (the abstract method signature is
      // `Future<void>` so a sync throw still surfaces via the Future).
      _throwAndEmit(const PlayerDisposedFailure());
    }
    return runOnQueue(() => _doLoadAndPlay(audioSource, nextSetQueueToken()));
  }

  Future<void> _doLoadAndPlay(CorePlayerAudioSource audioSource, int token) async {
    if (_disposed) return;
    await stop();
    if (token != latestSetQueueToken || _disposed) return;
    // Call _setQueueLocked directly to avoid re-entering queueLock (we
    // already hold it). load() -> setQueue() would deadlock here.
    await _setQueueLocked(CorePlayerQueue.single(audioSource), token);
    if (token != latestSetQueueToken || _disposed) return;
    await play();
  }

  @override
  Future<void> pause() async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
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
    if (position > dur - seekEndThreshold) {
      return;
    }

    if (position < seekStartThreshold) {
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
  Future<void> waitForReady({Duration? timeout}) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (playerState == CorePlayerState.ready) return;

    final future = playerStateStream.firstWhere((s) => s == CorePlayerState.ready || s == CorePlayerState.error);

    final state = timeout != null ? await future.timeout(timeout) : await future;
    if (state == CorePlayerState.error) {
      _throwAndEmit(LoadFailure(_playerErrorSubject.value ?? 'Unknown player error'));
    }
  }

  bool _disposed = false;
  bool _asyncDisposeStarted = false;
  @override
  bool get isDisposed => _disposed;

  /// Flips [_disposed] synchronously so an in-flight constructor
  /// continuation (e.g. [_applyLibmpvOptions] mid-await) or a system-control
  /// event reaction observes disposal and bails before touching the player.
  ///
  /// Mirrors [CoreMediaKitAudioServiceBridge.disposeSync] — callers owning
  /// a player from `State.dispose` should call this before
  /// `unawaited(player.dispose())` so leak_tracker's not-disposed roots
  /// drop the State subtree while the async drain still runs.
  ///
  /// Idempotent. Does NOT release native resources — call [dispose] for
  /// the full teardown.
  void disposeSync() {
    _disposed = true;
  }

  @override
  Future<void> dispose() async {
    // Separate flag from _disposed so a prior disposeSync() does not block
    // the async teardown.
    if (_asyncDisposeStarted) return;
    _asyncDisposeStarted = true;
    // _disposed must flip BEFORE any await so fire-and-forget paths
    // (_applyLibmpvOptions re-checks, event-handler dispatch guard, public
    // mutator throws) observe disposal during the drain that follows.
    _disposed = true;

    // Drain in-flight fire-and-forgets BEFORE cancelling subscriptions or
    // tearing down the native player; errors swallowed because we're on the
    // disposal path.
    if (_pendingOps.isNotEmpty) {
      final pending = _pendingOps.toList(growable: false);
      await Future.wait(
        pending.map((f) => f.catchError((Object _) {})),
        eagerError: false,
      );
    }

    // 1. Cancel ALL StreamSubscriptions first. This breaks the bridge between
    //    native media_kit streams and our local BehaviorSubjects, so anything
    //    stop() / player.dispose() triggers downstream can no longer fan into
    //    soon-to-be-closed subjects.
    await _playbackStateSubscription?.cancel();
    await _audioHandlerEventSubscription?.cancel();
    await _playerStateSubscription?.cancel();
    await _playerErrorSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _bufferSubscription?.cancel();
    await _playingSubscription?.cancel();
    await _rateSubscription?.cancel();
    await _volumeSubscription?.cancel();
    await _playlistSubscription?.cancel();
    await _shuffleSubscription?.cancel();

    // 2. Run stop(fromDispose: true). It writes only to the external
    //    audio_handler streams + native player; our local subjects no longer
    //    bridge, so no risk of writing into a closed subject.
    await stop(fromDispose: true);

    // 3. Close all local BehaviorSubjects so observable streams emit `done`.
    await _rateSubject.close();
    await _volumeSubject.close();
    await _loopModeSubject.close();
    await _queueStreamBacking.close();
    await _audioSourceSubject.close();
    await _shuffleSubject.close();
    await _durationSubject.close();
    await _positionSubject.close();
    await _bufferSubject.close();
    await _playingSubject.close();
    await _playerErrorSubject.close();
    await _playerStateSubject.close();
    await _errorController.close();

    // 4. Notify observer (after local resources are closed; before native
    //    player.dispose() so the callback can still inspect the impl).
    CorePlayer.observer?.onDispose(this);

    // 5. Dispose the native player.
    await runOnNative(() => player.dispose());

    // 6. Detach from the handler last so currentAudioHandler? lookups inside
    //    stop() still resolve correctly above. Detach from OUR scope, not
    //    the default scope (multi-scope correctness).
    await audioHandler?.detach(this);
  }

  ///
  /// Helpers
  ///

  MediaItem _toMediaItem(CorePlayerAudioSource audioSource) {
    return MediaItem(
      id: audioSource.url ?? audioSource.filePath ?? '',
      title: audioSource.title,
      album: audioSource.album,
      artist: audioSource.artist,
      genre: audioSource.genre,
      artUri: audioSource.artUri,
      duration: player.state.duration,
    );
  }

  /// Internal seam: lets the sibling [CoreMediaKitAudioServiceBridge] build a
  /// [MediaItem] from this player when re-emitting the active-scope's
  /// current media to the lock-screen on a scope focus transfer. Not for
  /// app code.
  @internal
  MediaItem toMediaItemForBridge(CorePlayerAudioSource audioSource) => _toMediaItem(audioSource);

  AudioProcessingState _toProcessingState(CorePlayerState state) {
    switch (state) {
      case CorePlayerState.loading:
        return AudioProcessingState.loading;
      case CorePlayerState.ready:
        return AudioProcessingState.ready;
      case CorePlayerState.error:
        return AudioProcessingState.error;
      case CorePlayerState.idle:
        return AudioProcessingState.idle;
      case CorePlayerState.completed:
        return AudioProcessingState.completed;
    }
  }

  PlaybackState _playbackStateValue({
    required Duration position,
    required Duration duration,
    required bool playing,
    required Duration buffer,
    required AudioProcessingState processingState,
  }) {
    final currentItem = currentAudioHandler?.currentMediaItem;
    final lastDuration = currentItem is MediaItem ? currentItem.duration : null;

    if (currentItem is MediaItem && (lastDuration == null || lastDuration != duration)) {
      currentAudioHandler?.emitMediaItem(currentItem.copyWith(duration: duration));
    }
    return PlaybackState(
      controls: [
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        MediaControl.fastForward,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: _systemActions,
      updatePosition: position,
      bufferedPosition: buffer,
      playing: playing,
      processingState: processingState,
    );
  }
}
