# audio_player example

Runnable Flutter app demonstrating the [player_core](../../player_core/) +
[audio_player](../) wrappers. Modeled after
[just_audio's example](https://github.com/ryanheise/just_audio/tree/minor/just_audio/example).

## Run

```bash
cd packages/player_core/audio_player/example
fvm flutter run
```

## Demos

- **Single track** — load, play, pause, seek, speed, volume, loop modes (off / one), error stream.
- **Playlist** — queue, `skipToNext` / `skipToPrevious` / `skipToIndex`, shuffle, queue loop, gapless playback.
- **Multi-scope** — two independent audio scopes; transfer OS-surface ownership at runtime via `requestSystemAudioFocus()`.
- **Observer** — install a `CorePlayerObserver` and watch lifecycle events stream into a live log.

## Audio sources

Streams MP3s from [SoundHelix](https://www.soundhelix.com/) and
Science Friday's public S3 bucket — the same tracks used by the
just_audio example.

## Background audio

Lock your device while playing — controls should appear on the
lock-screen and notification shade. This requires the iOS
`Info.plist` `UIBackgroundModes: audio` and Android `AudioService`
declarations (both present in this example's platform configs).
