import 'package:equatable/equatable.dart';

/// Backend capabilities advertised by a [CorePlayer] instance.
///
/// Consumers query this to gate optional UI (e.g. don't render a Cast
/// button if the active engine can't cast). All fields default to false
/// at the abstract level — concrete impls override the ones they
/// support.
class CorePlayerCapabilities extends Equatable {
  const CorePlayerCapabilities({
    this.supportsLiveSource = false,
    this.supportsHls = false,
    this.supportsCrossfade = false,
    this.supportsCast = false,
    this.supportsDrm = false,
    this.supportsEqualizer = false,
  });

  /// True when [LiveAudioSource] (segment-by-segment streaming) is
  /// honoured. Engines without playlist primitives can't support this.
  final bool supportsLiveSource;

  /// True when [HlsAudioSource] manifests play directly (e.g. libmpv,
  /// AVPlayer). False when the engine only handles single-file URLs.
  final bool supportsHls;

  /// True when consecutive queue items can crossfade. Currently always
  /// false — see ROADMAP for the dual-player design that would unlock it.
  final bool supportsCrossfade;

  /// True when the engine can route playback to Chromecast / AirPlay
  /// devices. Always false for the libmpv engine.
  final bool supportsCast;

  /// True when the engine can play DRM-protected media (Widevine /
  /// FairPlay). Always false today.
  final bool supportsDrm;

  /// True when [CorePlayer.setEqualizerBands] accepts band-gain input at
  /// runtime. Engines that lack runtime EQ keep this false; the
  /// libmpv-backed wrapper flips it on once the `af=equalizer=...` plumbing
  /// is wired in.
  final bool supportsEqualizer;

  @override
  List<Object?> get props => [
    supportsLiveSource,
    supportsHls,
    supportsCrossfade,
    supportsCast,
    supportsDrm,
    supportsEqualizer,
  ];
}
