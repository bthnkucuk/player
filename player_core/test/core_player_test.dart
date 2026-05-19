import 'package:test/test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

class _FakeTuPlayer extends CorePlayer {
  _FakeTuPlayer();

  @override
  CorePlayerAudioSource? get audioSource => null;

  @override
  ValueStream<CorePlayerAudioSource?> get audioSourceStream => BehaviorSubject<CorePlayerAudioSource?>.seeded(null).stream;

  @override
  CoreAudioHandler? get audioHandler => null;

  @override
  bool get autoLoad => false;

  @override
  bool get isDisposed => false;

  @override
  bool get isPlaying => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => Duration.zero;

  @override
  Duration get buffer => Duration.zero;

  @override
  CorePlayerState get playerState => CorePlayerState.idle;

  @override
  ValueStream<CorePlayerState> get playerStateStream => BehaviorSubject<CorePlayerState>.seeded(CorePlayerState.idle).stream;

  @override
  ValueStream<Duration> get positionStream => BehaviorSubject<Duration>.seeded(Duration.zero).stream;

  @override
  ValueStream<Duration> get durationStream => BehaviorSubject<Duration>.seeded(Duration.zero).stream;

  @override
  ValueStream<Duration> get bufferStream => BehaviorSubject<Duration>.seeded(Duration.zero).stream;

  @override
  ValueStream<bool> get playingStream => BehaviorSubject<bool>.seeded(false).stream;

  @override
  double get playbackSpeed => 1;

  @override
  ValueStream<double> get playbackSpeedStream => BehaviorSubject<double>.seeded(1.0).stream;

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  double get volume => 1.0;

  @override
  ValueStream<double> get volumeStream => BehaviorSubject<double>.seeded(1.0).stream;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  CorePlayerLoopMode get loopMode => CorePlayerLoopMode.off;

  @override
  ValueStream<CorePlayerLoopMode> get loopModeStream =>
      BehaviorSubject<CorePlayerLoopMode>.seeded(CorePlayerLoopMode.off).stream;

  @override
  Future<void> setLoopMode(CorePlayerLoopMode mode) async {}

  @override
  bool get shuffle => false;

  @override
  ValueStream<bool> get shuffleStream => BehaviorSubject<bool>.seeded(false).stream;

  @override
  Future<void> setShuffle(bool enabled) async {}

  @override
  Stream<CorePlayerFailure> get errorStream => const Stream<CorePlayerFailure>.empty();

  @override
  Future<void> pause() async {}

  @override
  Future<void> play({Duration? position}) async {}

  @override
  Future<void> stop({bool fromDispose = false}) async {}

  @override
  Future<void> load(CorePlayerAudioSource audioSource) async {}

  @override
  Future<void> loadAndPlay(CorePlayerAudioSource audioSource) async {}

  @override
  CorePlayerQueue get queue => const CorePlayerQueue.empty();

  @override
  ValueStream<CorePlayerQueue> get queueStream =>
      BehaviorSubject<CorePlayerQueue>.seeded(const CorePlayerQueue.empty()).stream;

  @override
  Future<void> setQueue(CorePlayerQueue queue) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> skipToIndex(int index) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> waitForReady({Duration? timeout}) async {}
}

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerState', () {
    test('should expose all expected enum values', () {
      expect(CorePlayerState.values, [
        CorePlayerState.error,
        CorePlayerState.loading,
        CorePlayerState.ready,
        CorePlayerState.idle,
        CorePlayerState.completed,
      ]);
    });

    test('should resolve every variant in an exhaustive switch', () {
      String label(CorePlayerState s) {
        switch (s) {
          case CorePlayerState.error:
            return 'error';
          case CorePlayerState.loading:
            return 'loading';
          case CorePlayerState.ready:
            return 'ready';
          case CorePlayerState.idle:
            return 'idle';
          case CorePlayerState.completed:
            return 'completed';
        }
      }

      expect(CorePlayerState.values.map(label).toList(), ['error', 'loading', 'ready', 'idle', 'completed']);
    });
  });

  group('CorePlayer (abstract)', () {
    test('uses identity equality (distinct instances are not equal)', () {
      final a = _FakeTuPlayer();
      final b = _FakeTuPlayer();

      expect(a, isNot(equals(b)));
      expect(a, equals(a));
      expect(identical(a, b), isFalse);
      expect(identical(a, a), isTrue);
    });
  });

  group('CorePlayer.observer (Phase 9d #2)', () {
    tearDown(() => CorePlayer.observer = null);

    test('defaults to null', () {
      CorePlayer.observer = null;
      expect(CorePlayer.observer, isNull);
    });

    test('can be set and cleared', () {
      final observer = _RecordingObserver();
      CorePlayer.observer = observer;
      expect(CorePlayer.observer, same(observer));
      CorePlayer.observer = null;
      expect(CorePlayer.observer, isNull);
    });

    test('default callbacks are no-ops (do not throw)', () {
      const base = _DefaultObserver();
      final player = _FakeTuPlayer();
      const src = CorePlayerAudioSource(title: 't', url: 'https://example.com/a.mp3');
      base.onCreate(player);
      base.onLoad(player, src);
      base.onPlay(player);
      base.onPause(player);
      base.onStop(player);
      base.onSeek(player, Duration.zero);
      base.onStateChange(player, CorePlayerState.idle, CorePlayerState.ready);
      base.onError(player, const PlayerDisposedFailure());
      base.onDispose(player);
    });
  });
}

/// Records every observer call. Used to verify dispatch from the impl tests.
class _RecordingObserver extends CorePlayerObserver {
  final calls = <String>[];
  @override
  void onCreate(CorePlayer player) => calls.add('onCreate');
  @override
  void onLoad(CorePlayer player, CorePlayerAudioSource source) => calls.add('onLoad:${source.title}');
  @override
  void onPlay(CorePlayer player) => calls.add('onPlay');
  @override
  void onPause(CorePlayer player) => calls.add('onPause');
  @override
  void onStop(CorePlayer player) => calls.add('onStop');
  @override
  void onSeek(CorePlayer player, Duration position) => calls.add('onSeek:$position');
  @override
  void onStateChange(CorePlayer player, CorePlayerState from, CorePlayerState to) => calls.add('onStateChange:$from->$to');
  @override
  void onError(CorePlayer player, CorePlayerFailure failure) => calls.add('onError:${failure.runtimeType}');
  @override
  void onDispose(CorePlayer player) => calls.add('onDispose');
}

class _DefaultObserver extends CorePlayerObserver {
  const _DefaultObserver();
}
