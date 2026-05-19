# audio_player Maestro flows

End-to-end UI flows that drive the example app on a real Android device
(or any platform Maestro supports) and measure observable wrapper +
media_kit behaviour. Used to reproduce bugs that only surface on real
hardware, where the simulators and Bash mpv don't.

## Setup

1. Connect an Android device with USB debugging enabled.
2. Build + install the example app:
   ```
   cd packages/player_core/audio_player/example
   fvm flutter pub get
   fvm flutter build apk --debug
   adb -s <DEVICE_ID> install -r build/app/outputs/flutter-apk/app-debug.apk
   ```
   You don't need `flutter run` afterwards — each Maestro flow starts the
   app via `launchApp: { clearState: true }`, so the device just needs the
   APK on it. Re-run `build + install` only when Dart code changes.

3. (Optional) In a second terminal, tail Android system logs side-by-side
   with the Maestro run — useful when something hangs:
   ```
   adb -s <DEVICE_ID> logcat -s flutter
   ```
   Find `<DEVICE_ID>` via `adb devices` — the dev device is `RFCX208RXNH`.

   Note: Flutter's `debugPrint` (and `print`) output does **not** route to
   logcat when the app is launched via `adb install` + `am start` (only via
   `flutter run`). For diagnostic data outside of logcat, read the
   in-app log panel via Maestro's `inspect_screen` — the new
   `id: log_panel` Semantics node wraps it.

## Running a flow

```
cd packages/player_core/audio_player/example/maestro
maestro test flows/raw_seek_backfill.yaml
```

Or run the whole directory:

```
maestro test flows/
```

Filter by tag (see flows for available tags):

```
maestro test flows/ --include-tags=seek
maestro test flows/ --exclude-tags=slow
```

## Reading results — prefer Semantics ids over text matching

The Raw media_kit demo exposes diagnostic state through `Semantics(identifier: …)`
nodes, which Maestro picks up as Android `resource-id`. **Always wait on
ids instead of matching against scrolling log text** — the log panel is
high-volume at `MPVLogLevel.debug` and individual lines can scroll off
between Maestro polls.

| Semantics id | Type | Meaning |
|---|---|---|
| `tuning_status` | text | `tuning...` → `ready` once initial mpv property tuning finishes |
| `load_status` | text | `not loaded` → `loading` → `loaded` |
| `play_status` | text | `idle` → `playing` / `paused` |
| `position_status` | label | `pos=… buffer=… buffering=…` snapshot |
| `seek_result` | label | `(no seek yet)` → `SEEK PENDING — target=…` → `SEEK COMPLETE — Xms after seek call` |
| `log_panel` | scrollable | Container of the full mpv debug log stream |

Example wait:

```yaml
- extendedWaitUntil:
    visible:
      id: "seek_result"
      text: "SEEK COMPLETE.*"
    timeout: 90000
```

Then after the flow, `maestro inspect_screen` (or the MCP `inspect_screen`
call) returns the node text directly — no scrolling, no regex against
formatted log lines.

## Flows

| File | Tag(s) | What it tests |
|---|---|---|
| `raw_seek_backfill.yaml` | `seek`, `bug` | Reproduces the media_kit-level seek backfill bug. Opens the "Raw media_kit (no wrapper)" demo, plays from 0, seeks to 1h, asserts the `id: seek_result` Semantics node reaches `SEEK COMPLETE` — and exposes the millisecond duration via that node so a follow-up `inspect_screen` reads the latency. |
| `wrapper_seek_smoke.yaml` | `seek`, `smoke` | Same scenario via the CorePlayer wrapper (Single Track demo). Compares wrapper behaviour against raw media_kit. |
| `lock_screen.yaml` | `lock-screen`, `smoke` | Opens Single Track, plays, then asserts the lock-screen MediaSession appears (manual visual check via screenshot). |

## Quick-start: reproduce the seek bug

```
cd packages/player_core/audio_player/example/maestro
maestro test flows/raw_seek_backfill.yaml
```

Then read the `seek_result` Semantics node (Maestro asserts it reaches
`SEEK COMPLETE` within 90s) — the milliseconds in that node's text are
the real seek latency. As of the last measurement on `RFCX208RXNH`
(Samsung Android 13+), the seek to 1h takes ~31–35 seconds even with
the full mpv tuning applied (`cache-on-disk=no`, `hr-seek=no`,
`demuxer-lavf-o=…,fflags=+fastseek`, etc.). The debug-level mpv log
(visible in `id: log_panel`) shows the time is spent between
`mpv:lavf execute seek` and `mpv:lavf seek done` — i.e. inside
libavformat's `mp3_seek`, not in mpv's stream/cache layer.
