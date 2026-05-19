import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/seek_bar.dart';

/// Demos the queue mutation API added in Faz Q:
/// `insertNext`, `appendToQueue`, `removeAt`, `moveItem`,
/// `replaceAt(preservePosition: ...)`.
///
/// The buttons exercise the mutation surface while a track is playing so
/// QA can eyeball that the wrapper never re-opens the active media (no
/// audible stall, no position reset).
class QueueMutationDemo extends StatefulWidget {
  const QueueMutationDemo({super.key});

  @override
  State<QueueMutationDemo> createState() => _QueueMutationDemoState();
}

class _QueueMutationDemoState extends State<QueueMutationDemo> {
  late final CorePlayer _player;
  StreamSubscription<CorePlayerFailure>? _errorSub;
  String? _lastError;
  bool _queueLoaded = false;

  // Reserved as the bench source for insertNext / replaceAt — kept distinct
  // from the initial queue so the new item is visually identifiable.
  static final CoreAudioSource _benchTrack = SampleTracks.soundHelix3;

  @override
  void initState() {
    super.initState();
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _errorSub = _player.errorStream.listen((failure) {
      if (!mounted) return;
      setState(() => _lastError = failure.toString());
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _loadQueue() async {
    setState(() => _lastError = null);
    try {
      await _player.setQueue(
        CorePlayerQueue(<CoreAudioSource>[
          SampleTracks.scienceFridayEpisode,
          SampleTracks.scienceFridaySegment,
          SampleTracks.soundHelix1,
          SampleTracks.soundHelix2,
        ]),
      );
      setState(() => _queueLoaded = true);
      await _player.play();
    } on CorePlayerFailure catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } on CorePlayerFailure catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Queue mutation')),
      body: SafeArea(
        child: StreamBuilder<CorePlayerQueue>(
          stream: _player.queueStream,
          initialData: _player.queue,
          builder: (context, queueSnap) {
            final queue = queueSnap.data ?? const CorePlayerQueue.empty();
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _IntroCard(),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _loadQueue,
                  icon: const Icon(Icons.queue_music),
                  label: Text(
                    _queueLoaded ? 'Reload queue' : 'Load 4-track queue',
                  ),
                ),
                const SizedBox(height: 8),
                _NowPlaying(player: _player),
                const SizedBox(height: 12),
                _MutationControls(
                  enabled: queue.isNotEmpty,
                  queue: queue,
                  benchTrack: _benchTrack,
                  onInsertNext: () =>
                      _safe(() => _player.insertNext(_benchTrack)),
                  onAppend: () =>
                      _safe(() => _player.appendToQueue(_benchTrack)),
                  onRemoveCurrent: () =>
                      _safe(() => _player.removeAt(queue.currentIndex)),
                  onReplaceCurrentPreserve: () => _safe(
                    () => _player.replaceAt(
                      queue.currentIndex,
                      _benchTrack,
                      preservePosition: true,
                    ),
                  ),
                  onReplaceCurrentReset: () => _safe(
                    () => _player.replaceAt(queue.currentIndex, _benchTrack),
                  ),
                ),
                const SizedBox(height: 12),
                _QueueView(
                  queue: queue,
                  player: _player,
                  onReorder: (int from, int to) =>
                      _safe(() => _player.moveItem(from, to)),
                ),
                const SizedBox(height: 12),
                if (_lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Error: $_lastError',
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                _ExpectedCard(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'What this demos',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'This screen demos the new queue mutation API:\n'
              'insertNext / appendToQueue / removeAt / moveItem /\n'
              'replaceAt(preservePosition).\n'
              'Use the buttons below while a track is playing\n'
              'and verify the queue reorders / extends / mutates\n'
              'WITHOUT restarting the current track.',
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpectedCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'Expected result',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'Expected result:\n'
              '- "Insert next" -> after the current track finishes,\n'
              '  playback jumps to the inserted item (not the\n'
              '  original successor).\n'
              '- "Append" -> the queue grows; current track keeps\n'
              '  playing without a pause/restart.\n'
              '- "Remove current" -> playback advances to the next\n'
              '  track immediately, no audible gap.\n'
              '- Drag-to-reorder -> grab the drag handle on the\n'
              '  right of any row and drag up/down. The row\n'
              '  visibly moves; queue order updates immediately.\n'
              '  Playback continues from the same position without\n'
              '  a pause/restart. If a non-active item is\n'
              '  reordered, the active item stays active.\n'
              '- "Replace current (preserve)" -> the new audio\n'
              '  starts at the same time-offset as where the old\n'
              '  one was (within ~200 ms).\n'
              '\n'
              'If any of these visibly restarts the current track\n'
              "or audibly stalls, that's a regression - open an\n"
              'issue and attach the seek_target / log output.',
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.player});
  final CorePlayer player;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        StreamBuilder<CoreAudioSource?>(
          stream: player.audioSourceStream,
          initialData: player.audioSource,
          builder: (context, snap) {
            final source = snap.data;
            return Text(
              source == null ? '(no track)' : 'Now playing: ${source.title}',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            );
          },
        ),
        StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position,
          builder: (context, posSnap) {
            return StreamBuilder<Duration>(
              stream: player.durationStream,
              initialData: player.duration,
              builder: (context, durSnap) {
                return StreamBuilder<Duration>(
                  stream: player.bufferStream,
                  initialData: player.buffer,
                  builder: (context, bufSnap) {
                    return SeekBar(
                      duration: durSnap.data ?? Duration.zero,
                      position: posSnap.data ?? Duration.zero,
                      bufferedPosition: bufSnap.data ?? Duration.zero,
                      onSeek: player.seek,
                    );
                  },
                );
              },
            );
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            StreamBuilder<bool>(
              stream: player.playingStream,
              initialData: player.isPlaying,
              builder: (context, snap) {
                final playing = snap.data ?? false;
                return IconButton(
                  iconSize: 36,
                  icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                  onPressed: playing ? player.pause : player.play,
                );
              },
            ),
            IconButton(
              iconSize: 32,
              icon: const Icon(Icons.skip_previous),
              onPressed: () async {
                try {
                  await player.skipToPrevious();
                } on CorePlayerFailure {
                  // boundary failures: surfaced via errorStream
                }
              },
            ),
            IconButton(
              iconSize: 32,
              icon: const Icon(Icons.skip_next),
              onPressed: () async {
                try {
                  await player.skipToNext();
                } on CorePlayerFailure {
                  // boundary failures: surfaced via errorStream
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _MutationControls extends StatelessWidget {
  const _MutationControls({
    required this.enabled,
    required this.queue,
    required this.benchTrack,
    required this.onInsertNext,
    required this.onAppend,
    required this.onRemoveCurrent,
    required this.onReplaceCurrentPreserve,
    required this.onReplaceCurrentReset,
  });

  final bool enabled;
  final CorePlayerQueue queue;
  final CoreAudioSource benchTrack;
  final VoidCallback onInsertNext;
  final VoidCallback onAppend;
  final VoidCallback onRemoveCurrent;
  final VoidCallback onReplaceCurrentPreserve;
  final VoidCallback onReplaceCurrentReset;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: <Widget>[
        OutlinedButton.icon(
          onPressed: enabled ? onInsertNext : null,
          icon: const Icon(Icons.playlist_add),
          label: const Text('Insert next'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? onAppend : null,
          icon: const Icon(Icons.add_to_queue),
          label: const Text('Append'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? onRemoveCurrent : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Remove current'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? onReplaceCurrentPreserve : null,
          icon: const Icon(Icons.find_replace),
          label: const Text('Replace current (preserve)'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? onReplaceCurrentReset : null,
          icon: const Icon(Icons.refresh),
          label: const Text('Replace current (reset)'),
        ),
      ],
    );
  }
}

class _QueueView extends StatelessWidget {
  const _QueueView({
    required this.queue,
    required this.player,
    required this.onReorder,
  });

  final CorePlayerQueue queue;
  final CorePlayer player;

  /// Caller-supplied reorder handler. Receives `(from, to)` where [to] is
  /// the destination slot in the FINAL list — matches
  /// [CorePlayer.moveItem]'s contract. The Flutter
  /// `ReorderableListView.onReorder` quirk (see below) is absorbed at the
  /// call site before invoking this callback.
  final Future<void> Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    // Inner ReorderableListView shrink-wraps and delegates scrolling to the
    // outer ListView. Drops the previous bounded-height + Card wrap: both
    // made drag targets visually cramped and limited how much of the queue
    // was visible at once, hurting reorder testability on a real device.
    if (queue.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Queue is empty')),
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: queue.length,
      onReorder: (int oldIndex, int newIndex) {
        // `ReorderableListView` quirk: when dragging DOWN, Flutter
        // passes `newIndex` computed against the pre-removal list,
        // so it is one larger than the final destination slot.
        // `CorePlayer.moveItem` expects `to` to be the destination
        // index in the FINAL list, so we strip Flutter's overshoot
        // before delegating.
        final int adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
        if (adjusted == oldIndex) return;
        // Fire-and-forget: the queueStream rebuild will reflect
        // the new order; errors are surfaced via errorStream.
        unawaited(onReorder(oldIndex, adjusted));
      },
      itemBuilder: (context, i) {
        final source = queue.sources[i];
        final isActive = i == queue.currentIndex;
        return ListTile(
          // Keys must be unique even when the queue contains
          // duplicate sources (e.g. after `insertNext(X)` followed
          // by `replaceAt(0, X)` — two slots reference the same
          // CoreAudioSource instance, identical URLs). The
          // index is the disambiguator; `identityHashCode` lets
          // the framework distinguish a "replace" (new instance)
          // from a "reorder" (same instance moved) at the same
          // slot. Re-render animations are best-effort under this
          // scheme — what matters is the absence of GlobalKey
          // collisions during the swap.
          key: ValueKey<String>('queue-row-$i-${identityHashCode(source)}'),
          leading: CircleAvatar(child: Text('$i')),
          title: Text(
            source.title,
            style: TextStyle(
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            source.artist ??
                switch (source) {
                  HttpAudioSource(:final url) => url.toString(),
                  FileAudioSource(:final path) => path,
                  HlsAudioSource(:final manifestUrl) => manifestUrl.toString(),
                  LiveAudioSource(:final initialUrl) =>
                      initialUrl?.toString() ?? '(live segment stream)',
                },
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isActive)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.graphic_eq, color: Colors.green),
                )
              else
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () async {
                    try {
                      await player.skipToIndex(i);
                    } on CorePlayerFailure {
                      // surfaced via errorStream
                    }
                  },
                ),
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.drag_handle),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
