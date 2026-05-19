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

## 0.8.1

- Fix: audio session is no longer activated when a CorePlayer is constructed or attached. It's now activated only when play() is first called, matching standard behavior (Spotify/YouTube don't pause other apps' audio just because you open them).
- CoreAudioHandler.requestActiveSession() — new method called by impls from inside play() to acquire OS audio focus on actual playback intent. Idempotent via the bridge's existing _hasUserActivatedSession gate.
- attach() no longer drives session activation. detach() still deactivates when the scope becomes empty.

## 0.8.0

- New API:
  - CoreAudioHandler.activeScopeStream — reactive notification of OS-surface focus transfer.
  - CorePlayer.audioSourceStream — reactive notification of the currently-loaded source.
  - CorePlayer.clearQueue() — convenience for setQueue(CorePlayerQueue.empty()).
- errorStream dartdoc clarified: fires for every CorePlayerFailure even when the caller catches it. Pick one strategy (passive observer OR per-call try/catch) to avoid duplicate notifications.
- Example app's multi-scope demo migrated from Timer.periodic polling to the new activeScopeStream and audioSourceStream.

## 0.7.0

- **Multi-scope audio handler.** `CoreAudioHandler` is now instantiable — each instance is an independent audio scope with its own attached players + event stream. Apps that need parallel audio paths (preview + main, ambient + foreground) can create additional scopes alongside the default one; pre-Phase-13 code using `CoreAudioHandler.instance` and the legacy static API keeps working unchanged.
- New public API on `CoreAudioHandler`:
  - Constructor: `CoreAudioHandler({String? debugName})`.
  - Instance: `attach(player)`, `detach(player)`, `players`, `current`, `isCurrent(player)` (multi-scope counterparts of the legacy statics).
  - Instance: `isActiveScope`, `requestSystemAudioFocus()`, `releaseSystemAudioFocus({fallbackTo})`, `debugName`.
  - Static: `activeScope` — the scope currently owning the OS surface.
- Existing instance API (`eventStream`, `postEvent`, `emitPlaybackState`, `emitMediaItem`, `currentMediaItem`, `onTaskRemoved`) is now scope-local.
- Legacy statics (`attachPlayer`, `detachPlayer`, `attachedPlayers`, `currentPlayer`, `isCurrentPlayer`) delegate to the default scope — fully back-compatible for single-scope callers.
- Within-scope auto-pause behavior preserved. Across-scope playback is mixed (simultaneous).
- Only the **active scope** drives audio_session activate/deactivate, lock-screen MediaItem updates, and receives system events (lock-screen play/pause/skip) from the bridge. Default scope is active at startup. Transfer via `requestSystemAudioFocus()`.
- New SPI hook: `CoreAudioServiceBridge.refreshMediaItemForActiveScope()` (default no-op) — bridges that want to re-emit MediaItem on scope transfer override this. The media_kit bridge implements it.
- README "Limitations" reframed: the old "single audio scope per process" bullet is gone; the only remaining limitation is `audio_service`'s "one OS audio surface per process", documented as a constraint of the underlying package.

## 0.6.0

- **Gapless playback** — internal queue mechanics migrated to media_kit's native Playlist primitive. Track-to-track transitions no longer close+re-open the native player.
- **Shuffle support** — new `setShuffle` / `shuffle` / `shuffleStream` on `CorePlayer`. Mapped to media_kit's native shuffle.
- Auto-advance is now handled by media_kit (PlaylistMode.{none,single,loop}) instead of the wrapper's manual completion handler. Externally-observable behavior unchanged.
- README "Limitations" — gapless and shuffle removed; single-audio-scope remains the only intentional constraint.

Internal:
- `_openSource` removed; `setQueue` / `skipToIndex` now use `player.open(Playlist)` / `player.jump(n)` / `player.next()` / `player.previous()`.
- `_handleCompletion` removed.
- New `player.stream.playlist` subscription keeps the wrapper's queue index in sync with media_kit's view.

## 0.5.0

- **Playlist / queue support.**
  - New `CorePlayerQueue` value type (extension type over `(List<CorePlayerAudioSource>, int)` record + `currentIndex`).
  - New `CorePlayer.{setQueue, skipToNext, skipToPrevious, skipToIndex}`.
  - New `CorePlayerLoopMode.all` for queue looping (wrap-around).
  - Auto-advance on track completion (respecting `loopMode`).
  - Lock-screen `MediaControl.skipToNext` / `MediaControl.skipToPrevious` wired through new `CoreAudioHandlerSkipToNextEvent` / `CoreAudioHandlerSkipToPreviousEvent`.
  - `QueueOutOfBoundsFailure` for invalid skip targets.
- `load(source)` preserved as a convenience — internally creates a single-item queue.
- README "Limitations" updated: gapless and shuffle still out of scope; single-track constraint removed.

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

* Interruption / BecomingNoisy / AppLifecycle resume protocol — `CoreAudioHandlerEvent` hierarchy now carries `InterruptionBeginEvent`, `InterruptionEndEvent`, `BecomingNoisyEvent`, `AppResumeEvent` so impls can react to audio-session events without leaking `audio_service` types.
* Staged init with per-stage 15 s timeouts and tolerant fall-through — a hung platform channel during bootstrap no longer deadlocks app startup.
* Dispose ordering tightened — stream subscriptions cancelled before native player teardown to eliminate "write to closed BehaviorSubject" races.
* `notifyOthersOnDeactivation` honoured on session deactivation so other audio apps can resume cleanly.
* Typed `CorePlayerFailure` sealed class replaces raw `Exception` throws: `PlayerDisposedFailure`, `MediaItemNotSetFailure`, `InvalidMediaSourceFailure`, `LoadFailure`, `PlayFailure`, `PlaybackSpeedFailure`.
* `CorePlayer.create` / `CorePlayer.registerFactory` — consumers no longer need to import the impl package directly. Impls register their factory inside `ensureInitialized()`.
* `play()` now throws a typed `PlayFailure` when `attachPlayer` fails (was silently swallowed).
* `AppResumeEvent` synthesises an `InterruptionEnd` when `_interruptedWhilePlaying` is set — covers iOS apps (Reels / TikTok-class) that don't fire interruption-end on foreground return.
* New `CorePlayer.loadAndPlay` single-flight wrapper coalesces rapid double-tap races into one in-flight Future.
* `CorePlayerAudioSource.props` now includes `genre` (was excluded by mistake, breaking equality for sources differing only in genre).
* Documented `CoreAudioServiceBridge.play()` semantics.

## 0.1.0

* Initial public surface for the backend-agnostic player wrapper.
* Extracted `CoreAudioServiceBridge` SPI so the abstraction no longer imports `audio_service` / `audio_session`; platform impls install a bridge via `CoreAudioHandler.registerBridge`.
* Replaced `dart:io` `File` field on `CorePlayerAudioSource` with a string `filePath`, making the package web-safe.
* Exposed stream getters as `rxdart` `ValueStream<T>` so consumers can read `.value` / `.hasValue` without casting.
* Added `CoreAudioHandlerTaskRemovedEvent` emission from `CoreAudioHandler.onTaskRemoved()` (distinct from a user-initiated stop).
* Removed the misleading parameterised abstract constructor — subclasses now supply their own.

## 0.0.1

* Initial scaffold.
