# player

[![CI](https://github.com/bthnkucuk/player/actions/workflows/ci.yml/badge.svg)](https://github.com/bthnkucuk/player/actions/workflows/ci.yml)
![coverage](https://img.shields.io/badge/coverage-83.3%25-brightgreen)

Production-grade audio playback for Flutter — a thin, testable wrapper over [media_kit](https://pub.dev/packages/media_kit), [audio_service](https://pub.dev/packages/audio_service), and [audio_session](https://pub.dev/packages/audio_session).

Two packages, split so app code only depends on the abstraction:

- **[`player_core`](player_core/)** — backend-agnostic API (`CorePlayer`, `CoreAudioHandler`, the sealed `CoreAudioSource` hierarchy with `HttpAudioSource` / `FileAudioSource`, typed failures, the `CoreAudioServiceBridge` SPI). No `audio_service` leak; imports only `equatable`, `flutter`, `meta`, `rxdart`.
- **[`audio_player`](audio_player/)** — the `media_kit`-based implementation. Wires `media_kit`'s `Player` to `audio_service` (lock-screen / notification) and `audio_session` (interruption handling, audio focus).

## Install

```yaml
dependencies:
  player_core: ^0.8.0
  audio_player: ^0.8.0
```

## Bootstrap

```dart
// main():
CorePlayerMediaKit.ensureInitialized();
```

That single call:
1. Initializes `media_kit` native bindings.
2. Registers the `CoreMediaKitAudioServiceBridge` with `CoreAudioHandler`.
3. Registers a `CorePlayer.create` factory.

See [`player_core/README.md`](player_core/README.md) for the full setup, including the iOS `Info.plist` and Android `AndroidManifest.xml` snippets required for background playback and lock-screen controls.

## Repo layout

```
player/
├── player_core/         # abstract API + state types + bridge SPI
├── audio_player/        # media_kit impl
│   └── example/         # demo app (outside the pub workspace)
└── ROADMAP.md           # design + Phase 0..N plan
```

The root `pubspec.yaml` declares a pub workspace; `flutter pub get` at the repo root resolves both packages.

## Development

Requires Flutter 3.41.9 (pinned in [`.fvmrc`](.fvmrc)). With [FVM](https://fvm.app/):

```sh
fvm install
fvm flutter pub get
fvm flutter analyze
(cd player_core && fvm flutter test --coverage)
(cd audio_player && fvm flutter test --coverage)
```

The example app lives outside the workspace and resolves the local packages via `dependency_overrides`:

```sh
cd audio_player/example
fvm flutter pub get
fvm flutter run
```

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push / PR to `main`:

- `flutter analyze` across the workspace.
- `flutter test --coverage` per package.
- Coverage lcov files are merged and uploaded as an artifact.
- On `main` pushes, a follow-up job recomputes the line-coverage percentage and commits an updated badge into this README.

## License

See [LICENSE](LICENSE) where present; otherwise the repo is currently unreleased.
