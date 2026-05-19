# packages/player_core/audio_player — Test Quality Report

**Overall grade:** A-

> 7 test files / 3,056 LOC for 2 lib files / 738 LOC = **4.14 ratio** (very high). media_kit-specific platform behavior tested with mocktail; `Player`/`VideoController` in ignored leak list as known offenders. The single biggest leverage: add an integration smoke that proves a real media_kit instance plays a sample asset (currently all mocked).

## Dimensions

### Unit / Logic coverage — A
- 7 test files for media_kit binding adapter.

### Widget tests — N/A

### Golden tests — N/A

### Mocking discipline — A+
- mocktail in 9; 0 mockito.

### Leak hygiene — A
- §14 FULL template; `Player`, `VideoController` upstream-singletons in ignored.

### Hydration round-trips — N/A

### Equatable / stringify — A
- Global in config.

### Flaky tests — A
- 0 skips.

### Test:source ratio — A++
- 3,056 / 738 = **4.14**.

### CI hookup — A
- Included in melos.

### `BUGS_FOUND.md` outstanding — A
- None.

## File inventory

- Tests: 7 files / 3,056 lines
- Lib: 2 files / 738 lines
- Test:source ratio: **4.14**

## How to upgrade overall grade
1. Add 1 integration smoke that loads a tiny WAV asset and asserts position advances (proves the abstraction → media_kit wiring).
2. Pin the seek-boundary contract via a back-to-back `playItem` test (Strategy AN-#6 flake pattern).
3. Hold — this is the most heavily-tested player binding in the repo.
