# player roadmap

Production-grade audio wrapper plan for `player_core` + `audio_player`.

**Guiding principles**
- **Thin wrapper** over `media_kit` + `audio_service` + `audio_session`. Wrapper's job is glue + stable API + normalised types — not reimplementing what underlying libs already do.
- **Testable + proper**: every code path mockable without natives where reasonable; clean lifecycle; typed errors; single source of truth for state.
- **Patrol gates `main`**: integration tests block merges when behavior breaks.

**Current state baseline** (2026-05-19)
- Coverage: `player_core` 100% (58/58 + 6/6), `audio_player` 97.8% (179/183). 4 uncovered lines = documented native bootstrap.
- Test:source ratio: 3.27 (`player_core`), 4.14 (`audio_player`).
- No CI, no patrol, `alchemist` dev dep declared but zero golden tests exist.
- media_kit pinned to upstream `media-kit/media-kit` `ref: main` (fork dropped, was carrying obsolete one-line compile fix).
- pub workspace at repo root (`player_core` + `audio_player`); example resolves via path overrides outside workspace.

---

## Phase 0 — Highest-leverage trio (do first, ~half-day)

1. **CI workflow + branch protection.** Add `.github/workflows/ci.yml` running `dart format --set-exit-if-changed`, `flutter analyze`, `flutter test --coverage` for both packages. Wire `main` branch protection to require `unit` check.
2. **Coverage gate at 95% per package.** `tool/check_coverage.sh` script. Justified because measured baseline is 100/97.8 — not aspirational.
3. **Delete dead infra.** Remove `alchemist` from both pubspecs + strip `ciGoldensConfig` from both `flutter_test_config.dart`. Zero golden tests exist.

---

## Phase 1 — P0 thinness/properness fixes

### Sil / kapat
- [ ] **Delete back-compat statics on `CoreAudioHandler`** — `attachPlayer` / `detachPlayer` / `attachedPlayers` / `currentPlayer` / `isCurrentPlayer` at `player_core/lib/src/player/core_audio_handler.dart:478-505`. No v1 history to preserve.
- [ ] **Decide `CoreAudioHandlerAppResumeEvent`** at `core_audio_handler.dart:114`: wire a real consumer or delete. Currently dispatched, no consumer reads it.
- [ ] **Hide `CorePlayerMediaKit.player`** at `audio_player/lib/src/player/core_player_media_kit.dart:124`. Mark `@internal` or make private — leaks `media_kit.Player` and breaks backend-agnostic claim.
- [ ] **Remove `alchemist`** dev dep + `flutter_test_config.dart` `ciGoldensConfig` wrappers (covered in Phase 0).
- [ ] **`seek` snap thresholds** at `core_player_media_kit.dart:744-746`: either make `seekStartThreshold` / `seekEndThreshold` consumer-configurable via `CorePlayerConfiguration`, or remove the silent no-op (current behavior is a footgun).
- [ ] **`CorePlayerAudioSource` validation** in constructor: require exactly one of `url` / `filePath` at construction, not deferred-throw in `_toMedia`.

### Test seam (testability blockers)
- [ ] **Extract `MediaKitPlayerLike` interface** covering the subset of `media_kit.Player` the wrapper uses (`stream.position`, `stream.playlist`, `stream.playing`, `stream.completed`, `stream.volume`, `stream.rate`, `stream.buffer`, `open`, `play`, `pause`, `seek`, `next`, `previous`, `jump`, `dispose`, etc.). Unlocks state-machine + queue tests without libmpv. Highest single-change leverage.
- [ ] **Simplify `_playerStateValue`** at `core_player_media_kit.dart:221-242`. Drop `combineLatest5 + buffer>position` heuristic; derive `CorePlayerState` directly from `playing` + `completed` + opening flag + error. Heuristic flaky, hard to unit-test deterministically.
- [ ] **Surface bridge init failure** as a typed `bridgeInitStatus` getter/stream at `core_audio_service_bridge.dart:110-117, 163-171`. Current silent swallow means lock-screen can quietly not work and the consumer never knows.

---

## Phase 2 — Spotify-tier feature gap (thin pass-through wiring)

These belong in the wrapper because they wire existing underlying capabilities; not reimplementations.

