import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

/// Transport row: replay 10s, skip prev, play/pause/stop, skip next, forward 10s.
///
/// Skip prev/next are auto-disabled when the active queue is single-track or
/// empty; the ±10s buttons are auto-disabled while the duration is unknown.
/// The widget reads queue / position / duration from [player]'s streams.
class PlayPauseStopButtons extends StatelessWidget {
  const PlayPauseStopButtons({
    required this.player,
    required this.state,
    required this.isPlaying,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    this.showStop = true,
    super.key,
  });

  final CorePlayer player;
  final CorePlayerState state;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final bool showStop;

  static const Duration _seekStep = Duration(seconds: 10);

  @override
  Widget build(BuildContext context) {
    final Widget primary;
    if (state == CorePlayerState.loading) {
      primary = const SizedBox(
        width: 56,
        height: 56,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(),
        ),
      );
    } else if (state == CorePlayerState.completed) {
      primary = IconButton(
        iconSize: 56,
        icon: const Icon(Icons.replay),
        onPressed: onPlay,
      );
    } else if (isPlaying) {
      primary = IconButton(
        iconSize: 56,
        icon: const Icon(Icons.pause_circle_filled),
        onPressed: onPause,
      );
    } else {
      primary = IconButton(
        iconSize: 56,
        icon: const Icon(Icons.play_circle_filled),
        onPressed: onPlay,
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Flexible(
          child: _SeekRelativeButton(
            player: player,
            icon: Icons.replay_10,
            delta: -_seekStep,
          ),
        ),
        Flexible(child: _SkipButton(player: player, isNext: false)),
        Flexible(child: primary),
        if (showStop) ...<Widget>[
          Flexible(
            child: IconButton(
              iconSize: 40,
              icon: const Icon(Icons.stop_circle),
              onPressed: onStop,
            ),
          ),
        ],
        Flexible(child: _SkipButton(player: player, isNext: true)),
        Flexible(
          child: _SeekRelativeButton(
            player: player,
            icon: Icons.forward_10,
            delta: _seekStep,
          ),
        ),
      ],
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.player, required this.isNext});

  final CorePlayer player;
  final bool isNext;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CorePlayerQueue>(
      stream: player.queueStream,
      initialData: player.queue,
      builder: (BuildContext context, AsyncSnapshot<CorePlayerQueue> snap) {
        final bool enabled = (snap.data?.length ?? 0) > 1;
        // Tooltip explains the disabled state; without it the greyed icon is
        // ambiguous (could read as a transient buffering state).
        return Tooltip(
          message: enabled
              ? (isNext ? 'Skip next' : 'Skip previous')
              : 'Queue has a single track',
          child: IconButton(
            iconSize: 36,
            icon: Icon(isNext ? Icons.skip_next : Icons.skip_previous),
            onPressed: enabled
                ? (isNext
                      ? () => player.skipToNext()
                      : () => player.skipToPrevious())
                : null,
          ),
        );
      },
    );
  }
}

class _SeekRelativeButton extends StatelessWidget {
  const _SeekRelativeButton({
    required this.player,
    required this.icon,
    required this.delta,
  });

  final CorePlayer player;
  final IconData icon;
  final Duration delta;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (BuildContext context, AsyncSnapshot<Duration> durSnap) {
        final Duration duration = durSnap.data ?? Duration.zero;
        final bool enabled = duration > Duration.zero;
        return IconButton(
          iconSize: 36,
          icon: Icon(icon),
          onPressed: enabled
              ? () {
                  final Duration target = _clampDuration(
                    player.position + delta,
                    Duration.zero,
                    duration,
                  );
                  player.seek(target);
                }
              : null,
        );
      },
    );
  }
}

Duration _clampDuration(Duration value, Duration min, Duration max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/// Drop-down for playback speed.
class SpeedDropdown extends StatelessWidget {
  const SpeedDropdown({
    required this.speed,
    required this.onChanged,
    super.key,
  });

  final double speed;
  final ValueChanged<double> onChanged;

  static const List<double> _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final double rounded = _speeds.reduce(
      (double a, double b) => (a - speed).abs() < (b - speed).abs() ? a : b,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.speed),
        const SizedBox(width: 8),
        DropdownButton<double>(
          value: rounded,
          items: <DropdownMenuItem<double>>[
            for (final double s in _speeds)
              DropdownMenuItem<double>(value: s, child: Text('${s}x')),
          ],
          onChanged: (double? value) {
            if (value != null) onChanged(value);
          },
        ),
      ],
    );
  }
}

/// Horizontal slider for volume [0.0, 1.0].
class VolumeSlider extends StatelessWidget {
  const VolumeSlider({
    required this.volume,
    required this.onChanged,
    super.key,
  });

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.volume_down),
        Expanded(
          child: Slider(
            min: 0,
            max: 1,
            value: volume.clamp(0.0, 1.0),
            onChanged: onChanged,
          ),
        ),
        const Icon(Icons.volume_up),
      ],
    );
  }
}

/// Cycle button: off → one → all → off …
class LoopModeButton extends StatelessWidget {
  const LoopModeButton({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  final CorePlayerLoopMode mode;
  final ValueChanged<CorePlayerLoopMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color color = mode == CorePlayerLoopMode.off
        ? Colors.grey
        : Theme.of(context).colorScheme.primary;
    final IconData icon = switch (mode) {
      CorePlayerLoopMode.off => Icons.repeat,
      CorePlayerLoopMode.one => Icons.repeat_one,
      CorePlayerLoopMode.all => Icons.repeat_on,
    };
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: 'Loop: ${mode.name}',
      onPressed: () {
        const List<CorePlayerLoopMode> cycle = <CorePlayerLoopMode>[
          CorePlayerLoopMode.off,
          CorePlayerLoopMode.one,
          CorePlayerLoopMode.all,
        ];
        final int next = (cycle.indexOf(mode) + 1) % cycle.length;
        onChanged(cycle[next]);
      },
    );
  }
}

/// Toggle button for shuffle.
class ShuffleButton extends StatelessWidget {
  const ShuffleButton({
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color color = enabled
        ? Theme.of(context).colorScheme.primary
        : Colors.grey;
    return IconButton(
      icon: Icon(Icons.shuffle, color: color),
      tooltip: 'Shuffle: ${enabled ? 'on' : 'off'}',
      onPressed: () => onChanged(!enabled),
    );
  }
}
