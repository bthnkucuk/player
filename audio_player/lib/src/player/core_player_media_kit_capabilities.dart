part of 'core_player_media_kit.dart';

/// Capabilities advertised by the libmpv-backed [CorePlayerMediaKit].
///
/// Cached as a top-level constant so [CorePlayerMediaKit.capabilities] is
/// allocation-free per call — consumers that read it on every frame
/// (e.g. for a feature-gated chip) don't pay an instantiation cost.
///
/// Flags reflect what the engine fundamentally supports, NOT what is
/// currently wired in any given branch:
///
/// - `supportsLiveSource` / `supportsHls` stay TRUE even before Faz S2 /
///   S3 land in this branch — they advertise engine capability so
///   sibling consumer apps can ship feature-gated UI ahead of the wiring.
/// - `supportsEqualizer` stays FALSE even though libmpv supports
///   `--af=equalizer=...` — the wrapper has not yet exposed a typed
///   `setEqualizerBands` API and the flag MUST mirror the public surface.
/// - `supportsCrossfade` / `supportsCast` / `supportsDrm` are engine
///   non-support: libmpv cannot do them.
const CorePlayerCapabilities _kMediaKitCapabilities = CorePlayerCapabilities(
  supportsLiveSource: true,
  supportsHls: true,
  supportsCrossfade: false,
  supportsCast: false,
  supportsDrm: false,
  supportsEqualizer: false,
);
