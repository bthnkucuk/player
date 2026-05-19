## 0.8.6

- Add detailed log instrumentation throughout CoreMediaKitAudioServiceBridge
  — every audio_service / audio_session lifecycle event (init, activate,
  deactivate, emitPlaybackState, emitMediaItem, lock-screen play/pause/
  skip/stop overrides, interruption/becomingNoisy/appResume) now emits
  a one-line log via CorePlayerMediaKit.log(...). Routes through the
  consumer-supplied CorePlayerConfiguration.logCallback (added Phase 9d)
  with developer.log fallback.
- Example app now ships with talker_flutter integration: a 5th demo
  screen ("Debug Logs") shows the live log stream via TalkerScreen.
  Use this to diagnose lock-screen / MediaSession binding issues on
  real devices.

## 0.8.5

- Fix: replaced AudioSessionConfiguration.music() preset with an
  explicit, aggressive configuration matching example_speech_app's working
  setup (playback category, longFormAudio mode, gain focus, music
  content-type). The .music() preset apparently allowed iOS/Android
  to keep treating us as "ambient/mixable" — never displacing the
  prior MediaController owner (YouTube/Spotify) from the lock-screen.
  Explicit playback + longFormAudio + gain forces a real focus claim.

## 0.8.4

- Fix: CoreMediaKitAudioServiceBridge.initialize now seeds an initial
  non-NONE PlaybackState (processingState: idle, queueIndex: 0) right
  after AudioService.init completes. Without this, audio_service's
  Android plugin may not bind the MediaSession to our handler until
  the first play() emission — by which time the system has settled on
  whichever app previously held the OS audio surface (e.g. YouTube),
  and our MediaItem never replaces it on the lock-screen / Now Playing
  widget.

## 0.8.3

- Fix: add androidNotificationIcon to CorePlayerConfiguration (default
  'mipmap/ic_launcher'), threaded through to the AudioServiceConfig
  passed to AudioService.init. Without this, audio_service's
  foreground notification is treated as malformed on some Android
  OEMs (Samsung, Xiaomi), preventing the MediaSession from claiming
  the OS lock-screen / Now Playing surface — playback would work but
  controls would still show whichever app previously held the
  surface (e.g. YouTube).
- Example main.dart sets the icon explicitly as documentation.
- Consumers should ensure their `android/app/src/main/res/` contains
  a `mipmap/ic_launcher` (the default), or override
  `androidNotificationIcon` to point at a different drawable.
- Tracks `player_core ^0.8.3`.

## 0.8.2

- Fix: CorePlayerConfiguration defaults updated to make audio_service's
  foreground service / MediaSession actually work out of the box on
  Android 8+. The previous null `androidNotificationChannelId` and
  `androidNotificationOngoing: false` caused audio to play but the OS
  lock-screen / Now Playing widget to keep showing whichever app last
  claimed the surface (e.g. YouTube), even after pressing play in our
  app.
  - androidNotificationChannelId default: null → 'player_core.audio.default'
  - androidNotificationOngoing default: false → true
  Consumers can still override per-app via CorePlayerConfiguration.
- Internal: play() now activates the audio session BEFORE emitting the
  first MediaItem, so the foreground service is up by the time the
  MediaItem bridges to the OS surface (was the reverse order, which on
  some Android versions caused the bridged value to be dropped).
- Example app's main.dart shows the channel ID / name override pattern.
- Tracks `player_core ^0.8.2`.

## 0.8.1

- Fix: audio session is no longer activated when a CorePlayer is constructed or attached. It's now activated only when play() is first called, matching standard behavior (Spotify/YouTube don't pause other apps' audio just because you open them).
- CoreAudioHandler.requestActiveSession() — new method called by impls from inside play() to acquire OS audio focus on actual playback intent. Idempotent via the bridge's existing _hasUserActivatedSession gate.
- attach() no longer drives session activation. detach() still deactivates when the scope becomes empty.
- Tracks `player_core ^0.8.1`.

## 0.8.0

