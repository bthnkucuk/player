part of 'core_player_media_kit.dart';

/// Signature for the seam that pushes an `equalizer=...` filter spec onto
/// a constructed [Player]. Production wires this to a closure that calls
/// `(player.platform as dynamic).setProperty('af', spec)`; tests inject a
/// capture-only implementation so the libmpv `af` property string can be
/// inspected without needing a real `NativePlayer`.
///
/// Mirrors the [LibmpvOptionsApplier] seam pattern used by the rest of the
/// libmpv property surface — a top-level applier reference plus a
/// `debugSet...ForTest` override hook.
typedef EqualizerApplier =
    Future<void> Function(Player player, String afSpec);

EqualizerApplier _equalizerApplier = _defaultEqualizerApplier;

/// Test seam: override the production applier so unit tests can capture the
/// `af=equalizer=...` spec that the wrapper would push at libmpv. Pass
/// `null` to restore the production applier.
@visibleForTesting
void debugSetEqualizerApplierForTest(EqualizerApplier? applier) {
  _equalizerApplier = applier ?? _defaultEqualizerApplier;
}

Future<void> _defaultEqualizerApplier(Player player, String afSpec) async {
  final platform = player.platform;
  // No native handle yet (very early in construction, or non-libmpv build) —
  // nothing to do. The wrapper still updates the subject so a later
  // `platform` attach can read [CorePlayer.equalizerBands] and re-apply.
  if (platform == null) return;
  final dynamic native = platform;
  try {
    await native.setProperty('af', afSpec);
  } on Object catch (e, s) {
    CorePlayerMediaKit.log(
      'libmpv setProperty failed for af=$afSpec',
      error: e,
      stackTrace: s,
    );
    // Convert into a typed failure so the wrapper's call site can route
    // through `_throwAndEmit` and surface on `errorStream` as well.
    throw UnsupportedFeatureFailure('Equalizer not supported: $e');
  }
}

/// Snapshot of the flat / zeroed equalizer state. Cached as a top-level
/// `final` so the seed allocation happens once per process.
final List<double> _kEqualizerFlat = List<double>.unmodifiable(
  List<double>.filled(10, 0.0),
);

/// Format a band list as libmpv's `equalizer` filter expects:
/// `equalizer=g0:g1:...:g9`. One decimal place keeps the property string
/// compact and predictable to compare against in tests.
String _formatEqualizerSpec(List<double> gains) {
  return 'equalizer=${gains.map((g) => g.toStringAsFixed(1)).join(':')}';
}
