import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';

class MockPlayer extends Mock implements Player {}

class MockPlayerStream extends Mock implements PlayerStream {}

class MockPlayerState extends Mock implements PlayerState {}

class FakePlayable extends Fake implements Playable {}

void registerMediaKitTestFallbacks() {
  registerFallbackValue(FakePlayable());
  registerFallbackValue(Duration.zero);
  registerFallbackValue(0.0);
  registerFallbackValue(PlaylistMode.none);
}

/// Install a fresh [CoreMediaKitAudioServiceBridge] into the [CoreAudioHandler]
/// for tests that need to inspect the bridge's `PlaybackState` / `MediaItem`
/// streams (the audio_service-typed surface that the abstraction now hides).
///
/// The bridge is constructed without running [CoreMediaKitAudioServiceBridge.initialize],
/// so it has no `AudioSession` configured. Tests can drive
/// `bridge.playbackState` / `bridge.mediaItem` directly without touching any
/// platform channels.
CoreMediaKitAudioServiceBridge installTestBridge() {
  final bridge = CoreMediaKitAudioServiceBridge();
  CoreAudioHandler.debugSetBridge(bridge);
  // Wire the bridge to the registry so its play/pause/seek/stop overrides
  // can fan events into `handler.eventStream` without running the real
  // [initialize] flow (which would touch AudioService.init).
  final handler = CoreAudioHandler.instance;
  if (handler != null) {
    bridge.debugAttachHandler(handler);
  }
  return bridge;
}

/// Resolve the currently installed bridge as a [CoreMediaKitAudioServiceBridge].
/// Throws if no bridge / wrong bridge type is installed.
CoreMediaKitAudioServiceBridge requireTestBridge() {
  final bridge = CoreAudioHandler.debugBridge;
  if (bridge is! CoreMediaKitAudioServiceBridge) {
    throw StateError(
      'Expected CoreMediaKitAudioServiceBridge to be installed; '
      'call installTestBridge() in setUp. Got: ${bridge?.runtimeType}',
    );
  }
  return bridge;
}
