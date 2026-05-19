import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player_core/player_core.dart';

import '../sample_tracks.dart';
import '../widgets/player_controls.dart';

/// Demonstrates the 10-band parametric equalizer surface
/// (`setEqualizerBands`, `equalizerBandsStream`, `equalizerBandFrequenciesHz`).
///
/// Loads a voice-heavy track automatically so band changes are immediately
/// audible while the demo is on-screen.
class EqualizerDemo extends StatefulWidget {
  const EqualizerDemo({super.key});

  @override
  State<EqualizerDemo> createState() => _EqualizerDemoState();
}

class _EqualizerDemoState extends State<EqualizerDemo> {
  late final CorePlayer _player;
  StreamSubscription<List<double>>? _bandsSub;
  StreamSubscription<CorePlayerFailure>? _errorSub;
  // Local cache for instant slider feedback — the stream re-confirms each
  // emit but UI shouldn't wait for the async hop to repaint the thumb.
  List<double> _bands = List<double>.filled(10, 0.0);
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _player = CorePlayer.create(audioHandler: CoreAudioHandler.instance);
    _bands = List<double>.of(_player.equalizerBands);
    _bandsSub = _player.equalizerBandsStream.listen((bands) {
      if (!mounted) return;
      setState(() => _bands = List<double>.of(bands));
    });
    _errorSub = _player.errorStream.listen((failure) {
      if (!mounted) return;
      setState(() => _lastError = failure.toString());
    });
    // Demo source loaded automatically so the EQ effect is audible the
    // moment the user moves a slider.
    unawaited(_player.load(SampleTracks.scienceFridayEpisode));
  }

  @override
  void dispose() {
    _bandsSub?.cancel();
    _errorSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _applyBands(List<double> bands) async {
    try {
      await _player.setEqualizerBands(bands);
    } on CorePlayerFailure catch (e) {
      if (!mounted) return;
      setState(() => _lastError = e.toString());
    }
  }

  void _onBandChanged(int index, double value) {
    final next = List<double>.of(_bands);
    next[index] = value;
    setState(() => _bands = next);
    unawaited(_applyBands(next));
  }

  Future<void> _flatten() => _applyBands(List<double>.filled(10, 0.0));

  Future<void> _applyPreset(List<double> preset) => _applyBands(preset);

  // Pre-baked presets keyed to the equalizerBandFrequenciesHz index layout:
  // 31.25, 62.5, 125, 250, 500, 1k, 2k, 4k, 8k, 16k.
  static const List<double> _voiceBoost = <double>[
    0, 0, 0, 3, 3, 3, 0, 0, 0, 0,
  ];
  static const List<double> _bassBoost = <double>[
    6, 4, 2, 0, 0, 0, 0, 0, 0, 0,
  ];
  static const List<double> _trebleCut = <double>[
    0, 0, 0, 0, 0, 0, 0, -3, -3, -3,
  ];

  /// Format band frequency for slider labels: sub-1k as `Hz`, 1k+ as `kHz`.
  static String _formatFreq(double hz) {
    if (hz >= 1000) {
      final khz = hz / 1000;
      // Drop the decimal for whole-kHz values (e.g. 1 kHz not 1.0 kHz).
      final label = khz == khz.roundToDouble()
          ? khz.toStringAsFixed(0)
          : khz.toStringAsFixed(1);
      return '$label kHz';
    }
    return '${hz.round()} Hz';
  }

  @override
  Widget build(BuildContext context) {
    final caps = _player.capabilities;
    final supports = caps.supportsEqualizer;
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'What this demos',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "10-band parametric equalizer. Each slider controls one "
                      "band's gain (-12 dB to +12 dB). Changes apply in real "
                      "time via libmpv's `af` property. Move a slider while a "
                      "track is playing and listen — the difference is most "
                      "pronounced on bands you'd normally fight (boost the "
                      "250-1k bands to make voices cut through; cut 31-125 to "
                      "remove rumble).",
                    ),
                    if (!supports) ...<Widget>[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'The active engine does not advertise '
                          'supportsEqualizer — sliders are disabled.',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _TransportRow(player: _player),
            const SizedBox(height: 16),
            _BandSliders(
              bands: _bands,
              enabled: supports,
              onChanged: _onBandChanged,
              formatFreq: _formatFreq,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: supports ? _flatten : null,
                  icon: const Icon(Icons.tune),
                  label: const Text('Flat (reset)'),
                ),
                OutlinedButton(
                  onPressed: supports ? () => _applyPreset(_voiceBoost) : null,
                  child: const Text('Voice boost'),
                ),
                OutlinedButton(
                  onPressed: supports ? () => _applyPreset(_bassBoost) : null,
                  child: const Text('Bass boost'),
                ),
                OutlinedButton(
                  onPressed: supports ? () => _applyPreset(_trebleCut) : null,
                  child: const Text('Treble cut'),
                ),
              ],
            ),
            if (_lastError != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Error: $_lastError',
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Expected result',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '- Move any slider while a track plays — the audio '
                      'reshapes immediately.\n'
                      '- "Flat (reset)" restores neutral playback.\n'
                      '- The "Voice boost" preset makes the Science Friday '
                      "narrator's voice pop out of the mix; \"Bass boost\" "
                      'thickens it; "Treble cut" makes sibilants softer.\n'
                      '- If `capabilities.supportsEqualizer` is false on the '
                      'active engine, the sliders disable themselves and the '
                      '"What this demos" card surfaces an info banner. (Not '
                      'applicable on the libmpv engine.)',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.player});

  final CorePlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CorePlayerState>(
      stream: player.playerStateStream,
      initialData: player.playerState,
      builder: (context, stateSnap) {
        final state = stateSnap.data ?? CorePlayerState.idle;
        return StreamBuilder<bool>(
          stream: player.playingStream,
          initialData: player.isPlaying,
          builder: (context, playingSnap) {
            return PlayPauseStopButtons(
              player: player,
              state: state,
              isPlaying: playingSnap.data ?? false,
              onPlay: () => player.play(),
              onPause: () => player.pause(),
              onStop: () => player.stop(),
            );
          },
        );
      },
    );
  }
}

class _BandSliders extends StatelessWidget {
  const _BandSliders({
    required this.bands,
    required this.enabled,
    required this.onChanged,
    required this.formatFreq,
  });

  final List<double> bands;
  final bool enabled;
  final void Function(int index, double value) onChanged;
  final String Function(double hz) formatFreq;

  @override
  Widget build(BuildContext context) {
    final freqs = CorePlayer.equalizerBandFrequenciesHz;
    return Column(
      children: <Widget>[
        for (int i = 0; i < freqs.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 64,
                  child: Text(
                    formatFreq(freqs[i]),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: bands[i].clamp(-12.0, 12.0),
                    min: -12.0,
                    max: 12.0,
                    divisions: 48,
                    label: '${bands[i].toStringAsFixed(1)} dB',
                    onChanged: enabled
                        ? (v) => onChanged(i, v)
                        : null,
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '${bands[i].toStringAsFixed(1)} dB',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
