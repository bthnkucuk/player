import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// Raw media_kit `Player` test screen — NO CorePlayer wrapper, NO state
/// machine, NO observer, NO bridge. Plays the same Science Friday MP3 used
/// by the Single Track demo and surfaces seek timings.
///
/// Purpose: determine whether the long-seek issue lives in our wrapper or
/// in media_kit / Android libmpv directly. If this screen reproduces the
/// 30+ second seek-to-60min stall with no wrapper code in the way, the
/// fix must live below audio_player (mpv config, fork patch, or
/// switch backend).
class RawMediaKitDemo extends StatefulWidget {
  const RawMediaKitDemo({super.key});

  @override
  State<RawMediaKitDemo> createState() => _RawMediaKitDemoState();
}

class _RawMediaKitDemoState extends State<RawMediaKitDemo> {
  static const String _url =
      'https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3';

  late final Player _player;
  final List<String> _events = <String>[];
  final Stopwatch _bootClock = Stopwatch()..start();
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<PlayerLog>? _mpvLogSub;
  bool _bufferingNow = false;
  Duration _position = Duration.zero;
  Duration _buffer = Duration.zero;
  DateTime? _seekStartedAt;
  // Latest "SEEK COMPLETE — Xms" line, surfaced into a dedicated Semantics
  // node so Maestro can read it directly via id:seek_result without
  // scrolling the log panel or regex-matching against accessibility text.
  // Empty until the first seek completes.
  String _lastSeekResult = '';
  // Lifecycle flags surfaced into Semantics nodes so Maestro can wait by id
  // instead of regex-matching transient log lines. The log panel is capped
  // at a few thousand entries and debug-level mpv output flushes through it
  // fast — text-based waits are unreliable.
  String _tuningStatus = 'tuning...';
  String _loadStatus = 'not loaded';
  String _playStatus = 'idle';

  String get _ts {
    final double s = _bootClock.elapsedMilliseconds / 1000.0;
    return 'T+${s.toStringAsFixed(3)}s';
  }

  void _log(String line) {
    final entry = '[$_ts] $line';
    debugPrint('[raw-media_kit] $line');
    if (!mounted) return;
    setState(() {
      _events.insert(0, entry);
      // Debug-level mpv emits hundreds of lines per seek — keep more of
      // them around so Maestro / humans can scroll back through the seek
      // window. 5000 lines @ ~120 chars ≈ 600KB, fine for an example app.
      if (_events.length > 5000) _events.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    // logLevel: debug bumps libmpv's internal log verbosity high enough to
    // include HTTP Range request boundaries, demuxer seek attempts, and
    // cache state transitions. Verbose (v) was too quiet — during the
    // 31-second buffering wait after a long seek, ONLY the `cplayer`
    // prefix emitted anything. Debug exposes the categories that actually
    // explain what mpv is doing.
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 2 * 1024 * 1024,
        logLevel: MPVLogLevel.debug,
      ),
    );
    _log('Player() constructed with bufferSize=2MiB, logLevel=debug');

    // mpv internal log stream — no filter. We want the full firehose during
    // the seek-wait window so the buffering-true gap doesn't look empty.
    _mpvLogSub = _player.stream.log.listen((PlayerLog mpv) {
      _log('mpv:${mpv.prefix} ${mpv.text.trim()}');
    });

    _bufferingSub = _player.stream.buffering.listen((b) {
      _bufferingNow = b;
      _log('buffering=$b');
      if (_seekStartedAt != null && !b) {
        final elapsed = DateTime.now().difference(_seekStartedAt!);
        final summary =
            'SEEK COMPLETE — buffering went false ${elapsed.inMilliseconds}ms after seek call';
        _log(summary);
        if (mounted) setState(() => _lastSeekResult = summary);
        _seekStartedAt = null;
      }
    });
    _playingSub = _player.stream.playing.listen((p) {
      _log('playing=$p');
      if (mounted) setState(() => _playStatus = p ? 'playing' : 'paused');
    });
    _positionSub = _player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _bufferSub = _player.stream.buffer.listen((b) {
      if (!mounted) return;
      setState(() => _buffer = b);
    });

    // BISECT MODE: skip ALL mpv property tuning. (which uses
    // the same Android libmpv 0.35.1 binary) seeks fast. Our refactor
    // added the property tuning. Confirm by running with mpv defaults —
    // if seek is fast here, one of the properties we set is the regression.
    _log('Tuning skipped — using mpv defaults');
    if (mounted) setState(() => _tuningStatus = 'ready');
  }

