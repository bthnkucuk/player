// This file is the legitimate platform-bridge consumer of
// `CoreAudioHandler.postEvent` (marked `@internal` on the abstraction). The
// invalid_use_of_internal_member lint is suppressed file-wide because the
// bridge is intentionally part of the player_workspace suite's internal surface,
// even though it lives in a sibling package.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_player_media_kit.dart';

/// Platform-side implementation of [CoreAudioServiceBridge] for `media_kit`.
///
/// Extends [BaseAudioHandler] so it can be registered with
/// `AudioService.init` and own the `PlaybackState` / `MediaItem`
/// BehaviorSubjects that show up in the system notification / lock screen.
///
/// All system control invocations (`play`, `pause`, `stop`, `seek`,
/// `fastForward`, `rewind`, `onTaskRemoved`) are forwarded into the
/// registry-side [CoreAudioHandler.eventStream] (via [CoreAudioHandler.postEvent])
/// so the active [CorePlayer] instance can react.
class CoreMediaKitAudioServiceBridge extends BaseAudioHandler
    with SeekHandler
    implements CoreAudioServiceBridge {
  /// The handler scope this bridge was bound to in [initialize] — i.e. the
  /// default scope. Retained for back-compat ([onTaskRemoved] still routes
  /// here for symmetry with pre-Phase-13 single-scope behavior). All other
  /// system events (play/pause/interruption/...) target
  /// [CoreAudioHandler.activeScope] so multi-scope apps can transfer the OS
  /// surface via [CoreAudioHandler.requestSystemAudioFocus].
  CoreAudioHandler? _handler;
  AudioSession? _audioSession;

  /// Resolve which scope receives the next system event. Prefers
  /// [CoreAudioHandler.activeScope] (the scope that owns the OS surface);
  /// falls back to the bridge-bound [_handler] for tests or pre-init paths.
  CoreAudioHandler? get _eventTarget =>
      CoreAudioHandler.activeScope ?? _handler;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;
  AppLifecycleListener? _appLifecycle;

  /// Tracks whether playback was active when an interruption began. Reset
  /// after interruption-end is delivered to the impl.
  bool _interruptedWhilePlaying = false;

  /// Gates idempotent activation. The OS implicitly deactivates AVAudioSession
  /// during certain interruptions; we reset this flag in those cases so the
  /// next [activateSession] actually re-`setActive(true)`s instead of being a
  /// no-op.
  bool _hasUserActivatedSession = false;

  /// Set synchronously by [disposeSync]; flips before any await in [dispose]
  /// so a still-in-flight [initialize] (e.g. stage 3 listener attach) can
  /// short-circuit instead of allocating fresh listeners after the field was
  /// already nulled.
  bool _disposedSync = false;

  @visibleForTesting
  AudioSession? get debugAudioSession => _audioSession;

  @visibleForTesting
  set debugAudioSession(AudioSession? value) => _audioSession = value;

  @visibleForTesting
  AppLifecycleListener? get debugLifecycleListener => _appLifecycle;

  @visibleForTesting
  bool get debugDisposedSync => _disposedSync;

  @visibleForTesting
  bool get debugHasUserActivatedSession => _hasUserActivatedSession;

  @visibleForTesting
  bool get debugInterruptedWhilePlaying => _interruptedWhilePlaying;

  /// Testing seam: wire a [CoreAudioHandler] without running the real
  /// [initialize] flow (which touches `AudioService.init`).
  @visibleForTesting
  void debugAttachHandler(CoreAudioHandler handler) {
    _handler = handler;
  }

  @override
  Future<void> initialize(CoreAudioHandler handler) async {
    _handler = handler;
    CorePlayerMediaKit.log(
      'Bridge.initialize: starting',
      name: 'CoreMediaKitAudioServiceBridge',
    );

    // Stage 1 — AudioService.init. The native side does a method-channel
    // round-trip and configures the foreground service; tolerate failures so
    // a degraded device (no notification permission, etc.) doesn't block the
    // rest of bootstrap.
    final cfg = CorePlayerMediaKit.configuration;
    try {
      await AudioService.init<CoreMediaKitAudioServiceBridge>(
        builder: () => this,
        config: AudioServiceConfig(
          androidResumeOnClick: cfg.androidResumeOnClick,
          androidNotificationOngoing: cfg.androidNotificationOngoing,
          androidStopForegroundOnPause: cfg.androidStopForegroundOnPause,
          androidNotificationChannelId: cfg.androidNotificationChannelId,
          androidNotificationChannelName:
              cfg.androidNotificationChannelName ?? 'Notifications',
          androidNotificationIcon: cfg.androidNotificationIcon,
        ),
      ).timeout(const Duration(seconds: 15));
      CorePlayerMediaKit.log(
        'Bridge.initialize: AudioService.init OK',
        name: 'CoreMediaKitAudioServiceBridge',
      );
    } catch (e, s) {
      CorePlayerMediaKit.log(
        '[audio_player] AudioService.init failed; continuing',
        error: e,
        stackTrace: s,
        name: 'CoreMediaKitAudioServiceBridge',
      );
    }

    if (_disposedSync) return;

    // Stage 2 — AudioSession.instance + configure(). Independent from stage 1.
    // Even if stage 1 failed we still want interruption / becoming-noisy
    // listeners working.
    AudioSession? session;
    try {
      session = await AudioSession.instance.timeout(
        const Duration(seconds: 15),
      );
      // Explicit AudioSessionConfiguration mirroring example_speech_app's known-working
      // setup (apps/example_speech_app/lib/core/audio_service/audio_handler/mixins/
      // audio_session_mixin.dart). The previously-used `.music()` preset
      // apparently let iOS/Android keep treating us as "ambient/mixable" —
      // the prior MediaController owner (YouTube/Spotify) was never displaced
      // from the lock-screen even after we published a MediaItem. Explicit
      // `playback` category + `longFormAudio` route policy + `gain` focus
      // forces a real focus claim.
      //
      // One deliberate divergence from example_speech_app: `androidAudioAttributes
      // .contentType` is `music` here instead of `speech`.player is a
      // general audio wrapper (music, podcasts, audiobooks), not the
      // TTS-centric example_speech_app use case.
      await session
          .configure(
            const AudioSessionConfiguration(
              avAudioSessionCategory: AVAudioSessionCategory.playback,
              avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
              avAudioSessionMode: AVAudioSessionMode.defaultMode,
              avAudioSessionRouteSharingPolicy:
                  AVAudioSessionRouteSharingPolicy.longFormAudio,
              avAudioSessionSetActiveOptions:
                  AVAudioSessionSetActiveOptions.none,
              androidAudioAttributes: AndroidAudioAttributes(
                contentType: AndroidAudioContentType.music,
                flags: AndroidAudioFlags.none,
                usage: AndroidAudioUsage.media,
              ),
              androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
              androidWillPauseWhenDucked: true,
            ),
          )
          .timeout(const Duration(seconds: 15));
      _audioSession = session;
      CorePlayerMediaKit.log(
        'Bridge.initialize: AudioSession configured (category=playback, mode=defaultMode, routePolicy=longFormAudio)',
        name: 'CoreMediaKitAudioServiceBridge',
      );
    } catch (e, s) {
      CorePlayerMediaKit.log(
        '[audio_player] AudioSession acquire/configure failed',
        error: e,
        stackTrace: s,
        name: 'CoreMediaKitAudioServiceBridge',
      );
      session = null;
    }
    // NOTE: we intentionally do NOT call `setActive(true)` here. Activation is
    // deferred to the first [CoreAudioHandler.attachPlayer] so we don't disturb
    // other audio apps while our player has nothing loaded.

    if (_disposedSync) return;

    // Seed initial PlaybackState so audio_service's Android plugin binds the
    // system MediaSession to this handler before any user interaction.
    //
    // audio_service binds the platform MediaSession to whichever handler
    // publishes a non-NONE PlaybackState first. BaseAudioHandler's default
    // `PlaybackState()` is treated as State.NONE — if we leave it empty, the
    // system keeps the previously-bound MediaController (e.g. YouTube) on the
    // lock-screen / Now Playing widget, and our MediaItem never replaces it
    // even after the user presses play in our app.
    //
    // Seeding `processingState: idle` + a populated `queueIndex` here mirrors
    // example_speech_app's `BehaviorSubject.seeded(PlaybackState(queueIndex: 0))` and
    // resolves the symptom on cold start. The first real playback emission
    // from CorePlayerMediaKit's stream will overwrite this immediately.
    playbackState.add(
      PlaybackState(
        controls: const [MediaControl.play],
        systemActions: const {MediaAction.play},
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        queueIndex: 0,
      ),
    );
    CorePlayerMediaKit.log(
      'Bridge.initialize: seed PlaybackState emitted (idle, queueIndex=0)',
      name: 'CoreMediaKitAudioServiceBridge',
    );

    // Stage 3 — listener attachment. Only meaningful if stage 2 succeeded.
    if (session != null) {
      try {
        _interruptionSub = session.interruptionEventStream.listen(
          _onInterruption,
        );
        _noisySub = session.becomingNoisyEventStream.listen(
          (_) => _onBecomingNoisy(),
        );
        if (_disposedSync) {
          await _interruptionSub?.cancel();
          await _noisySub?.cancel();
          _interruptionSub = null;
          _noisySub = null;
          return;
        }
        // AppLifecycleListener construction may fail in environments without
        // a WidgetsBinding (rare in production but possible in some test
        // harnesses). Tolerate it.
        try {
          final listener = AppLifecycleListener(onResume: _onAppResumed);
          if (_disposedSync) {
            listener.dispose();
          } else {
            _appLifecycle = listener;
            CorePlayerMediaKit.log(
              'Bridge.initialize: interruption + becomingNoisy + appLifecycle listeners attached',
              name: 'CoreMediaKitAudioServiceBridge',
            );
          }
        } catch (e, s) {
          CorePlayerMediaKit.log(
            '[audio_player] AppLifecycleListener attach failed',
            error: e,
            stackTrace: s,
            name: 'CoreMediaKitAudioServiceBridge',
          );
        }
      } catch (e, s) {
        CorePlayerMediaKit.log(
          '[audio_player] session listener attach failed',
          error: e,
          stackTrace: s,
          name: 'CoreMediaKitAudioServiceBridge',
        );
      }
    }
  }

  @override
  Future<void> activateSession() async {
    CorePlayerMediaKit.log(
      'Bridge.activateSession: called, _hasUserActivatedSession=$_hasUserActivatedSession',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    if (_hasUserActivatedSession) return;
    if (_audioSession == null) return;
    try {
      await _audioSession!.setActive(true, androidWillPauseWhenDucked: true);
      _hasUserActivatedSession = true;
      CorePlayerMediaKit.log(
        'Bridge.activateSession: setActive(true) succeeded',
        name: 'CoreMediaKitAudioServiceBridge',
      );
    } catch (e, s) {
      CorePlayerMediaKit.log(
        'Bridge.activateSession: setActive failed: $e',
        error: e,
        stackTrace: s,
        name: 'CoreMediaKitAudioServiceBridge',
      );
      rethrow;
    }
  }

  @override
  Future<void> deactivateSession() async {
    CorePlayerMediaKit.log(
      'Bridge.deactivateSession: called',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    await _audioSession?.setActive(
      false,
      avAudioSessionSetActiveOptions:
          AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
    );
    _hasUserActivatedSession = false;
    CorePlayerMediaKit.log(
      'Bridge.deactivateSession: setActive(false, notifyOthers) succeeded',
      name: 'CoreMediaKitAudioServiceBridge',
    );
  }

  /// Synchronous part of dispose. Must run before any await in [dispose] —
  /// detaches the [AppLifecycleListener] and flips [_disposedSync] so any
  /// still-in-flight [initialize] stage short-circuits.
  @visibleForTesting
  void disposeSync() {
    if (_disposedSync) return;
    _disposedSync = true;
    _appLifecycle?.dispose();
    _appLifecycle = null;
  }

  /// Tear down session listeners. Idempotent. Safe to call after [disposeSync].
  Future<void> dispose() async {
    disposeSync();
    final i = _interruptionSub;
    _interruptionSub = null;
    final n = _noisySub;
    _noisySub = null;
    await i?.cancel();
    await n?.cancel();
  }

  // ---- Interruption / lifecycle plumbing ---------------------------------

  void _onInterruption(AudioInterruptionEvent event) {
    CorePlayerMediaKit.log(
      'Bridge._onInterruption: begin=${event.begin} type=${event.type}',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    final handler = _eventTarget;
    if (handler == null) return;
    if (event.begin) {
      final wasPlaying = playbackState.value.playing;
      if (wasPlaying) {
        _interruptedWhilePlaying = true;
      }
      // iOS effectively deactivates AVAudioSession during the interruption;
      // reset our flag so a later resume actually re-calls setActive(true).
      _hasUserActivatedSession = false;
      handler.postEvent(
        CoreAudioHandlerInterruptionBeginEvent(
          _mapInterruptionType(event.type),
        ),
      );
    } else {
      final shouldResume =
          event.type == AudioInterruptionType.pause && _interruptedWhilePlaying;
      _interruptedWhilePlaying = false;
      handler.postEvent(
        CoreAudioHandlerInterruptionEndEvent(shouldResume: shouldResume),
      );
    }
  }

  void _onBecomingNoisy() {
    CorePlayerMediaKit.log(
      'Bridge._onBecomingNoisy: headphones unplugged',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    _eventTarget?.postEvent(CoreAudioHandlerBecomingNoisyEvent());
  }

  void _onAppResumed() {
    CorePlayerMediaKit.log(
      'Bridge._onAppResumed: app foregrounded, _interruptedWhilePlaying=$_interruptedWhilePlaying',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    final handler = _eventTarget;
    if (handler == null) return;
    if (_interruptedWhilePlaying) {
      // iOS apps like Instagram Reels / TikTok frequently fail to fire a
      // compliant interruption-end on foreground return. Synthesize the
      // resume-end event so the active CorePlayer (which already handles
      // InterruptionEnd) can recover playback without a dedicated AppResume
      // recovery path in every impl.
      _interruptedWhilePlaying = false;
      handler.postEvent(
        CoreAudioHandlerInterruptionEndEvent(shouldResume: true),
      );
      return;
    }
    handler.postEvent(CoreAudioHandlerAppResumeEvent());
  }

  /// Test seam: drive [_interruptedWhilePlaying] without faking a full
  /// interruption-begin pipeline.
  @visibleForTesting
  set debugInterruptedWhilePlaying(bool value) {
    _interruptedWhilePlaying = value;
  }

  CoreAudioInterruptionType _mapInterruptionType(AudioInterruptionType type) {
    switch (type) {
      case AudioInterruptionType.pause:
        return CoreAudioInterruptionType.pause;
      case AudioInterruptionType.duck:
        return CoreAudioInterruptionType.duck;
      case AudioInterruptionType.unknown:
        return CoreAudioInterruptionType.unknown;
    }
  }

  // ---- Test hooks --------------------------------------------------------

  @visibleForTesting
  void debugFireInterruption({
    required bool begin,
    AudioInterruptionType type = AudioInterruptionType.unknown,
  }) {
    _onInterruption(AudioInterruptionEvent(begin, type));
  }

  @visibleForTesting
  void debugFireBecomingNoisy() => _onBecomingNoisy();

  @visibleForTesting
  void debugFireAppResume() => _onAppResumed();

  @override
  void emitPlaybackState(Object state) {
    if (state is PlaybackState) {
      CorePlayerMediaKit.log(
        'Bridge.emitPlaybackState: playing=${state.playing} processingState=${state.processingState} pos=${state.updatePosition}',
        name: 'CoreMediaKitAudioServiceBridge',
      );
      playbackState.add(state);
    }
  }

  @override
  void emitMediaItem(Object? item) {
    if (item == null) {
      CorePlayerMediaKit.log(
        'Bridge.emitMediaItem: null',
        name: 'CoreMediaKitAudioServiceBridge',
      );
      mediaItem.add(null);
    } else if (item is MediaItem) {
      CorePlayerMediaKit.log(
        'Bridge.emitMediaItem: title=${item.title}, artist=${item.artist}, id=${item.id}, artUri=${item.artUri}',
        name: 'CoreMediaKitAudioServiceBridge',
      );
      mediaItem.add(item);
    }
  }

  @override
  void emitStopState() {
    playbackState.add(PlaybackState());
    mediaItem.add(null);
  }

  @override
  Object? get currentMediaItem => mediaItem.value;

  // ---- BaseAudioHandler overrides (system control surface) ----

  /// NOTE: Unlike [pause]/[stop]/[seek], we intentionally do NOT call
  /// `super.play()`. The active [CorePlayer] subscribes to [CoreAudioHandler.eventStream]
  /// and invokes `player.play()` itself when it sees a [CoreAudioHandlerPlayEvent].
  /// Calling `super.play()` here would either be a no-op (the base class
  /// updates `playbackState`, but we already drive `playbackState` from the
  /// media_kit player's stream via `CorePlayerMediaKit._playbackStateValue`) or
  /// — in the case of a future `super.play()` that actually triggers playback
  /// — produce a double-play race.
  ///
  /// If you change this, also re-derive the playbackState bridging path in
  /// `CorePlayerMediaKit._playbackStateValue`.
  @override
  Future<void> play() async {
    // System control surfaces (lock-screen, MediaSession) target the active
    // scope so multi-scope apps see lock-screen presses on the scope that
    // currently owns the OS surface (via [CoreAudioHandler.requestSystemAudioFocus]).
    CorePlayerMediaKit.log(
      'Bridge.play: lock-screen play event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    _eventTarget?.postEvent(CoreAudioHandlerPlayEvent());
  }

  @override
  Future<void> pause() async {
    CorePlayerMediaKit.log(
      'Bridge.pause: lock-screen pause event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    _eventTarget?.postEvent(CoreAudioHandlerPauseEvent());
    await super.pause();
  }

  @override
  Future<void> stop() async {
    CorePlayerMediaKit.log(
      'Bridge.stop: lock-screen stop event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    mediaItem.add(null);
    playbackState.add(PlaybackState());
    _eventTarget?.postEvent(CoreAudioHandlerStopEvent());
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    CorePlayerMediaKit.log(
      'Bridge.seek: lock-screen seek event received, pos=$position',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    _eventTarget?.postEvent(CoreAudioHandlerSeekEvent(position));
    await super.seek(position);
  }

  @override
  Future<void> fastForward() async {
    CorePlayerMediaKit.log(
      'Bridge.fastForward: lock-screen fastForward event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    await seek(
      playbackState.value.position + AudioService.config.fastForwardInterval,
    );
  }

  @override
  Future<void> rewind() async {
    CorePlayerMediaKit.log(
      'Bridge.rewind: lock-screen rewind event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    await seek(
      playbackState.value.position - AudioService.config.rewindInterval,
    );
  }

  /// Fan out lock-screen / notification "next" presses to the active
  /// [CorePlayer] via [CoreAudioHandlerSkipToNextEvent]. Deliberately does NOT
  /// call `super.skipToNext()` — the base class would emit an opinionated
  /// queue update we do not own; queue state lives on the active player.
  @override
  Future<void> skipToNext() async {
    CorePlayerMediaKit.log(
      'Bridge.skipToNext: lock-screen skipToNext event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    _eventTarget?.postEvent(CoreAudioHandlerSkipToNextEvent());
  }

  @override
  Future<void> skipToPrevious() async {
    CorePlayerMediaKit.log(
      'Bridge.skipToPrevious: lock-screen skipToPrevious event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    _eventTarget?.postEvent(CoreAudioHandlerSkipToPreviousEvent());
  }

  @override
  Future<void> onTaskRemoved() async {
    CorePlayerMediaKit.log(
      'Bridge.onTaskRemoved: system teardown event received',
      name: 'CoreMediaKitAudioServiceBridge',
    );
    // System teardown: notify the bound (default) scope to match
    // pre-Phase-13 behavior and keep teardown semantics identical for
    // single-scope apps. Multi-scope users should handle their own scope
    // lifecycle in app-level teardown.
    final handler = _handler;
    if (handler != null) {
      await handler.onTaskRemoved();
    }
    await super.onTaskRemoved();
  }

  /// Re-emit the active scope's current MediaItem to the lock-screen. Called
  /// by [CoreAudioHandler.requestSystemAudioFocus] / [releaseSystemAudioFocus]
  /// when scope ownership of the OS surface transfers.
  @override
  void refreshMediaItemForActiveScope() {
    final scope = CoreAudioHandler.activeScope;
    final player = scope?.current;
    if (player is CorePlayerMediaKit) {
      final source = player.audioSource;
      if (source != null) {
        mediaItem.add(player.toMediaItemForBridge(source));
        return;
      }
    }
    // Either no active scope, no current player, or current player has no
    // audio source loaded — clear the lock-screen MediaItem.
    mediaItem.add(null);
  }
}