- Tracks `player_core ^0.8.0`.
- New API:
  - CoreAudioHandler.activeScopeStream — reactive notification of OS-surface focus transfer.
  - CorePlayer.audioSourceStream — reactive notification of the currently-loaded source. Emits on setQueue, playlist auto-advance, and clearQueue.
  - CorePlayer.clearQueue() — convenience for setQueue(CorePlayerQueue.empty()).
- errorStream dartdoc clarified: fires for every CorePlayerFailure even when the caller catches it. Pick one strategy (passive observer OR per-call try/catch) to avoid duplicate notifications.
- Example app's multi-scope demo migrated from Timer.periodic polling to the new activeScopeStream and audioSourceStream.

## 0.7.0

- Tracks `player_core ^0.7.0`.
- **Multi-scope bridge routing.** `CoreMediaKitAudioServiceBridge` now routes lock-screen / system events (`play`, `pause`, `stop`, `seek`, `skipToNext`, `skipToPrevious`, interruption begin/end, becoming-noisy, app-resume) to `CoreAudioHandler.activeScope` rather than the bridge-bound default scope. Multi-scope apps that call `someScope.requestSystemAudioFocus()` will receive lock-screen presses on the new active scope's `eventStream` until focus is released.
- New override: `CoreMediaKitAudioServiceBridge.refreshMediaItemForActiveScope()` — emits the new active scope's current player's `MediaItem` (or null) to the bridge's `mediaItem` stream on focus transfer.
- `onTaskRemoved` still routes to the bound (default) scope — pre-Phase-13 single-scope teardown behavior preserved.
- `CorePlayerMediaKit` now calls `audioHandler.attach(this)` / `audioHandler.detach(this)` (instance) instead of the static `CoreAudioHandler.attachPlayer` / `detachPlayer`, so each player participates in its own scope. The `currentAudioHandler` gate (used before forwarding `MediaItem` / `PlaybackState` to the bridge) additionally checks `scope.isActiveScope` — non-active scopes still play but don't drive the lock-screen.

Internal:
- New `@internal` `CorePlayerMediaKit.toMediaItemForBridge(source)` exposes `_toMediaItem` to the sibling bridge for re-emit-on-focus-transfer.
- Example app rewritten as a proper Flutter app (was a doc snippet). Demonstrates single-track, playlist, multi-scope, and observer flows using SoundHelix MP3s.

## 0.6.0

- Tracks `player_core ^0.6.0`.
- **Gapless playback** — `setQueue` now builds a media_kit `Playlist` from the queue and hands it to `player.open(playable)` in a single call. Track-to-track transitions are gapless.
- **Shuffle support** — `setShuffle` / `shuffle` / `shuffleStream` map to `player.setShuffle` and `player.stream.shuffle`.
- Auto-advance migrated to media_kit's native PlaylistMode pipeline. `setLoopMode` continues to map `.off → none`, `.one → single`, `.all → loop`.
- `skipToIndex` → `player.jump(n)`; `skipToNext` → `player.next()`; `skipToPrevious` → `player.previous()`. Queue-index bounds checks (and `QueueOutOfBoundsFailure` semantics) preserved.
- `player.stream.playlist` listener mirrors media_kit's active index back into the queue projection and fires `CorePlayer.observer.onLoad` for the newly-active source.
- READMEs — gapless and shuffle removed from limitations; new "Gapless playback" section documents the new behavior.

Internal:
- `_openSource` deleted; `_handleCompletion` deleted.
- `_openWithRetry` now takes a `Playable` (Playlist supertype) instead of a `Media`.
- New `_toMedia(src)` helper centralizes the URL-vs-filePath mapping previously inline in `_openSource`.
- **Single source of truth for queue state (Phase 12).** Removed the parallel `_queueSubject` write-from-`setQueue` path. `queue` and `queueStream` are now strict projections of `player.stream.playlist`, mediated by `_queueStreamBacking` (only written by the playlist subscription, plus the explicit empty path in `setQueue`). The wrapper retains a private `_sources` list to round-trip Playlist → CorePlayerQueue. No public API change; no behavior change for callers — eliminates the bidirectional sync race window. Skip bounds checks read from `_sources` (synchronously updated in `setQueue` before `player.open(...)`).

## 0.5.0

