# audio_player

[media_kit](https://pub.dev/packages/media_kit)-based implementation of the
[player_core](../player_core/) abstraction. Wires `media_kit`'s `Player` to
`audio_service` (lock-screen controls, notification) and `audio_session`
(interruption handling, audio-focus on Android, AVAudioSession on iOS).

## Installation

See the [player_core README](../player_core/) for full setup, including the
iOS `Info.plist` and Android `AndroidManifest.xml` snippets required for
background playback and lock-screen controls.

```yaml
dependencies:
  player_core: ^0.5.0
  audio_player: ^0.5.0
```

## Bootstrap

```dart
// main():
CorePlayerMediaKit.ensureInitialized();
```

That single call:
1. Initializes `media_kit` native bindings.
2. Registers the `CoreMediaKitAudioServiceBridge` with `CoreAudioHandler`.
3. Registers a `CorePlayer.create` factory that builds `CorePlayerMediaKit` instances.

After this, feature code only imports `package:player_core/player_core.dart`.

## media_kit dependency note

This package depends on a pinned fork of `media_kit` at
`github.com/example-user/media-kit.git` (SHA-pinned for build reproducibility).
The fork exists to:

- Carry patches not yet merged upstream that are required by this wrapper.
- Pin a known-good revision so workspace bootstraps are deterministic.

If/when upstream `media_kit` catches up, the dep will be switched back to
the pub.dev version. Until then, expect the SHA to be bumped explicitly
when integrating new upstream fixes. See [`pubspec.yaml`](pubspec.yaml).

## Native loader

The package depends on `media_kit_libs_audio` which bundles libmpv binaries
for iOS, Android, macOS, Windows, Linux. No additional native setup is
required beyond the `Info.plist` / `AndroidManifest.xml` background-audio
declarations covered in the parent README.

## Limitations

This impl inherits the design constraint from the [`player_core` abstraction](../player_core/):

- **Single audio scope per process** — `CoreAudioHandler` is a singleton; attaching a new player auto-pauses any other attached one.

See the [parent README](../player_core/#limitations) for the rationale.

## Gapless playback

Queue transitions use `media_kit`'s native `Playlist` primitive, so
track-to-track transitions are gapless (or as close as the underlying
codec/decoder allows). Per-track preloading is handled by media_kit;
no wrapper-side preload knob is needed.

Shuffle (`setShuffle` / `shuffle` / `shuffleStream`) also maps onto
media_kit's native shuffle — same gapless behavior applies when
shuffle is enabled.

## Status

- v0.6.0 — matches player 0.6.0; gapless playback via media_kit Playlist, native shuffle.
- v0.5.0 — queue support, lock-screen skip controls, auto-advance.
- Audio session lifecycle: interruption (call/Siri), becoming-noisy
  (headphones unplugged), and AppLifecycle resume (iOS Reels/TikTok-class
  apps that don't fire interruption-end) all handled.
- Bridge initialization is staged with per-stage 15s timeouts and
  tolerant fall-through — a single platform-channel hang won't deadlock
  app startup.
