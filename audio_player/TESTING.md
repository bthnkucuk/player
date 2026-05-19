# `audio_player` — tests, coverage, CI

## Commands

From this package directory:

```bash
fvm flutter test --coverage
lcov --summary coverage/lcov.info
```

`lcov` is optional (summary only); install on macOS with `brew install lcov` if missing.

## Coverage (testable `lib/` code)

Line coverage is measured on `lib/src/player/core_player_media_kit.dart` only (single implementation file).

**Intentionally uncovered (native bootstrap):**

| Lines | Code | Why not covered in `flutter test` |
|-------|------|-----------------------------------|
| 19–20 | `CorePlayerMediaKit.ensureInitialized` → `MediaKit.ensureInitialized` | Requires native **media_kit** libs (e.g. `Mpv.framework` on macOS). Plain `flutter test` does not embed app frameworks; calling this throws *Cannot find Mpv.framework/Mpv*. |
| 48–49 | Default `Player(configuration: …)` when `testPlayer` is omitted | Same: real `Player` needs native initialization. All unit/integration tests pass `testPlayer: mockPlayer`. |

Expect **~98%** lines covered with mocks; reaching 100% needs a **device/integration** or **full desktop app** run where `media_kit` native code loads.

## CI / environment notes

- **Workspace resolution:** Tests run from the monorepo root context; `fvm flutter test` may print `Resolving dependencies in …` for the workspace. That is normal.
- **Pub advisories warnings:** If you see `Failed to decode advisories … FormatException: advisoriesUpdated must be a String`, that is a **pub.dev / client compatibility** issue during `pub get`, not a test failure. Dependencies still resolve; upgrade Dart/pub when practical.
- **Headless / Linux CI:** Mock-based tests do **not** require audio hardware or Mpv. No display server is required beyond what `flutter test` needs.
- **Sandbox:** Running `fvm` under a restricted sandbox can fail on `engine.stamp` / FVM cache writes; run CI jobs with normal filesystem permissions for the Flutter SDK cache.

## Flakiness

- **Async handler routing:** Several tests fire `CoreAudioHandler` events and await a short delay so `unawaited(play())` / `pause()` / `seek()` on the mock complete before `verify()`. Delays are tuned for local runs; **very slow** CI agents might rarely time out. If that happens, increase the delay in the failing test or replace with polling until `verify` succeeds (with a hard timeout).
- **Timeouts:** One integration test uses `handler.playbackState.firstWhere(...).timeout(1s)`; if the stream never emits, it fails loudly (preferable to hanging).

## Regenerating mocks

After changing `@GenerateMocks` in `test/helpers/test_mocks.dart`:

```bash
fvm dart run build_runner build --delete-conflicting-outputs
```
