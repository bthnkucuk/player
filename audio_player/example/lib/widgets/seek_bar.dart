import 'package:flutter/material.dart';

/// Position slider that shows current position, buffered position and total
/// duration. Calls [onSeek] with the chosen value once the user releases the
/// slider; live drag updates are local-only so we don't fire a seek per frame.
///
/// Two layouts:
///  * default — slider + buffer band + `MM:SS` position/duration labels.
///  * [SeekBar.compact] — slider + buffer band only, no labels (for tight
///    multi-scope cards or dense lists).
///
/// When [duration] is [Duration.zero] (still loading) the slider is disabled
/// and labels render as `--:--` so the user can't drag a meaningless thumb.
class SeekBar extends StatefulWidget {
  const SeekBar({
    required this.duration,
    required this.position,
    required this.bufferedPosition,
    required this.onSeek,
    super.key,
  }) : compact = false;

  /// Compact variant — same controls and buffer band, but no time labels.
  /// Useful for multi-player surfaces (per-scope cards, mini players).
  const SeekBar.compact({
    required this.duration,
    required this.position,
    required this.bufferedPosition,
    required this.onSeek,
    super.key,
  }) : compact = true;

  final Duration duration;
  final Duration position;
  final Duration bufferedPosition;
  final ValueChanged<Duration> onSeek;
  final bool compact;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final double durationMs = widget.duration.inMilliseconds.toDouble();
    final bool isLoading = durationMs <= 0;

    final double sliderMax = isLoading ? 1.0 : durationMs;
    final double positionMs = widget.position.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final double bufferedMs = widget.bufferedPosition.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final double sliderValue = _dragValue ?? positionMs;
    final double bufferedFraction = isLoading ? 0.0 : (bufferedMs / sliderMax).clamp(0.0, 1.0);

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color bufferedColor = scheme.primary.withValues(alpha: 0.4);
    final Color bufferedTrack = scheme.onSurface.withValues(alpha: 0.08);

    final Widget track = SizedBox(
      height: widget.compact ? 28 : 36,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Buffered band — sits BEHIND the slider so the playhead reads on top.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: bufferedFraction,
                minHeight: 6,
                backgroundColor: bufferedTrack,
                valueColor: AlwaysStoppedAnimation<Color>(bufferedColor),
              ),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              // Transparent track lets the buffered band show through; the
              // active (played) portion still gets the primary color.
              inactiveTrackColor: Colors.transparent,
            ),
            child: Slider(
              min: 0,
              max: sliderMax,
              value: sliderValue.clamp(0.0, sliderMax),
              onChanged: isLoading
                  ? null
                  : (double value) {
                      setState(() => _dragValue = value);
                    },
              onChangeEnd: isLoading
                  ? null
                  : (double value) {
                      widget.onSeek(Duration(milliseconds: value.round()));
                      setState(() => _dragValue = null);
                    },
            ),
          ),
        ],
      ),
    );

    if (widget.compact) return track;

    final String positionLabel = isLoading ? '--:--' : _formatDuration(widget.position);
    final String durationLabel = isLoading ? '--:--' : _formatDuration(widget.duration);
    // Hide the buffered label when nothing has been pre-fetched yet — cleaner
    // than rendering `Buffered: --:--` for the brief pre-buffer window.
    final bool showBufferedLabel = !isLoading && widget.bufferedPosition > Duration.zero;
    final String bufferedLabel = showBufferedLabel ? 'Buffered: ${_formatDuration(widget.bufferedPosition)}' : '';

    const TextStyle tabular = TextStyle(fontFeatures: <FontFeature>[FontFeature.tabularFigures()]);
    final TextStyle bufferedStyle = tabular.copyWith(color: scheme.onSurface.withValues(alpha: 0.6), fontSize: 12);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        track,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: <Widget>[
              Expanded(child: Text(positionLabel, style: tabular)),
              Text(bufferedLabel, style: bufferedStyle),
              Expanded(
                child: Text(durationLabel, style: tabular, textAlign: TextAlign.right),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Formats a [Duration] as `M:SS` (under an hour) or `H:MM:SS` (over an hour).
/// [Duration.zero] renders as `0:00` — never `0:00:00`.
String _formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final int totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '$minutes:${two(seconds)}';
}