  @override
  void dispose() {
    unawaited(_bufferingSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_bufferSub?.cancel());
    unawaited(_mpvLogSub?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    _log('open(Media) called — loading $_url');
    if (mounted) setState(() => _loadStatus = 'loading');
    final t0 = DateTime.now();
    await _player.open(Media(_url));
    final ms = DateTime.now().difference(t0).inMilliseconds;
    _log('open() returned after ${ms}ms');
    if (mounted) setState(() => _loadStatus = 'loaded');
  }

  Future<void> _play() async {
    _log('play() called');
    await _player.play();
  }

  Future<void> _pause() async {
    _log('pause() called');
    await _player.pause();
  }

  Future<void> _seek(Duration target) async {
    _log(
      'seek($target) called — current position=$_position buffer=$_buffer buffering=$_bufferingNow',
    );
    _seekStartedAt = DateTime.now();
    // Clear the previous SEEK COMPLETE summary so Maestro's `id:seek_result`
    // wait can't accidentally match a stale result from an earlier tap.
    if (mounted) {
      setState(() => _lastSeekResult = 'SEEK PENDING — target=$target');
    }

    final t0 = DateTime.now();
    await _player.seek(target);
    final ms = DateTime.now().difference(t0).inMilliseconds;
    _log(
      'seek() returned after ${ms}ms (native call duration; buffering may continue)',
    );
    // Only publish a "command-duration" SEEK COMPLETE if the buffering
    // listener hasn't already filled in the audible-ready reading. The
    // listener's number is strictly more accurate when buffering toggles;
    // this fallback covers the in-cache case where buffering never flips.
    if (mounted && _lastSeekResult.startsWith('SEEK PENDING')) {
      setState(
        () => _lastSeekResult =
            'SEEK COMPLETE (cmd) — ${ms}ms native command duration',
      );
    }
  }

  /// Experimental byte-percent seek workaround for the libavformat
  /// `mp3_seek` slow-path bug. mpv's `seek <pct> absolute-percent+keyframes`
  /// triggers the SEEK_FACTOR code path in `demux_seek_lavf`, which sets
  /// `AVSEEK_FLAG_BYTE` and bypasses `mp3_seek` entirely — the demuxer does
  /// a pure AVIO byte seek + resync at the demuxer level, so we expect
  /// sub-second seeks even on HTTP-streamed CBR MP3 where the bug
  /// otherwise causes a 30+ second sequential frame scan.
  ///
  /// Computes the percentage from current `Player.state.duration` so the
  /// math survives any source. Falls back to a hardcoded estimate for the
  /// Science Friday MP3 (90min) if duration isn't known yet.
  Future<void> _seekByPercent(Duration target) async {
    final Duration totalDuration = _player.state.duration;
    final double targetSec = target.inMilliseconds / 1000.0;
    final double durationSec = totalDuration.inMilliseconds > 0
        ? totalDuration.inMilliseconds / 1000.0
        : 90 * 60.0; // Science Friday episode fallback
    final double pct = (targetSec / durationSec * 100.0).clamp(0.0, 100.0);

    _log(
      'seek-by-percent($target ≈ ${pct.toStringAsFixed(3)}%) called — '
      'duration=$totalDuration position=$_position buffer=$_buffer buffering=$_bufferingNow',
    );
    _seekStartedAt = DateTime.now();
    if (mounted) {
      setState(
        () => _lastSeekResult =
            'SEEK PENDING (byte%) — target=$target pct=${pct.toStringAsFixed(2)}',
      );
    }

    final t0 = DateTime.now();
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // command([seek, <pct>, absolute-percent+keyframes]) → SEEK_FACTOR
      // path → AVSEEK_FLAG_BYTE → bypasses mp3_seek's sequential scan.
      // dynamic cast: NativePlayer stub on web doesn't declare `command`;
      // the runtime check above guards us on web (stub instance is not the
      // real type), the cast just satisfies the analyzer for the web build.
      await (platform as dynamic).command([
        'seek',
        pct.toString(),
        'absolute-percent+keyframes',
      ]);
    } else {
      _log('platform is not NativePlayer — falling back to timestamp seek');
      await _player.seek(target);
    }
    final ms = DateTime.now().difference(t0).inMilliseconds;
    _log(
      'seek-by-percent() returned after ${ms}ms (native call; buffering may continue)',
    );
    // Publish "SEEK COMPLETE (byte% cmd)" only if buffering listener
    // hasn't already raced ahead with a more accurate audible-ready
    // reading. Byte-percent seeks frequently land in mpv's in-cache range
    // and never toggle buffering, so this fallback is the common case.
    if (mounted && _lastSeekResult.startsWith('SEEK PENDING')) {
      setState(
        () => _lastSeekResult =
            'SEEK COMPLETE (byte% cmd) — ${ms}ms native command duration',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Raw media_kit (no wrapper)')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Uses media_kit.Player directly — no CorePlayer wrapper. '
                    'Same tuning (cache-on-disk:no, fastseek, etc.) applied.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilledButton(onPressed: _load, child: const Text('Load')),
                      FilledButton.tonal(
                        onPressed: _play,
                        child: const Text('Play'),
                      ),
                      FilledButton.tonal(
                        onPressed: _pause,
                        child: const Text('Pause'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      OutlinedButton(
                        onPressed: () => _seek(const Duration(minutes: 30)),
                        child: const Text('Seek 30min'),
                      ),
                      OutlinedButton(
                        onPressed: () => _seek(const Duration(hours: 1)),
                        child: const Text('Seek 1h'),
                      ),
                      OutlinedButton(
                        onPressed: () => _seek(const Duration(minutes: 5)),
                        child: const Text('Seek 5min'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Byte-percent (SEEK_FACTOR) workaround for the mp3_seek
                  // slow-path bug. Visually distinct from the broken
                  // timestamp-seek row above: bright green FilledButton +
                  // ⚡ prefix + larger padding so users (and Maestro)
                  // can't confuse the two strategies.
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      border: Border.all(
                        color: Colors.green.shade700,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '⚡ FAST SEEK (byte-percent workaround)',
                          style: TextStyle(
                            color: Colors.green.shade900,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                              ),
                              onPressed: () =>
                                  _seekByPercent(const Duration(hours: 1)),
                              child: const Text(
                                '⚡ Seek 1h FAST',
                                style: TextStyle(fontSize: 16),
                              ),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                              ),
                              onPressed: () =>
                                  _seekByPercent(const Duration(minutes: 30)),
                              child: const Text(
                                '⚡ Seek 30min FAST',
                                style: TextStyle(fontSize: 16),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Lifecycle status row — three Semantics nodes Maestro can
                  // wait on individually. Each renders a tiny chip so the
                  // values are visible on-screen for human inspection too.
                  Wrap(
                    spacing: 8,
                    children: [
                      Semantics(
                        identifier: 'tuning_status',
                        label: _tuningStatus,
                        child: Chip(label: Text('tune: $_tuningStatus')),
                      ),
                      Semantics(
                        identifier: 'load_status',
                        label: _loadStatus,
                        child: Chip(label: Text('load: $_loadStatus')),
                      ),
                      Semantics(
                        identifier: 'play_status',
                        label: _playStatus,
                        child: Chip(label: Text('play: $_playStatus')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Maestro reads playback state through this Semantics node
                  // (id: position_status) — no need to grep accessibility
                  // text against the formatted "pos: ... buffer: ..." line.
                  Semantics(
                    identifier: 'position_status',
                    label:
                        'pos=$_position buffer=$_buffer buffering=$_bufferingNow',
                    child: Text(
                      'pos: $_position   buffer: $_buffer   buffering: $_bufferingNow',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Dedicated SEEK COMPLETE surface (id: seek_result). Empty
                  // until the first seek completes; reads "SEEK PENDING …"
                  // while a seek is in flight, then "SEEK COMPLETE — Xms …"
                  // when buffering=false fires. Maestro waits on this id
                  // directly via `extendedWaitUntil: visible: { id: ... }`.
                  Semantics(
                    identifier: 'seek_result',
                    label: _lastSeekResult.isEmpty
                        ? 'no seek yet'
                        : _lastSeekResult,
                    child: Text(
                      _lastSeekResult.isEmpty
                          ? '(no seek yet)'
                          : _lastSeekResult,
                      style: const TextStyle(
                        color: Colors.deepPurple,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              // id: log_panel — Maestro can scroll/inspect this node by id
              // if the raw event stream is needed for deeper diagnosis.
              child: Semantics(
                identifier: 'log_panel',
                container: true,
                child: Container(
                  color: Colors.black,
                  padding: const EdgeInsets.all(8),
                  child: ListView.builder(
                    itemCount: _events.length,
                    itemBuilder: (BuildContext context, int index) {
                      return Text(
                        _events[index],
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
