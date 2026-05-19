# packages/player_core/player_core — Test Quality Report

**Overall grade:** A-

> Wave 1 added playback state-machine + seek-boundary edge cases (+12 tests, per rollout report). 5 test files / 1,742 LOC for 3 lib files / 532 LOC = **3.27 ratio** (very high — abstract layer + tests). The single biggest leverage: keep this abstraction tested before bumping `audio_player`.

## Dimensions

### Unit / Logic coverage — A
- 5 test files for the abstract `Player` contract + state machine.

### Widget tests — N/A
- Abstract API; no widgets here.

### Golden tests — N/A

### Mocking discipline — A
- mocktail in 3; 0 mockito.

### Leak hygiene — A
- §14 FULL template.

### Hydration round-trips — N/A

### Equatable / stringify — A
- Global in config.

### Flaky tests — A
- 0 skips.

### Test:source ratio — A++
- 1,742 / 532 = **3.27** — defensively tested abstraction.

### CI hookup — A
- Included in melos.

### `BUGS_FOUND.md` outstanding — A
- None.

## File inventory

- Tests: 5 files / 1,742 lines
- Lib: 3 files / 532 lines
- Test:source ratio: **3.27**

## How to upgrade overall grade
1. Add property-based (glados) tests for state-machine transitions (no invalid path).
2. Document the seek-boundary contract in a doc-comment for downstream `audio_player` consumers.
