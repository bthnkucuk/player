part of 'core_player_media_kit.dart';

/// Notification / lock screen controls: play, pause, stop, seek, skip next/prev.
const _systemActions = {
  MediaAction.seek,
  MediaAction.rewind,
  MediaAction.fastForward,
  MediaAction.skipToNext,
  MediaAction.skipToPrevious,
};

/// Default libmpv property overrides applied to every [Player] built by
/// [CorePlayerMediaKit]. Tuned for long-form HTTP MP3 streaming on mobile:
/// `demuxer-lavf-o=fflags=+fastseek` is the upstream-prescribed workaround
/// for mpv#6537 (post-seek silence of ~26 s on HTTPS-served VBR/CBR MP3 due
/// to libavformat's mp3dec scanning frame headers byte-by-byte from the seek
/// estimate). The remaining keys harden the HTTP demuxer's reconnect /
/// seek-table behaviour without altering decode semantics.
///
/// `cache-dir` is intentionally NOT listed here: its value is resolved
/// asynchronously via `path_provider.getApplicationCacheDirectory()` at
/// construction time. See `_applyLibmpvOptions` in
/// `core_player_media_kit.dart`.
const Map<String, String> _kDefaultLibmpvOptions = {
  // HTTP / seek tuning (Fix 2 — mpv#6537 workaround group)
  'demuxer-lavf-o': 'fflags=+fastseek',
  'stream-lavf-o':
      'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,seekable=1,multiple_requests=1',
  'demuxer-readahead-secs': '20',
  'force-seekable': 'yes',
  // Audio output longevity (Fix 4):
  // Keep the platform audio device open across track switches so libmpv
  // doesn't tear down + recreate the iOS AudioUnit on `player.jump`. That
  // teardown was a guaranteed AVAudioSession deactivation window through
  // which backgrounded apps (YouTube) could reclaim focus, leaving our
  // playback silent or both apps in focus limbo.
  'audio-keep-open': 'yes',
  'gapless-audio': 'yes',
};

/// Signature for the seam that pushes the effective libmpv option map onto a
/// constructed [Player]. Production wires this to a closure that calls
/// `(player.platform as dynamic).setProperty(name, value)` per entry; tests
/// inject a capture-only implementation. The applier is invoked once per
/// player construction; it is not re-invoked when options change later.
typedef LibmpvOptionsApplier =
    Future<void> Function(Player player, Map<String, String> options);

LibmpvOptionsApplier _libmpvOptionsApplier = _defaultLibmpvOptionsApplier;

/// Test seam: override the production applier so unit tests can capture the
/// effective option map (defaults merged with `configuration.libmpvOptions`)
/// without needing a real `NativePlayer`. Pass `null` to restore the
/// production applier.
@visibleForTesting
void debugSetLibmpvOptionsApplierForTest(LibmpvOptionsApplier? applier) {
  _libmpvOptionsApplier = applier ?? _defaultLibmpvOptionsApplier;
}

Future<void> _defaultLibmpvOptionsApplier(
  Player player,
  Map<String, String> options,
) async {
  final platform = player.platform;
  if (platform == null) return;
  final dynamic native = platform;
  for (final entry in options.entries) {
    try {
      await native.setProperty(entry.key, entry.value);
    } on Object catch (e, s) {
      CorePlayerMediaKit.log(
        'libmpv setProperty failed for "${entry.key}"',
        error: e,
        stackTrace: s,
      );
    }
  }
}

