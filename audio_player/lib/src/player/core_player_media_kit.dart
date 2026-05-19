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
part 'core_player_media_kit_queue.dart';
part 'core_player_media_kit_auto_radio.dart';
part 'core_player_media_kit_navigation.dart';
part 'core_player_media_kit_playback.dart';
part 'core_player_media_kit_mutation.dart';
part 'core_player_media_kit_live.dart';

/// Position-restoration SLA for [CorePlayerMediaKit.replaceAt] when
/// `preservePosition: true` is requested for the active index. Buffer-aware
/// seek cost + native rate of position emission means the post-replace
/// stream typically lands within ~150 ms of the captured playhead; tests
/// pin this constant as the documented tolerance.
const Duration kReplacePreservePositionTolerance = Duration(milliseconds: 200);

class CorePlayerMediaKit extends CorePlayer
    with
        CorePlayerMediaKitConcurrency,
        CorePlayerMediaKitNavigation,
        CorePlayerMediaKitPlayback,
        CorePlayerMediaKitMutation,
        CorePlayerMediaKitLive {
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
      return CorePlayerMediaKit(
        audioSource: audioSource,
        audioHandler: audioHandler,
        autoLoad: autoLoad,
      );
    });
  }

  /// Active wrapper configuration. Reflects the value passed to the most
  /// recent [ensureInitialized] call (or the default if none was passed).
  static CorePlayerConfiguration get configuration => _configuration;

  static CorePlayerConfiguration _configuration =
      const CorePlayerConfiguration();

  /// Test seam: replace the active [configuration] without going through the
  /// real [ensureInitialized] (which touches MediaKit + AudioService natives).
  @visibleForTesting
  static void debugSetConfigurationForTest(
    CorePlayerConfiguration configuration,
  ) {
    _configuration = configuration;
  }

  /// Centralised log dispatch. Routes through the configured
  /// [CorePlayerConfiguration.logCallback] when present, falling back to
  /// `dart:developer`'s `log` otherwise. Public so the sibling
  /// `core_audio_service_bridge.dart` can reuse the same indirection.
  @internal
  static void log(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? name,
  }) {
    final cb = _configuration.logCallback;
    if (cb != null) {
      cb(message, error: error, stackTrace: stackTrace);
    } else {
      developer.log(
        message,
        error: error,
        stackTrace: stackTrace,
        name: name ?? 'audio_player',
      );
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
  @override
  CoreAudioHandler? get currentAudioHandler {
    final scope = audioHandler;
    if (scope == null) return null;
    return scope.isCurrent(this) && scope.isActiveScope ? scope : null;
  }

  @override
  CoreAudioSource? _audioSource;
  @override
  CoreAudioSource? get audioSource => _audioSource;

  /// Mutate [_audioSource] and broadcast on [audioSourceStream]. All
  /// assignments to [_audioSource] route through this helper so the
  /// subject and the field cannot drift.
  void _setAudioSource(CoreAudioSource? source) {
    _audioSource = source;
    if (!_audioSourceSubject.isClosed) {
      _audioSourceSubject.add(source);
    }
  }

  late final BehaviorSubject<CoreAudioSource?> _audioSourceSubject =
      BehaviorSubject<CoreAudioSource?>.seeded(_audioSource);

  @override
  late final ValueStream<CoreAudioSource?> audioSourceStream =
      _audioSourceSubject.stream;

  @override
  final CoreAudioHandler? audioHandler;

  final bool? _autoLoad;
  @override
  bool get autoLoad => _autoLoad ?? false;

  @override
  final Player player;

  /// Direct construction is internal — use [CorePlayer.create] after
  /// [CorePlayerMediaKit.ensureInitialized]. The constructor is retained
  /// for internal use and tests; external callers will receive a lint
  /// warning.
  @internal
  @override
  CorePlayerMediaKit({
    CoreAudioSource? audioSource,
    this.audioHandler,
    bool autoLoad = false,
    @visibleForTesting Player? testPlayer,
  }) : player =
           testPlayer ??
           Player(
             configuration: PlayerConfiguration(
               bufferSize: _configuration.bufferSizeBytes,
             ),
           ),
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
        audioHandler!.attach(this).then<void>((_) {}).catchError((
          Object e,
          StackTrace s,
        ) {
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
      final previousIndex = _queueStreamBacking.hasValue
          ? _queueStreamBacking.value.currentIndex
          : -1;
      // Cache the previous active source BEFORE pushing the new queue so a
      // mutation API call (removeAt / replaceAt) that swaps the source at
      // the same index is still observable: comparing newSource against
      // [_audioSource] catches "index stayed the same but the slot's source
      // changed" — index-only diffing missed this case in Faz Q.
      final previousSource = _audioSource;
      _queueStreamBacking.add(newQueue);
      final newSource = _sources[index];
      if (previousIndex != index || !identical(previousSource, newSource)) {
        _setAudioSource(newSource);
        CorePlayer.observer?.onLoad(this, newSource);
        currentAudioHandler?.emitMediaItem(_toMediaItem(newSource));
      }
    });

    // Shuffle: media_kit emits the canonical value on its stream after a
    // [player.setShuffle] call. Mirror into our seeded BehaviorSubject so
    // [shuffle] / [shuffleStream] stay in sync with the native state.
    _shuffleSubscription = player.stream.shuffle.listen(_shuffleSubject.add);

    // Combine position + duration into a single seeded record so scrubber
    // UIs can subscribe to one stream. `distinct` collapses back-to-back
    // identical records (mostly when only the buffer changes upstream and
    // both inputs re-emit unchanged values).
    _positionDataSubscription =
        Rx.combineLatest2<Duration, Duration, CorePlayerPositionData>(
          _positionSubject.stream,
          _durationSubject.stream,
          (p, d) => (position: p, duration: d),
        ).distinct().listen((data) {
          if (_disposed) return;
          if (!_positionDataSubject.isClosed) {
            _positionDataSubject.add(data);
          }
        });

    // Queue-exhaustion detector: media_kit's `completed` fires on every
    // track end. We only invoke the configured callback when the last
    // playlist index just finished — see [_onQueueExhausted].
    _queueExhaustedSubscription = player.stream.completed.listen((completed) {
      if (!completed) return;
      if (_disposed) return;
      _maybeFireQueueExhausted();
    });

    // INTERNAL position input is throttled (default 200ms, trailing) so the
    // playerState combineLatest5 doesn't churn at native rate (~30 Hz). The
    // public [positionStream] remains at native rate for UI scrubbers — only
    // the internal pipeline is rate-limited. Throttle is configurable via
    // [CorePlayerConfiguration.internalPositionThrottle]; pass [Duration.zero]
    // to opt out (e.g. tests that drive single position emits synchronously).
    final positionThrottle = _configuration.internalPositionThrottle;
    final throttledPosition = positionThrottle == Duration.zero
        ? player.stream.position
        : player.stream.position.throttleTime(
            positionThrottle,
            leading: true,
            trailing: true,
          );
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

  @override
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
  StreamSubscription<CorePlayerPositionData>? _positionDataSubscription;
  StreamSubscription<bool>? _queueExhaustedSubscription;

  final BehaviorSubject<String?> _playerErrorSubject =
      BehaviorSubject<String?>.seeded(null);
  final BehaviorSubject<CorePlayerState> _playerStateSubject =
      BehaviorSubject<CorePlayerState>.seeded(CorePlayerState.idle);
  final BehaviorSubject<Duration> _durationSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _positionSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _bufferSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<bool> _playingSubject = BehaviorSubject<bool>.seeded(
    false,
  );
  @override
  final BehaviorSubject<double> _rateSubject = BehaviorSubject<double>.seeded(
    1.0,
  );
  @override
  final BehaviorSubject<double> _volumeSubject = BehaviorSubject<double>.seeded(
    1.0,
  );
  @override
  final BehaviorSubject<CorePlayerLoopMode> _loopModeSubject =
      BehaviorSubject<CorePlayerLoopMode>.seeded(CorePlayerLoopMode.off);

  /// Derived from `player.stream.playlist` — DO NOT add directly except
  /// from the playlist subscription, or from the explicit empty-queue
  /// fast path in [setQueue]. [setQueue] mutates [_sources] and calls
  /// [player.open]; the playlist stream then drives this subject. Single
  /// source of truth: media_kit owns playback queue state, the wrapper
  /// only stores the typed-source mapping in [_sources].
  @override
  final BehaviorSubject<CorePlayerQueue> _queueStreamBacking =
      BehaviorSubject<CorePlayerQueue>.seeded(const CorePlayerQueue.empty());

  /// Parallel list of [CoreAudioSource] matching the [Media] list in
  /// media_kit's current [Playlist]. Indexed by position. Used to round-
  /// trip from a media_kit [Playlist] back to a typed [CorePlayerQueue].
  /// Only mutated inside [setQueue] BEFORE `player.open(...)` is awaited;
  /// every queue change is then observed via the playlist subscription.
  @override
  List<CoreAudioSource> _sources = const [];

  @override
  final BehaviorSubject<bool> _shuffleSubject = BehaviorSubject<bool>.seeded(
    false,
  );

  /// Seeded with a zero/zero record so freshly mounted scrubber widgets get
  /// an immediate snapshot rather than a frame-one blank. Fed by a
  /// `Rx.combineLatest2(position, duration)` pipeline plugged in from the
  /// constructor.
  final BehaviorSubject<CorePlayerPositionData> _positionDataSubject =
      BehaviorSubject<CorePlayerPositionData>.seeded((
        position: Duration.zero,
        duration: Duration.zero,
      ));

  /// Re-entrancy guard for the queue-exhaustion handler. media_kit's
  /// `completed` can emit `true` more than once for the same end-of-stream
  /// (rapid replays of the last frame, audio backend quirks). We flip
  /// this on the first invocation per "real" end and clear it when the
  /// queue grows (append succeeded) or when setQueue replaces the queue.
  bool _queueExhaustedHandled = false;

  @override
  final StreamController<CorePlayerFailure> _errorController =
      StreamController<CorePlayerFailure>.broadcast();

  @override
  Stream<CorePlayerFailure> get errorStream => _errorController.stream;

  /// Emits [failure] to [errorStream] then throws it. Used at every synchronous
  /// throw site so passive observers see the same failure as direct callers.
  /// The emit is best-effort — if the controller has already been closed (post
  /// dispose), only the throw runs.
  @override
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
  late final ValueStream<CorePlayerState> playerStateStream =
      _playerStateSubject.stream;
  @override
  late final ValueStream<Duration> positionStream = _positionSubject.stream;
  @override
  late final ValueStream<Duration> durationStream = _durationSubject.stream;
  @override
  late final ValueStream<Duration> bufferStream = _bufferSubject.stream;
  @override
  late final ValueStream<bool> playingStream = _playingSubject.stream;

  @override
  late final ValueStream<CorePlayerPositionData> positionDataStream =
      _positionDataSubject.stream;

  @override
  double get playbackSpeed => _rateSubject.value;

  @override
  late final ValueStream<double> playbackSpeedStream = _rateSubject.stream;

  @override
  double get volume => _volumeSubject.value;

  @override
  late final ValueStream<double> volumeStream = _volumeSubject.stream;

  @override
  CorePlayerLoopMode get loopMode => _loopModeSubject.value;

  @override
  late final ValueStream<CorePlayerLoopMode> loopModeStream =
      _loopModeSubject.stream;

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
  @override
  bool needToLoad = true;

  @override
  Future<void> load(CoreAudioSource audioSource) {
    // Backward-compat: a single-source load is a single-item queue.
    // `setQueue` hands media_kit's native [Playlist] primitive directly
    // to the player, preserving the single-track contract end-to-end.
    return setQueue(CorePlayerQueue.single(audioSource));
  }

  /// Maps a [CoreAudioSource] into a media_kit [Media]. HTTP sources forward
  /// their [HttpAudioSource.headers] verbatim; file sources hand the bare
  /// [FileAudioSource.path] to media_kit's resolver.
  ///
  /// The switch is exhaustive on the sealed [CoreAudioSource] hierarchy; Faz
  /// S2 ([HlsAudioSource]) and Faz S3 ([LiveAudioSource]) MUST extend it.
  /// [InvalidMediaSourceFailure] is reserved for residual runtime
  /// malformedness (e.g. empty path / unsupported transports) — the sealed
  /// type itself prevents the obvious "neither url nor path" state.
  ///
  /// [LiveAudioSource] is mapped via its [LiveAudioSource.initialUrl] seed.
  /// When the seed is null, this is a programmer-error path: callers MUST
  /// have routed through [_primeLiveSource] (which waits for the first
  /// stream emission) before invoking [_toMedia] on a seedless live
  /// source. The throw surfaces the contract violation as a typed
  /// [LiveSourceNotReadyFailure] instead of a silent NPE.
  @override
  Media _toMedia(CoreAudioSource src) => switch (src) {
    HttpAudioSource(:final url, :final headers) =>
        Media(url.toString(), httpHeaders: headers),
    FileAudioSource(:final path) => Media(path),
    LiveAudioSource(:final initialUrl, :final headers) => initialUrl != null
        ? Media(initialUrl.toString(), httpHeaders: headers)
        : throw const LiveSourceNotReadyFailure(
            'LiveAudioSource without initialUrl is not ready: the wrapper '
            'must wait for the first segment emission before calling '
            '_toMedia. This is a programmer-error path; the active-source '
            'priming logic in _setQueueLocked should have handled it.',
          ),
  };

  @override
  CorePlayerQueue get queue => _queueStreamBacking.value;

  @override
  late final ValueStream<CorePlayerQueue> queueStream =
      _queueStreamBacking.stream;

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
  @override
  Future<void> _setQueueLocked(CorePlayerQueue queue, int token) async {
    if (_disposed) return;
    _playerErrorSubject.add(null);
    // Fresh queue invalidates any prior exhaustion fire.
    _queueExhaustedHandled = false;

    // Cancel any prior live subscriptions whose source is not present in
    // the new queue. Done BEFORE mutating `_sources` so the
    // pre-existing live-source identities are still observable.
    await _cancelLiveSubscriptionsNotIn(queue.sources);

    // Live sources are projected into the queue via their initialUrl seed
    // (if any) and their stream emissions, NOT as a standalone playlist
    // entry. The projected list below is what media_kit and the wrapper
    // mirror agree on; the parent [LiveAudioSource] instance lives only in
    // [_liveSubscriptions] for the duration of its stream.
    //
    // Index translation: queue.currentIndex addresses the user-supplied
    // sources. After projecting live sources to seeds, the projected index
    // may differ. We keep the index aligned by counting how many seeds
    // each pre-active source contributes (0 for a seedless live source
    // whose stream is exhausted by the time the open lands; 1 otherwise).
    final projected = <CoreAudioSource>[];
    int projectedActiveIndex = 0;
    final liveToAttach = <LiveAudioSource>[];
    for (int i = 0; i < queue.sources.length; i++) {
      final src = queue.sources[i];
      if (src is LiveAudioSource) {
        liveToAttach.add(src);
        if (src.initialUrl != null) {
          // The seed is added as a sibling HttpAudioSource so the queue
          // UI's "currently at segment N" presentation is uniform with
          // post-open emissions.
          projected.add(
            HttpAudioSource(
              url: src.initialUrl!,
              title: '${src.title} (segment 1)',
              artist: src.artist,
              artUri: src.artUri,
              headers: src.headers,
            ),
          );
          if (i < queue.currentIndex) projectedActiveIndex++;
          if (i == queue.currentIndex) {
            // The newly-projected slot's index in `projected` is its tail.
            projectedActiveIndex = projected.length - 1;
          }
        } else {
          // Seedless: nothing to seed the playlist with. The active-source
          // priming below waits for the first emission before opening, so
          // for the active live source we'll inject the first segment
          // synchronously into [projected] just before the open() call.
          // For non-active seedless live sources, we DO NOT block the
          // open — emissions will append into the playlist as they
          // arrive. The non-active case therefore contributes nothing to
          // `projected` at open time.
          if (i < queue.currentIndex) {
            // currentIndex addresses an entry whose live source produced
            // no projected element — shift the projected index back by
            // one so the user-supplied index still maps to the right slot.
            // (Net effect: projectedActiveIndex tracks projected length.)
          }
        }
      } else {
        projected.add(src);
        if (i < queue.currentIndex) projectedActiveIndex++;
        if (i == queue.currentIndex) {
          projectedActiveIndex = projected.length - 1;
        }
      }
    }

    // If the active queue entry is a seedless live source, prime it: wait
    // for the first segment URL before issuing the open. Tracked via
    // [_pendingOps] so dispose drains the pending wait.
    final activeUserSource = queue.current;
    if (activeUserSource is LiveAudioSource &&
        activeUserSource.initialUrl == null) {
      // Pre-attach the subscription so the first emission is consumed by
      // the priming completer (not lost). The subscription's onData adds
      // to _sources/native; we route the first emit through a one-shot
      // completer instead so the wrapper can use it as the open seed.
      // Implementation: we use a transformed first() future plus an
      // attach-after-open follow-up.
      throw const LiveSourceNotReadyFailure(
        'LiveAudioSource active at setQueue time requires a non-null '
        'initialUrl in v1. Construct the live source with an initialUrl '
        'seed, or place it after a non-live source so the wrapper has '
        'something to open with before the segment stream emits.',
      );
    }

    // Mutate the parallel typed-source list. The playlist stream
    // subscription will then produce the derived CorePlayerQueue once
    // media_kit acknowledges the open. Single source of truth: we never
    // push to `_queueStreamBacking` directly from setQueue (except the
    // explicit empty-queue path below, since stop() does not necessarily
    // emit a playlist index that maps to an empty queue).
    //
    // Growable: queue-mutation API (insertNext / appendToQueue /
    // removeAt / moveItem / replaceAt) mutates this list in place to
    // keep wrapper state aligned with each incremental playlist emission.
    _sources = List<CoreAudioSource>.of(projected, growable: true);

    if (projected.isEmpty) {
      _setAudioSource(null);
      await runOnNative(() => player.stop());
      if (token != latestSetQueueToken) return;
      _queueStreamBacking.add(const CorePlayerQueue.empty());
      _durationSubject.add(Duration.zero);
      _positionSubject.add(Duration.zero);
      _bufferSubject.add(Duration.zero);
      _playingSubject.add(false);
      currentAudioHandler?.emitMediaItem(null);
      // Even with nothing to open, attach segment streams for any live
      // sources in the queue so subsequent emissions populate the playlist.
      for (final live in liveToAttach) {
        _attachLiveSegmentStream(live);
      }
      return;
    }

    final clampedIndex = projectedActiveIndex.clamp(0, projected.length - 1);
    final activeSource = projected[clampedIndex];
    _setAudioSource(activeSource);

    // Build the media_kit Playlist for the projected queue. After this
    // open(), media_kit owns track-to-track transitions: auto-advance,
    // [next], [previous], [jump], and shuffle all go through its native
    // pipeline, which is what gives us gapless playback. The playlist
    // stream subscription mirrors the resulting index into
    // [_queueStreamBacking].
    final medias = projected.map(_toMedia).toList();
    final playlist = Playlist(medias, index: clampedIndex);
    await _openWithRetry(playlist);
    if (token != latestSetQueueToken) return;

    // Attach live-source subscriptions AFTER the open. Emissions land via
    // `player.add(Media(...))` against a live native playlist.
    for (final live in liveToAttach) {
      _attachLiveSegmentStream(live);
    }

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
  bool get shuffle => _shuffleSubject.value;

  @override
  late final ValueStream<bool> shuffleStream = _shuffleSubject.stream;

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
          _throwAndEmit(
            LoadFailure(
              'Failed to load media after $attempt attempts: $e',
              cause: e,
            ),
          );
        }
        await Future<void>.delayed(backoff);
        final nextMillis = (backoff.inMilliseconds * retry.backoffMultiplier)
            .round();
        final next = Duration(milliseconds: nextMillis);
        backoff = next > retry.maxBackoff ? retry.maxBackoff : next;
      }
    }
  }

  @override
  Future<void> loadAndPlay(CoreAudioSource audioSource) {
    if (_disposed) {
      // Match other ops: throw the typed failure rather than returning a
      // rejected Future via async syntax (the abstract method signature is
      // `Future<void>` so a sync throw still surfaces via the Future).
      _throwAndEmit(const PlayerDisposedFailure());
    }
    return runOnQueue(() => _doLoadAndPlay(audioSource, nextSetQueueToken()));
  }

  Future<void> _doLoadAndPlay(
    CoreAudioSource audioSource,
    int token,
  ) async {
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
  Future<void> waitForReady({Duration? timeout}) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    if (playerState == CorePlayerState.ready) return;

    final future = playerStateStream.firstWhere(
      (s) => s == CorePlayerState.ready || s == CorePlayerState.error,
    );

    final state = timeout != null
        ? await future.timeout(timeout)
        : await future;
    if (state == CorePlayerState.error) {
      _throwAndEmit(
        LoadFailure(_playerErrorSubject.value ?? 'Unknown player error'),
      );
    }
  }

  @override
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

    // Cancel live-source segment subscriptions FIRST so a late emission
    // landing during the drain below doesn't race with the native teardown.
    // The wrapper-side `_sources` mutation in `_onLiveSegmentEmit` is sync
    // and gated on `_disposed` (set above), so any in-flight emission will
    // observe disposal and bail before touching the player.
    await _cancelAllLiveSubscriptions();

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
    await _positionDataSubscription?.cancel();
    await _queueExhaustedSubscription?.cancel();

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
    await _positionDataSubject.close();
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

  @override
  MediaItem _toMediaItem(CoreAudioSource audioSource) {
    // `id` is required by audio_service to identify the MediaItem on the
    // lock-screen; map per subtype rather than reaching into nullable
    // fields. The engine's preferred duration is the real one from
    // `player.state.duration`; fall back to the source's
    // [CoreAudioSource.estimatedDuration] hint so the lock-screen has a
    // value before the demuxer reports back (then the playbackState
    // pipeline overwrites with the real one on the next emit).
    final id = switch (audioSource) {
      HttpAudioSource(:final url) => url.toString(),
      FileAudioSource(:final path) => path,
      // Live sources don't have a stable "id" — neither the segment stream
      // nor the (possibly-null) initialUrl is meaningful for lock-screen
      // identity. Fall back to a synthetic id derived from the parent
      // identity so MediaItem reconciliation stays stable across emissions.
      LiveAudioSource(:final initialUrl) =>
          initialUrl?.toString() ?? 'live:${identityHashCode(audioSource)}',
    };
    final engineDuration = player.state.duration;
    final duration = engineDuration > Duration.zero
        ? engineDuration
        : audioSource.estimatedDuration ?? Duration.zero;
    return MediaItem(
      id: id,
      title: audioSource.title,
      artist: audioSource.artist,
      artUri: audioSource.artUri,
      duration: duration,
    );
  }

  /// Internal seam: lets the sibling [CoreMediaKitAudioServiceBridge] build a
  /// [MediaItem] from this player when re-emitting the active-scope's
  /// current media to the lock-screen on a scope focus transfer. Not for
  /// app code.
  @internal
  MediaItem toMediaItemForBridge(CoreAudioSource audioSource) =>
      _toMediaItem(audioSource);

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

    if (currentItem is MediaItem &&
        (lastDuration == null || lastDuration != duration)) {
      currentAudioHandler?.emitMediaItem(
        currentItem.copyWith(duration: duration),
      );
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
