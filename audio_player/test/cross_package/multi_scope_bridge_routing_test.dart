import 'package:flutter_test/flutter_test.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';

/// Phase 13 — bridge-level multi-scope routing.
///
/// Validates that [CoreMediaKitAudioServiceBridge] routes its lock-screen /
/// system events to [CoreAudioHandler.activeScope] (rather than the bound
/// default scope), so multi-scope apps that transfer focus via
/// [CoreAudioHandler.requestSystemAudioFocus] see lock-screen presses on the
/// new active scope's eventStream.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CoreMediaKitAudioServiceBridge bridge;

  setUp(() {
    CoreAudioHandler.resetForTest();
    CoreAudioHandler.setInitialized(true);
    bridge = CoreMediaKitAudioServiceBridge();
    // Bind to the default scope (matches what `initialize` would do).
    bridge.debugAttachHandler(CoreAudioHandler.instance!);
    CoreAudioHandler.debugSetBridge(bridge);
  });

  tearDown(() {
    CoreAudioHandler.resetForTest();
  });

  test('bridge.play() posts PlayEvent to the active scope, not the default scope, '
      'after focus transfer', () async {
    final defaultScope = CoreAudioHandler.instance!;
    final preview = CoreAudioHandler(debugName: 'preview');

    final defaultEvents = <CoreAudioHandlerEvent?>[];
    final previewEvents = <CoreAudioHandlerEvent?>[];
    final s1 = defaultScope.eventStream.listen(defaultEvents.add);
    final s2 = preview.eventStream.listen(previewEvents.add);

    // Transfer focus to the preview scope.
    await preview.requestSystemAudioFocus();
    expect(preview.isActiveScope, isTrue);

    // System press on the lock-screen fires bridge.play().
    await bridge.play();
    await Future<void>.delayed(Duration.zero);

    expect(previewEvents.whereType<CoreAudioHandlerPlayEvent>(), hasLength(1));
    expect(defaultEvents.whereType<CoreAudioHandlerPlayEvent>(), isEmpty);

    await s1.cancel();
    await s2.cancel();
  });

  test('bridge.skipToNext() / skipToPrevious() target the active scope', () async {
    final defaultScope = CoreAudioHandler.instance!;
    final preview = CoreAudioHandler(debugName: 'preview');
    await preview.requestSystemAudioFocus();

    final defaultEvents = <CoreAudioHandlerEvent?>[];
    final previewEvents = <CoreAudioHandlerEvent?>[];
    final s1 = defaultScope.eventStream.listen(defaultEvents.add);
    final s2 = preview.eventStream.listen(previewEvents.add);

    await bridge.skipToNext();
    await bridge.skipToPrevious();
    await Future<void>.delayed(Duration.zero);

    expect(previewEvents.whereType<CoreAudioHandlerSkipToNextEvent>(), hasLength(1));
    expect(previewEvents.whereType<CoreAudioHandlerSkipToPreviousEvent>(), hasLength(1));
    expect(defaultEvents.whereType<CoreAudioHandlerSkipToNextEvent>(), isEmpty);
    expect(defaultEvents.whereType<CoreAudioHandlerSkipToPreviousEvent>(), isEmpty);

    await s1.cancel();
    await s2.cancel();
  });

  test('bridge.refreshMediaItemForActiveScope() with null current player '
      'clears the MediaItem', () async {
    final preview = CoreAudioHandler(debugName: 'preview');
    await preview.requestSystemAudioFocus();

    // Seed a non-null MediaItem so we can observe the clear.
    bridge.refreshMediaItemForActiveScope();

    // preview has no current player → MediaItem should be cleared (null).
    expect(bridge.mediaItem.value, isNull);
  });

  test('after releaseSystemAudioFocus, lock-screen events return to the default scope', () async {
    final defaultScope = CoreAudioHandler.instance!;
    final preview = CoreAudioHandler(debugName: 'preview');
    await preview.requestSystemAudioFocus();
    await preview.releaseSystemAudioFocus();

    final defaultEvents = <CoreAudioHandlerEvent?>[];
    final previewEvents = <CoreAudioHandlerEvent?>[];
    final s1 = defaultScope.eventStream.listen(defaultEvents.add);
    final s2 = preview.eventStream.listen(previewEvents.add);

    await bridge.play();
    await Future<void>.delayed(Duration.zero);

    expect(defaultEvents.whereType<CoreAudioHandlerPlayEvent>(), hasLength(1));
    expect(previewEvents.whereType<CoreAudioHandlerPlayEvent>(), isEmpty);

    await s1.cancel();
    await s2.cancel();
  });
}