- Tracks `player_core ^0.5.0`.
- **Playlist / queue support.**
  - `setQueue` opens the current source through the existing retry-aware `_openSource` helper, so all queue entries inherit the same load semantics as `load(source)`.
  - `CorePlayerLoopMode.all` maps to `media_kit`'s `PlaylistMode.loop`. Queue wrap-around is enforced by our own auto-advance code (not media_kit's internal queue, since the wrapper owns queue state).
  - Auto-advance on `CorePlayerState.completed` — branches on `loopMode`. `.one` uses `player.seek(Duration.zero)` directly to bypass the wrapper's near-end clamp.
  - `CoreMediaKitAudioServiceBridge.skipToNext` / `skipToPrevious` overrides fan out to the active `CorePlayer` via the new audio-handler skip events.
  - `PlaybackState.controls` now includes `MediaControl.skipToNext` / `MediaControl.skipToPrevious`, and `systemActions` adds the matching `MediaAction`s.
- `load(source)` is a thin wrapper over `setQueue(CorePlayerQueue.single(source))` — backward-compatible.

## 0.4.0

- New CorePlayer API:
  - waitForReady({Duration? timeout}) — convenience for the load-then-wait pattern; throws LoadFailure on transition to error, TimeoutException on timeout.
  - CorePlayerObserver — global lifecycle hook (BlocObserver analog) for analytics / observability.
- CorePlayerConfiguration.logCallback — optional logger callback (talker-compatible). Falls back to developer.log.
- CorePlayerMediaKit's media_kit player.stream.position is throttled to 200ms for internal state calculations (combineLatest5). Public positionStream remains at native rate for UI scrubbers.
- CorePlayerMediaKit constructor is now marked @internal — use CorePlayer.create after ensureInitialized.
- Test suites verified stable under --test-randomize-ordering-seed=random.

## 0.3.0

- New CorePlayer API:
  - setVolume / volume / volumeStream — volume control 0.0–1.0.
  - setLoopMode / loopMode / loopModeStream — single-track loop toggle.
  - errorStream — passive observer surface for all CorePlayerFailures + impl-side errors.
- New CorePlayerConfiguration — wraps bufferSizeBytes + AudioServiceConfig
  overrides + LoadRetryConfig (exponential backoff). Pass via
  CorePlayerMediaKit.ensureInitialized(configuration: ...).

## 0.2.0

* Tracks `player_core ^0.2.0`.
* Interruption / BecomingNoisy / AppLifecycle resume handling — bridge translates `audio_session` events into `CoreAudioHandlerEvent`s; `_interruptedWhilePlaying` flag resynchronises on AppResume for iOS apps that drop interruption-end.
* Staged init with per-stage 15 s timeouts and tolerant fall-through so a hung platform channel can't deadlock app startup.
* `notifyOthersOnDeactivation` honoured when the session deactivates.
* Typed `CorePlayerFailure` throws (`PlayerDisposedFailure`, `MediaItemNotSetFailure`, `InvalidMediaSourceFailure`, `LoadFailure`, `PlayFailure`, `PlaybackSpeedFailure`) replace raw `Exception`s.
* `play()` propagates `PlayFailure` when `attachPlayer` fails (was previously swallowed).
* Implements `CorePlayer.registerFactory` inside `CorePlayerMediaKit.ensureInitialized()` — consumers no longer need to import this package outside of bootstrap.
* `CorePlayerMediaKit.loadAndPlay` inherits the single-flight wrapper from `player_core 0.2.0`.

## 0.1.0

* Initial public release tracking `player_core ^0.1.0`.
* Implemented the new `CoreAudioServiceBridge` from `player_core` as `CoreMediaKitAudioServiceBridge`; platform-specific `audio_service` / `audio_session` setup now lives entirely in this package.
* Reordered `dispose()` to cancel stream subscriptions before stopping / disposing the native player, fixing a "write to closed BehaviorSubject" race.
* Added an `idle` branch to the playback state machine so `CorePlayerMediaKit` reports `CorePlayerState.idle` when no audio source is loaded.
* Reacted to `CoreAudioHandlerTaskRemovedEvent` from the handler.
* Extracted the magic 300 ms start/end seek thresholds to named constants on the class.

## 0.0.1

* Initial scaffold.
