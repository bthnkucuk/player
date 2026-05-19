#player

Backend-agnostic Flutter audio player wrapper. Defines a small abstract
surface (`CorePlayer`, `CoreAudioHandler`, `CorePlayerAudioSource`, the failure
sealed hierarchy, and the `CoreAudioServiceBridge` SPI) so apps depend on
this package and pick an impl at bootstrap.

Pair with **`audio_player`** for the ready-made
[media_kit](https://pub.dev/packages/media_kit)-based implementation.

## Why

- **Backend-agnostic.** Consumers import only `player_core`; impl lives in a
  sibling package. Swap media_kit for just_audio / native AVPlayer / web
  HTMLAudio later without touching feature code.
- **No `audio_service` leak.** The abstraction imports only `equatable`,
  `flutter`, `meta`, `rxdart`. The platform-side `BaseAudioHandler`
  subclass is hidden behind the `CoreAudioServiceBridge` SPI in the impl
  package.
- **Production-shaped lifecycle.** Audio session activation deferred
  until first attach (so other apps aren't interrupted on bootstrap),
  interruption + becoming-noisy + iOS-app-resume handled, dispose
  ordering documented, single-flight `loadAndPlay()`.

## Installation

In your app's `pubspec.yaml`:

```yaml
dependencies:
 player: ^0.5.0
  audio_player: ^0.5.0   # or your own impl
```

### iOS — `ios/Runner/Info.plist`

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

Required for lock-screen controls and background playback.

### Android — `android/app/src/main/AndroidManifest.xml`

Inside `<application>`:

```xml
<service
    android:name="com.ryanheise.audioservice.AudioService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="true">
    <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService" />
    </intent-filter>
</service>

<receiver
    android:name="com.ryanheise.audioservice.MediaButtonReceiver"
    android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.MEDIA_BUTTON" />
    </intent-filter>
</receiver>
```

Add the permission inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
```

## Quickstart

```dart
// 1. Bootstrap once (e.g. in your main()):
import 'package:audio_player/audio_player.dart';

void main() {
  CorePlayerMediaKit.ensureInitialized();   // registers factory + bridge
  runApp(const MyApp());
}

// 2. In feature code — only importplayer:
import 'package:player_core/player_core.dart';

await CoreAudioHandler.initialize();        // wires audio_service

final player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);

const source = CorePlayerAudioSource(
  title: 'Track',
  artist: 'Artist',
  url: 'https://example.com/audio.mp3',
);

await player.loadAndPlay(source);

// 3. Queue-based playback (Phase 10):
final queue = CorePlayerQueue([
  CorePlayerAudioSource(title: 'Track 1', url: 'https://example.com/1.mp3'),
  CorePlayerAudioSource(title: 'Track 2', url: 'https://example.com/2.mp3'),
]);

await player.setQueue(queue);
await player.play();

// Auto-advance fires on natural end-of-track; respects loopMode.
await player.setLoopMode(CorePlayerLoopMode.all);   // wrap queue
await player.skipToNext();
await player.skipToPrevious();
await player.skipToIndex(0);

// Shuffle traverses the queue in randomized order until disabled (Phase 11).
await player.setShuffle(true);
player.shuffleStream.listen((on) => print('shuffle=$on'));
await player.setShuffle(false);

// Single-track still works (internally creates a single-item queue):
await player.loadAndPlay(source);

// 4. Observe state:
player.playerStateStream.listen((s) => print('state=$s'));
player.positionStream.listen((p) => print('pos=$p'));
player.queueStream.listen((q) => print('queue.currentIndex=${q.currentIndex}'));

// 5. Clean up:
await player.dispose();
```

## API tour

| Surface | Purpose |
|---|---|
| `CorePlayer.create(...)` | Construct via registered factory. Throws `StateError` if no impl bootstrapped. |
| `CorePlayer.loadAndPlay(src)` | Single-flight `stop → load → play`. Rapid double-taps coalesce. |
| `CorePlayer.{play, pause, seek, stop, setPlaybackSpeed}` | Standard playback. |
| `CorePlayer.{setQueue, skipToNext, skipToPrevious, skipToIndex}` | Queue API. `load(src)` is a convenience that wraps a single source. |
| `CorePlayer.{queue, queueStream}` | Current queue (`CorePlayerQueue`) and its `ValueStream`. |
| `CorePlayer.{shuffle, shuffleStream, setShuffle}` | Shuffle mode (Phase 11). Backed by the underlying impl's native shuffle. |
| `CorePlayer.{playerStateStream, positionStream, durationStream, bufferStream, playingStream, playbackSpeedStream}` | `ValueStream<T>` getters — consumers can read `.value` directly. |
| `CorePlayerFailure` (sealed) | Typed errors: `PlayerDisposedFailure`, `MediaItemNotSetFailure`, `InvalidMediaSourceFailure`, `LoadFailure`, `PlayFailure`, `PlaybackSpeedFailure`, `QueueOutOfBoundsFailure`. |
| `CoreAudioHandler.{initialize, instance, attachPlayer, detachPlayer, eventStream}` | Registry + event hub for the **default scope**. Cross-player coordination within a scope. |
| `CoreAudioHandler({debugName})` constructor, `.{attach, detach, players, current, isCurrent, requestSystemAudioFocus, releaseSystemAudioFocus, isActiveScope, debugName, activeScope}` | **Multi-scope API.** Each instance is an independent audio scope (parallel audio paths). Only the active scope owns the OS surface (lock-screen, audio session). |
| `CoreAudioHandlerEvent` (open hierarchy) | Bridge → impl signals: `PlayEvent`, `PauseEvent`, `StopEvent`, `SeekEvent`, `TaskRemovedEvent`, `InterruptionBeginEvent`, `InterruptionEndEvent`, `BecomingNoisyEvent`, `AppResumeEvent`. |
| `CoreAudioServiceBridge` (SPI) | Abstract — implement to backplayer with a non-media_kit backend. |

## Writing your own impl

1. Implement `CorePlayer` (the abstract class).
2. Implement `CoreAudioServiceBridge` — typically by extending `BaseAudioHandler` from `audio_service` (if you want lock-screen controls) and translating its callbacks into `CoreAudioHandlerEvent`s.
3. Expose a static `ensureInitialized()` that calls
   `CoreAudioHandler.registerBridge(yourBridge)` and
   `CorePlayer.registerFactory((args) => YourPlayer(args))`.

See `packages/player_core/audio_player/` for a working reference.

## Audio scopes (multi-scope playback)

Each `CoreAudioHandler` instance is an independent **audio scope** — a logical grouping of attached players with its own current player and event stream. Most apps need only the default scope (`CoreAudioHandler.instance`); apps that need parallel audio paths (e.g. main playback + preview, ambient background + foreground audio) can create additional scopes:

```dart
final preview = CoreAudioHandler(debugName: 'preview');
final previewPlayer = CorePlayer.create(audioHandler: preview);
```

**Rules:**

- **Within a scope:** attaching a new player auto-pauses any other player in the same scope.
- **Across scopes:** players in different scopes play simultaneously (mixed audio). Attaching to scope B does NOT pause players in scope A.
- **OS surface:** only the **active scope** owns the lock-screen, MediaSession, and `audio_session` focus. The default scope is active at startup.
- **Switching focus:** call `someScope.requestSystemAudioFocus()` to transfer ownership. The previously-active scope's players are NOT paused — they keep playing in the background. The lock-screen updates to reflect the new active scope's current player. Subsequent lock-screen presses (play / pause / skip) flow to the new active scope's `eventStream`.
- **Releasing focus:** `someScope.releaseSystemAudioFocus()` returns ownership to the default scope (or to `fallbackTo:` if provided).

Pre-Phase-13 code that uses `CoreAudioHandler.instance` and the legacy static API (`attachPlayer`, `detachPlayer`, `attachedPlayers`, `currentPlayer`, `isCurrentPlayer`) keeps working unchanged — those statics implicitly target the default scope.

## Limitations

These constraints are imposed by the underlying `audio_service` package, not by `player_core` itself:

- **One OS audio surface per process.** Lock-screen / MediaSession / notification show one player at a time. Multi-scope removes the wrapper-level limitation, but the OS still binds one `BaseAudioHandler` per app. Use `requestSystemAudioFocus()` to switch which scope owns the surface; players in inactive scopes keep playing but don't appear on the lock-screen.

## Status

- v0.7.0 — multi-scope `CoreAudioHandler` (parallel audio paths via `CoreAudioHandler({debugName})`, `requestSystemAudioFocus` / `releaseSystemAudioFocus`, per-instance `attach` / `detach` / `players` / `current` / `isCurrent`). All pre-Phase-13 statics retained as default-scope delegations — single-scope callers are unaffected.
- v0.6.0 — gapless playback (media_kit native Playlist), shuffle support.
- v0.5.0 — playlist/queue support added (`setQueue`, `skipToNext/Previous/Index`, `CorePlayerLoopMode.all`, auto-advance, lock-screen `MediaControl.skipToNext/Previous`). Single-track `load(src)` preserved as a convenience.

