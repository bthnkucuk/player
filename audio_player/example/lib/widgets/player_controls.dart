import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

/// Big play / pause / stop button row that adapts to [CorePlayerState] and
/// [isPlaying]. Renders a progress indicator while loading, a replay icon
/// when completed, and a play/pause toggle otherwise.
class PlayPauseStopButtons extends StatelessWidget {
  const PlayPauseStopButtons({
    required this.state,
    required this.isPlaying,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    this.showStop = true,
    super.key,
  });

  final CorePlayerState state;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final bool showStop;

  @override
  Widget build(BuildContext context) {
    final Widget primary;
    if (state == CorePlayerState.loading) {
      primary = const SizedBox(
        width: 56,
        height: 56,
        child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
      );
    } else if (state == CorePlayerState.completed) {
      primary = IconButton(iconSize: 56, icon: const Icon(Icons.replay), onPressed: onPlay);
    } else if (isPlaying) {
      primary = IconButton(iconSize: 56, icon: const Icon(Icons.pause_circle_filled), onPressed: onPause);
    } else {
      primary = IconButton(iconSize: 56, icon: const Icon(Icons.play_circle_filled), onPressed: onPlay);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        primary,
        if (showStop) ...<Widget>[
          const SizedBox(width: 16),
          IconButton(iconSize: 40, icon: const Icon(Icons.stop_circle), onPressed: onStop),
        ],
      ],
    );
  }
}

/// Drop-down for playback speed.
class SpeedDropdown extends StatelessWidget {
  const SpeedDropdown({required this.speed, required this.onChanged, super.key});

  final double speed;
  final ValueChanged<double> onChanged;

  static const List<double> _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final double rounded = _speeds.reduce((double a, double b) => (a - speed).abs() < (b - speed).abs() ? a : b);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.speed),
        const SizedBox(width: 8),
        DropdownButton<double>(
          value: rounded,
          items: <DropdownMenuItem<double>>[
            for (final double s in _speeds) DropdownMenuItem<double>(value: s, child: Text('${s}x')),
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
  const VolumeSlider({required this.volume, required this.onChanged, super.key});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.volume_down),
        Expanded(
          child: Slider(min: 0, max: 1, value: volume.clamp(0.0, 1.0), onChanged: onChanged),
        ),
        const Icon(Icons.volume_up),
      ],
    );
  }
}

/// Cycle button: off → one → all → off …
class LoopModeButton extends StatelessWidget {
  const LoopModeButton({required this.mode, required this.onChanged, super.key});

  final CorePlayerLoopMode mode;
  final ValueChanged<CorePlayerLoopMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color color = mode == CorePlayerLoopMode.off ? Colors.grey : Theme.of(context).colorScheme.primary;
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
  const ShuffleButton({required this.enabled, required this.onChanged, super.key});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color color = enabled ? Theme.of(context).colorScheme.primary : Colors.grey;
    return IconButton(
      icon: Icon(Icons.shuffle, color: color),
      tooltip: 'Shuffle: ${enabled ? 'on' : 'off'}',
      onPressed: () => onChanged(!enabled),
    );
  }
}
