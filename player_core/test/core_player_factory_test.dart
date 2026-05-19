import 'package:test/test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);
  setUp(CorePlayer.debugClearFactory);
  tearDown(CorePlayer.debugClearFactory);

  group('CorePlayer factory', () {
    test('create throws StateError when no factory registered', () {
      expect(CorePlayer.create, throwsA(isA<StateError>()));
      expect(CorePlayer.isFactoryRegistered, isFalse);
    });

    test('registerFactory then create dispatches to factory', () {
      var calls = 0;
      late CorePlayer fake;
      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
        calls++;
        return fake = _FakeTuPlayer();
      });

      expect(CorePlayer.isFactoryRegistered, isTrue);
      final result = CorePlayer.create();
      expect(result, same(fake));
      expect(calls, 1);
    });

    test('registerFactory twice replaces the previous registration', () {
      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) => _FakeTuPlayer());
      final first = CorePlayer.create();

      late CorePlayer second;
      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) => second = _FakeTuPlayer());
      expect(CorePlayer.create(), same(second));
      expect(CorePlayer.create(), isNot(same(first)));
    });

    test('create forwards all args to factory', () {
      CoreAudioSource? capturedSource;
      CoreAudioHandler? capturedHandler;
      bool? capturedAutoLoad;
      CorePlayer.registerFactory(({audioSource, audioHandler, autoLoad = false}) {
        capturedSource = audioSource;
        capturedHandler = audioHandler;
        capturedAutoLoad = autoLoad;
        return _FakeTuPlayer();
      });

      final src = HttpAudioSource(title: 'x', url: Uri.parse('https://x'));
      CorePlayer.create(audioSource: src, autoLoad: true);
      expect(capturedSource, same(src));
      expect(capturedHandler, isNull);
      expect(capturedAutoLoad, isTrue);
    });
  });
}

/// Minimal stand-in for [CorePlayer]. Concrete impl required because [CorePlayer]
/// has a default constructor — `noSuchMethod` covers the rest of the surface
/// that these factory tests never exercise.
class _FakeTuPlayer extends CorePlayer {
  @override
  CoreAudioSource? get audioSource => null;
  @override
  ValueStream<CoreAudioSource?> get audioSourceStream => BehaviorSubject<CoreAudioSource?>.seeded(null).stream;
  @override
  CoreAudioHandler? get audioHandler => null;
  @override
  bool get autoLoad => false;
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
  ValueStream<CorePlayerPositionData> get positionDataStream =>
      BehaviorSubject<CorePlayerPositionData>.seeded(
        (position: Duration.zero, duration: Duration.zero),
      ).stream;
  @override
  CorePlayerState get playerState => CorePlayerState.idle;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  Duration get buffer => Duration.zero;
  @override
  bool get isPlaying => false;
  @override
  bool get isDisposed => false;
  @override
  Future<void> load(CoreAudioSource audioSource) async {}
  @override
  Future<void> loadAndPlay(CoreAudioSource audioSource) async {}
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
  Future<void> insertNext(CoreAudioSource source) async {}
  @override
  Future<void> appendToQueue(CoreAudioSource source) async {}
  @override
  Future<void> appendAllToQueue(List<CoreAudioSource> sources) async {}
  @override
  Future<void> removeAt(int index) async {}
  @override
  Future<void> moveItem(int from, int to) async {}
  @override
  Future<void> replaceAt(
    int index,
    CoreAudioSource source, {
    bool preservePosition = false,
  }) async {}
  @override
  Future<void> play({Duration? position}) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  double get playbackSpeed => 1.0;
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
  Future<void> stop({bool fromDispose = false}) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> waitForReady({Duration? timeout}) async {}
}
