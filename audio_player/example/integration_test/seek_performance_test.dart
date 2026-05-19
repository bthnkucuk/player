// Deterministic seek-performance regression test.
//
// WHY THIS EXISTS
// ---------------
// Users report that seeking ~1 hour into the Science Friday MP3 used by
// `lib/demos/single_track.dart` takes 25–30 seconds in this app while the
// exact same URL seeks in ~1 second in Chrome. The hypothesis is that libmpv
// (or our wrapper bootstrap) is doing a sequential download from the current
// position to the seek target instead of issuing an HTTP byte-range request.
//
// A parallel investigation is doing root-cause analysis. This test is the
// independent, runnable proof: it measures wall-clock time from `seek(target)`
// to the first emission where playback has actually resumed at-or-past the
// target. It does NOT try to fix anything.
//
// PASS  → seek completes in < 5s (Chrome-tier behaviour).
// FAIL  → seek takes longer (regression / sequential-download bug present).
//         Failure message includes elapsed ms and last observed position so
//         the log alone tells you what happened.
//
// HOW TO RUN
//   cd audio_player/example
//   fvm flutter test integration_test/seek_performance_test.dart -d <device-id>
// Notes:
//   * Requires a connected device or emulator with internet access.
//   * Uses FVM-pinned Flutter 3.41.9 at repo root.
//   * Two test cases run independently:
//       1. wrapper flow  — CorePlayerMediaKit.ensureInitialized + CorePlayer.create
//       2. raw media_kit — media_kit.Player directly, same URL/target
//     If (1) fails and (2) passes, the wrapper is at fault. If both fail,
//     the issue lives in libmpv / bootstrap config.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'package:audio_player_example/sample_tracks.dart';

// Longest sample available is the Science Friday episode (~90 min). 72 min
// is ~80% in — well past any plausible initial buffer window, so a fast
// seek can only succeed via an HTTP range request.
const Duration _seekTarget = Duration(minutes: 72);

// Chrome-tier seek SLA. Bug today produces ~25–30s; well-behaved native
// playback should be sub-second to a few seconds even on a cold network.
const Duration _seekSla = Duration(seconds: 5);

// Hard ceiling so a totally broken seek surfaces as a clear failure rather
// than hanging the test runner.
const Duration _seekHardTimeout = Duration(seconds: 60);

// If initial playback never starts within this window, the failure is almost
// certainly network/device — not the seek bug.
const Duration _initialPlaybackTimeout = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Mirror example/lib/main.dart bootstrap so the wrapper path matches
    // what users actually run.
    WidgetsFlutterBinding.ensureInitialized();
    CorePlayerMediaKit.ensureInitialized(
      configuration: CorePlayerConfiguration(
        androidNotificationChannelId:
            'com.example.audio_player_example.audio',
        androidNotificationChannelName: 'audio_player example playback',
        androidNotificationOngoing: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
    await CoreAudioHandler.initialize();
    mk.MediaKit.ensureInitialized();
  });

  testWidgets(
    'wrapper: seek($_seekTarget) completes in < ${_seekSla.inSeconds}s',
    (WidgetTester tester) async {
      final CorePlayer player =
          CorePlayer.create(audioHandler: CoreAudioHandler.instance);
      final _Observed obs = _Observed();
      final StreamSubscription<Duration> posSub =
          player.positionStream.listen((Duration p) => obs.position = p);
      final StreamSubscription<bool> playSub =
          player.playingStream.listen((bool p) => obs.playing = p);

      try {
        await player.loadAndPlay(SampleTracks.scienceFridayEpisode);
        await _measureSeek(
          obs: obs,
          startInitial: () async {}, // loadAndPlay already started playback
          doSeek: () => player.seek(_seekTarget),
          label: 'wrapper',
        );
      } finally {
        await posSub.cancel();
        await playSub.cancel();
        await player.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'raw media_kit (control): seek($_seekTarget) completes in < ${_seekSla.inSeconds}s',
    (WidgetTester tester) async {
      // Bypass the wrapper. If this PASSES while the wrapper test FAILS, the
      // bug lives in CorePlayer/bridge. If both fail, it's libmpv/bootstrap.
      final mk.Player player = mk.Player();
      final String url = SampleTracks.scienceFridayEpisode.url!;
      final _Observed obs = _Observed();
      final StreamSubscription<Duration> posSub =
          player.stream.position.listen((Duration p) => obs.position = p);
      final StreamSubscription<bool> playSub =
          player.stream.playing.listen((bool p) => obs.playing = p);

      try {
        await _measureSeek(
          obs: obs,
          startInitial: () async {
            await player.open(mk.Media(url));
            await player.play();
          },
          doSeek: () => player.seek(_seekTarget),
          label: 'raw media_kit',
        );
      } finally {
        await posSub.cancel();
        await playSub.cancel();
        await player.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _Observed {
  Duration position = Duration.zero;
  bool playing = false;
}

/// Drives the shared seek-measurement protocol used by both test cases.
/// 1. Run [startInitial] to kick off playback (no-op for wrapper which
///    already loaded via loadAndPlay).
/// 2. Wait for real playback (playing=true AND position has advanced past
///    2s — the position check guards against a "lying" playing=true).
/// 3. Time the [doSeek] call and wait for the FIRST emission where BOTH
///    playing=true AND position is inside the target window. After a seek
///    mpv may briefly flip playing=false during buffering or surface a
///    stale position before the seek lands; only the joint signal proves
///    audible playback resumed at the requested timestamp.
/// 4. Assert against [_seekSla] with a failure message that embeds the
///    elapsed ms and last observed position.
Future<void> _measureSeek({
  required _Observed obs,
  required Future<void> Function() startInitial,
  required Future<void> Function() doSeek,
  required String label,
}) async {
  await startInitial();

  await _waitUntil(
    () => obs.playing && obs.position > const Duration(seconds: 2),
    timeout: _initialPlaybackTimeout,
    onTimeout:
        '[$label] initial playback never started within '
        '${_initialPlaybackTimeout.inSeconds}s — possible network issue, not '
        'a seek bug. playing=${obs.playing} position=${obs.position}',
  );

  final Stopwatch sw = Stopwatch()..start();
  await doSeek();
  await _waitUntil(
    () =>
        obs.playing &&
        obs.position >= _seekTarget - const Duration(seconds: 5) &&
        obs.position <= _seekTarget + const Duration(seconds: 10),
    timeout: _seekHardTimeout,
    onTimeout:
        '[$label] seek did not complete within '
        '${_seekHardTimeout.inSeconds}s. playing=${obs.playing} '
        'position=${obs.position} target=$_seekTarget',
  );
  sw.stop();

  expect(
    sw.elapsed < _seekSla,
    isTrue,
    reason:
        '[$label] Seek to $_seekTarget took ${sw.elapsedMilliseconds}ms — '
        'expected < ${_seekSla.inMilliseconds}ms (Chrome-tier). Last observed '
        'position=${obs.position}. Matches the reported sequential-download '
        'regression.',
  );
}

/// Polls [condition] every 100ms until true or [timeout] elapses, then
/// fails with [onTimeout]. Callers embed live state in that message so the
/// failure log is self-explanatory.
Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
  required String onTimeout,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(onTimeout);
}