- [ ] **ReplayGain / loudness normalisation** — libmpv `--replaygain` family, expose via config.
- [x] **Cache options** — exposed via `CorePlayerConfiguration.libmpvOptions`. `cache-dir`, `demuxer-readahead-secs`, and `force-seekable` are wired with sensible defaults; any libmpv property can be overridden by the consumer.
- [ ] **Pitch correction** — libmpv `--audio-pitch-correction`, expose via config.
- [ ] **Configurable `MediaControl` / `MediaAction` sets** at `core_player_media_kit.dart:13-19` (`_systemActions`) and lock-screen `PlaybackState` builder. Currently hardcoded — consumers cannot add `setRating`, custom skip intervals, or disable controls.
- [ ] **`CorePlayerQueue.toJson` / `fromJson`** — queue persistence for hot-restart survival. Cheap, high-value.
- [ ] **Android Auto / CarPlay decision**: either expose `audio_service` MediaBrowser hooks via `CoreAudioServiceBridge` (`getChildren`, `search`), or document as explicit non-goal.
- [x] **HTTP MP3 fast seek (mpv#6537 workaround)** — `demuxer-lavf-o=fflags=+fastseek` shipped as default in `libmpvOptions`. Post-seek silence on long-form HTTPS MP3 dropped from ~26 s to ~1 s on Android (Samsung S911B baseline). User override via `CorePlayerConfiguration.libmpvOptions`.
- [x] **iOS playlist-switch focus retention (libmpv audio-keep-open)** — added
  `audio-keep-open=yes` + `gapless-audio=yes` to default `libmpvOptions`.
  Prevents libmpv's iOS AudioUnit teardown on `player.jump` that was
  letting backgrounded apps (YouTube) reclaim focus and silencing our
  playback. Verified on iPhone foreground + background.

### Out of scope (consumer-side concerns)
- Offline cache / eviction policy
- Recently-played / history list
- Sleep timer
- Cast / AirPlay (libmpv doesn't support; out of scope for this wrapper)
- Crossfade (would require dual-player; revisit only if a real consumer demands it)

---

## Phase 3 — Missing wrapper unit tests (filtered: only OUR logic)

Author-flagged in `TEST_QUALITY_REPORT.md`:
- [ ] `loadAndPlay` concurrent-call coalescing (two simultaneous calls share the same Future)
- [ ] `seekEndThreshold` early-return — assert `player.seek` is NOT called past `duration - 300ms`
- [ ] `_openWithRetry` backoff schedule — pin `maxBackoff` clamp + `backoffMultiplier` accumulation

Discovered in review:
- [ ] `_onAppResumed` `_interruptedWhilePlaying=false` branch (`core_audio_service_bridge.dart:347-360`)
- [ ] `refreshMediaItemForActiveScope` non-`CorePlayerMediaKit` branch (`core_audio_service_bridge.dart:530-543`)
- [ ] `onTaskRemoved` ordering (`core_audio_handler.dart:528-555`)
- [ ] `_playbackStateValue` MediaItem-duration patch (`core_player_media_kit.dart:894-899`) — lock-screen progress-bar fix path
- [ ] Multi-scope `requestActiveSession` gate when not active scope (`core_audio_handler.dart:438-441`)
- [ ] `setQueue` single-flight (currently can interleave concurrent calls)

### Properness fixes
- [ ] Replace global `CorePlayer.observer` static at `player_core/lib/src/player/player_core.dart:111` with per-instance observer (or injected list). Globals cause test pollution.
- [ ] Make `needToLoad` private at `core_player_media_kit.dart:482-483`; expose via debug getter if needed.
- [ ] `setQueue` single-flight (same pattern as `_inFlightLoadAndPlay`).

---

## Phase 4 — Patrol smoke gate (Month 1)

Set up `audio_player/example/integration_test/` with patrol. PR-blocker subset first.

> **Note (2026-05-19):** `integration_test` package is treated as discontinued for this project — **all integration tests will be written with patrol**. The current `seek_performance_test.dart` uses raw `integration_test` as a temporary repro for the slow-seek bug; convert it to a patrol test when patrol is wired up, then remove the `integration_test` dev_dependency from `example/pubspec.yaml`.

### Top scenarios (mapped to existing demos)

| # | Scenario | Demo | What's tested |
|---|---|---|---|
| 1 | Single track plays, position > 2s | `single_track.dart` | media_kit native pipeline actually loads + reports position |
| 2 | Lock-screen pause → wrapper pauses → `playingStream` emits false | `single_track.dart` | `audio_service` → bridge → `eventStream` → `CorePlayer.pause` |
| 3 | Lock-screen next → queue advances, MediaItem updates | `playlist.dart` | `skipToNext` → `CoreAudioHandlerSkipToNextEvent` |
| 4 | Headphone unplug → wrapper pauses within 500ms | `single_track.dart` | `audio_session.becomingNoisyEventStream` |
| 5 | Phone-call sim begin/end → pauses; resumes per config | `single_track.dart` | `audio_session` interruption + `_interruptedWhilePlaying` |
| 6 | Backgrounded → foreground notification visible 10s later, plays through | `single_track.dart` | `androidNotificationOngoing` + background playback |
| 7 | Cold start with YouTube holding MediaSession → our seed displaces it | `single_track.dart` | `core_audio_service_bridge.dart:192-202` seed workaround |
| 8 | Multi-scope: two players, transfer focus, lock-screen MediaItem swaps | `multi_scope.dart` | `requestSystemAudioFocus` + `refreshMediaItemForActiveScope` |
| 9 | Hot-restart while playing → second `main()` doesn't crash | `single_track.dart` | `ensureInitialized` / `AudioService.init` idempotency |
| 10 | `loadAndPlay` double-tapped 50ms apart → only one native open | `single_track.dart` | `_inFlightLoadAndPlay` coalescing |

**Phase 4 PR-blocker subset: 1, 2, 4** (Month 1 end).
**Phase 4 expanded PR-blocker: 1–5** (Month 1 end target).

### Native triggers

- Reachable via patrol: app backgrounding (`pressHome`), notification taps, Android media-session button (`adb shell media dispatch headsethook`), headphone-plug intent (`am broadcast android.intent.action.HEADSET_PLUG`).
- Not reachable, defer to manual / XCUITest:
  - Real phone-call interruption on iOS (CallKit sim is dev-cert gated)
  - Bluetooth device disconnect (physical only)
  - Flutter hot-restart proper (patrol can't trigger; needs test-only entrypoint that re-invokes `runApp`)

For phone-call + BT, ship `manual_tests/CHECKLIST.md` rather than pretend CI covers them.

---

## Phase 5 — Cross-platform parity (Month 3)

- [ ] Patrol 6–10 stable on Android.
- [ ] iOS sim for 6–8 (skip 4 — headphone-unplug sim unavailable on iOS).
- [ ] `manual_tests/CHECKLIST.md` for phone-call + BT disconnect; PRs touching `_onInterruption` / `_onBecomingNoisy` require checklist signoff in PR template.
- [ ] Nightly patrol job across API 30 / 33 / 34 + iOS 16 / 17.
- [ ] Android-specific test parity: `androidStopForegroundOnPause`, `androidResumeOnClick`, `androidNotificationOngoing`, foreground-service notification stickiness, channel-id registration.
- [ ] iOS-specific: `AVAudioSessionCategory.playback` + `longFormAudio` actually displaces prior Now Playing owner; `notifyOthersOnDeactivation` lets Spotify/YouTube resume.

---

## Performance notes

- **`flutter test` cold-cache compile in `audio_player/` runs 30–90s** before any test executes: ~10 test files including the 1863-line `core_player_media_kit_test.dart`, plus media_kit (git-sourced from upstream main) recompiled when the pub cache is cold. Plan for this when budgeting CI wall-clock, local iteration loops, and agent task durations.
- Implication for CI: keep the unit job on a warm cache (cache `.dart_tool/`, `~/.pub-cache/`) — otherwise PR feedback adds a full minute of pre-test compile every run.
- Implication for design: the 1863-line monolithic test file is itself a slowness contributor. When backfilling tests (Phase 3), prefer splitting by feature area (queue, retry, dispose, state machine) over appending to the existing file.

## CI gating sketch (full target)

```yaml
# .github/workflows/ci.yml
name: ci
on: [pull_request]
jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - run: flutter pub get
      - run: dart format --set-exit-if-changed .
      - run: flutter analyze
      - run: flutter test --coverage
        working-directory: player
      - run: flutter test --coverage
        working-directory: audio_player
      - name: Coverage threshold (95%)
        run: |
          bash tool/check_coverage.sh player/coverage/lcov.info 95
          bash tool/check_coverage.sh audio_player/coverage/lcov.info 95
      - uses: codecov/codecov-action@v4

  patrol-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
      - uses: reactivecircus/android-emulator-runner@v2
        with:
          api-level: 34
          arch: x86_64
          script: |
            cd audio_player/example
            dart pub global activate patrol_cli
            patrol test --target integration_test/

  patrol-ios:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
      - run: |
          cd audio_player/example
          dart pub global activate patrol_cli
          patrol test --target integration_test/ -d "iPhone 15"
```

Branch protection on `main`: require `unit`, `patrol-android` (smoke), `patrol-ios` (smoke). Block force-push. Patrol full suite runs nightly.

---

## Explicit NOT-test list (thinness discipline)

These belong to upstream libs, not the wrapper:
- `media_kit.Player.play()` actually produces sound — media_kit's responsibility.
- `audio_service` publishes `PlaybackState` to MPNowPlayingInfoCenter — audio_service's responsibility. Verify only that we built the right `PlaybackState` and called `emitPlaybackState`.
- `audio_session` correctly detects a phone call — audio_session's responsibility. Verify only that when its `interruptionEventStream` emits, our `_onInterruption` routes correctly.
- `MediaKit.ensureInitialized` itself (the `TESTING.md` carve-out is correct).
- Retry library policy details — only that our `LoadRetryConfig` numbers are honored.

---

## Feature matrix snapshot

| Capability | Status |
|---|---|
| Gapless | ✅ via media_kit Playlist |
| Crossfade | ❌ would require wrapper-side dual-player; defer |
| ReplayGain / loudnorm | ❌ libmpv supports; not wired (Phase 2) |
| EQ / audio filters | ⚠️ libmpv has `--af`; not exposed typed |
| Playback speed | ✅ `setPlaybackSpeed` |
| Pitch preservation | ❌ libmpv supports; not exposed (Phase 2) |
| HLS / DASH | ✅ libmpv native |
| Range-request caching | ❌ libmpv `--cache`; not wired (Phase 2) |
| Offline cache / eviction | ❌ consumer-side |
| Queue persistence | ❌ Phase 2 (toJson/fromJson) |
| Shuffle | ✅ |
| Repeat (off/one/all) | ✅ |
| History | ❌ consumer-side |
| Lock-screen controls | ⚠️ hardcoded set; Phase 2 makes configurable |
| Audio focus & ducking | ✅ |
| Becoming noisy | ✅ |
| Call / app interruption | ✅ (with iOS Reels/TikTok foreground fallback) |
| BT disconnect | ⚠️ pauses on noisy; no resume-on-reconnect |
| CarPlay / Android Auto | ❌ Phase 2 decision |
| Cast / AirPlay | ❌ libmpv doesn't support; out of scope |
| Sleep timer | ❌ consumer-side |
| Analytics hooks | ✅ `CorePlayerObserver` + `logCallback` |
| Structured errors | ✅ sealed `CorePlayerFailure` + `errorStream` |
| Multi-player isolation | ✅ multi-scope, well-designed |

---

## Source files (reference)

- `player_core/lib/src/player/player_core.dart`
- `player_core/lib/src/player/core_audio_handler.dart`
- `player_core/lib/src/config/player_core_configuration.dart`
- `player_core/lib/src/queue/player_core_queue.dart`
- `player_core/lib/src/observer/player_core_observer.dart`
- `player_core/lib/src/failures/player_core_failure.dart`
- `audio_player/lib/src/player/core_player_media_kit.dart`
- `audio_player/lib/src/player/core_audio_service_bridge.dart`
- `player_core/TEST_QUALITY_REPORT.md`
- `audio_player/TEST_QUALITY_REPORT.md`
- `audio_player/TESTING.md`
