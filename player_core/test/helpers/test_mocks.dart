import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';

class MockTuPlayer extends Mock implements CorePlayer {}

class _FakeTuAudioHandler extends Fake implements CoreAudioHandler {}

/// Call once per test isolate before using a [Mock] implementing
/// [CoreAudioServiceBridge] with `any()` matchers on `initialize`.
void registerTuPlayerTestFallbacks() {
  registerFallbackValue(_FakeTuAudioHandler());
}
