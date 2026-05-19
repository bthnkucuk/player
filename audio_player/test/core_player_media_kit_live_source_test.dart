import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'helpers/test_mocks.dart';

/// Live-source tests parallel the queue-mutation suite's MockPlayer +
/// StreamHarness pattern. Each segment emission is asserted at the native
/// `player.add(Media(...))` boundary, the wrapper-side `_sources` mirror,
/// and the projected `queueStream`. Cleanup invariants (cancel on
/// setQueue / dispose) round out the suite.

class _FakeMedia extends Fake implements Media {}

class _StreamHarness {
  final duration = StreamController<Duration>.broadcast();
  final position = StreamController<Duration>.broadcast();
  final buffer = StreamController<Duration>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final error = StreamController<String>.broadcast();
  final completed = StreamController<bool>.broadcast();
  final rate = StreamController<double>.broadcast();
  final volume = StreamController<double>.broadcast();
  final playlist = StreamController<Playlist>.broadcast();
  final shuffle = StreamController<bool>.broadcast();

  Future<void> close() async {
    await duration.close();
    await position.close();
    await buffer.close();
    await buffering.close();
    await playing.close();
    await error.close();
    await completed.close();
    await rate.close();
    await volume.close();
    await playlist.close();
    await shuffle.close();
  }
}

class _MockPlaylistState {
  final List<Media> medias = [];
  int index = 0;
}

/// Capture-list for `player.add(Media)` calls — tests inspect the URI the
/// wrapper handed to media_kit for each segment emission.
final List<Media> _addedMedias = [];

void _wireMockStreams(
  MockPlayer mockPlayer,
  MockPlayerStream mockStream,
  MockPlayerState mockState,
  _StreamHarness h,
  _MockPlaylistState pl,
) {
  when(() => mockPlayer.stream).thenReturn(mockStream);
  when(() => mockPlayer.state).thenReturn(mockState);

  when(() => mockStream.duration).thenAnswer((_) => h.duration.stream);
  when(() => mockStream.position).thenAnswer((_) => h.position.stream);
  when(() => mockStream.buffer).thenAnswer((_) => h.buffer.stream);
  when(() => mockStream.buffering).thenAnswer((_) => h.buffering.stream);
  when(() => mockStream.playing).thenAnswer((_) => h.playing.stream);
  when(() => mockStream.error).thenAnswer((_) => h.error.stream);
  when(() => mockStream.completed).thenAnswer((_) => h.completed.stream);
  when(() => mockStream.rate).thenAnswer((_) => h.rate.stream);
  when(() => mockStream.volume).thenAnswer((_) => h.volume.stream);
  when(() => mockStream.playlist).thenAnswer((_) => h.playlist.stream);
  when(() => mockStream.shuffle).thenAnswer((_) => h.shuffle.stream);

  when(() => mockState.duration).thenReturn(Duration.zero);
  when(() => mockState.position).thenReturn(Duration.zero);
  when(() => mockState.buffer).thenReturn(Duration.zero);
  when(() => mockState.playing).thenReturn(false);
  when(() => mockState.rate).thenReturn(1.0);
  when(() => mockState.volume).thenReturn(100.0);

  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((
    inv,
  ) async {
    final playable = inv.positionalArguments[0];
    if (playable is Playlist) {
      pl.medias
        ..clear()
        ..addAll(playable.medias);
      pl.index = playable.index;
      h.playlist.add(playable);
    }
  });
  when(() => mockPlayer.play()).thenAnswer((_) async {});
  when(() => mockPlayer.pause()).thenAnswer((_) async {});
  when(() => mockPlayer.stop()).thenAnswer((_) async {});
  when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setRate(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setVolume(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setPlaylistMode(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setShuffle(any())).thenAnswer((_) async {});
  when(() => mockPlayer.next()).thenAnswer((_) async {});
  when(() => mockPlayer.previous()).thenAnswer((_) async {});
  when(() => mockPlayer.jump(any())).thenAnswer((_) async {});

  // Capture every `add` so the test can assert URI + header propagation.
  when(() => mockPlayer.add(any())).thenAnswer((inv) async {
    final media = inv.positionalArguments[0] as Media;
    _addedMedias.add(media);
    pl.medias.add(media);
    h.playlist.add(Playlist(List.of(pl.medias), index: pl.index));
  });
  when(() => mockPlayer.remove(any())).thenAnswer((inv) async {
    final i = inv.positionalArguments[0] as int;
    if (i < 0 || i >= pl.medias.length) return;
    pl.medias.removeAt(i);
    if (pl.index > i) {
      pl.index--;
    } else if (pl.index == i && pl.index >= pl.medias.length) {
      pl.index = pl.medias.isEmpty ? 0 : pl.medias.length - 1;
    }
    h.playlist.add(Playlist(List.of(pl.medias), index: pl.index));
  });
  when(() => mockPlayer.move(any(), any())).thenAnswer((inv) async {
    final from = inv.positionalArguments[0] as int;
    final to = inv.positionalArguments[1] as int;
    if (from < 0 || from >= pl.medias.length) return;
    final m = pl.medias.removeAt(from);
    final insertAt = to > from ? to - 1 : to;
    pl.medias.insert(insertAt, m);
    h.playlist.add(Playlist(List.of(pl.medias), index: pl.index));
  });
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

void main() {
  late MockPlayer mockPlayer;
  late MockPlayerStream mockStream;
  late MockPlayerState mockState;
  late _StreamHarness h;
  late _MockPlaylistState pl;
  late CorePlayerMediaKit player;

  setUpAll(() {
    registerMediaKitTestFallbacks();
    registerFallbackValue(_FakeMedia());
    CoreAudioHandler.setInitialized(true);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(internalPositionThrottle: Duration.zero),
    );
  });

  tearDownAll(() {
    CoreAudioHandler.setInitialized(false);
    CorePlayerMediaKit.debugSetConfigurationForTest(
      const CorePlayerConfiguration(),
    );
  });

  setUp(() {
    mockPlayer = MockPlayer();
    mockStream = MockPlayerStream();
    mockState = MockPlayerState();
    h = _StreamHarness();
    pl = _MockPlaylistState();
    _addedMedias.clear();
    _wireMockStreams(mockPlayer, mockStream, mockState, h, pl);
    player = CorePlayerMediaKit(testPlayer: mockPlayer);
  });

  tearDown(() async {
    if (!player.isDisposed) {
      await player.dispose();
    }
    await h.close();
  });

  // A short non-live source the demos pin into the seed position so live
  // sources without initialUrl can still ride alongside.
  final seedHttp = HttpAudioSource(
    title: 'Seed HTTP',
    url: Uri.parse('https://example.com/seed.mp3'),
  );

  Uri segmentUri(int i) => Uri.parse('https://example.com/seg-$i.mp3');

  test(
    'empty live source (stream closes without emitting) leaves the queue '
    'with no segments contributed; a sibling HTTP source plays normally',
    () async {
      final controller = StreamController<Uri>();
      final live = LiveAudioSource(
        segmentUrlStream: controller.stream,
        title: 'Live',
      );
      // Place the live source LAST so the active position lands on the
      // sibling HTTP source — this is the legal v1 shape for a seedless
      // live source.
      await player.setQueue(
        CorePlayerQueue(<CoreAudioSource>[seedHttp, live]),
      );
      await Future<void>.delayed(Duration.zero);

      // The seedless live source contributes nothing at open time, so the
      // playlist is just the HTTP seed.
      expect(player.queue.length, 1);
      expect(player.queue.sources.first, seedHttp);

      // Close the stream without emitting: the live subscription tears
      // itself down on `onDone`.
      await controller.close();
      await Future<void>.delayed(Duration.zero);
      expect(player.debugLiveSubscriptionCount, 0);
    },
  );

  test('stream emits 3 URLs serially -> 3 sibling queue entries in order', () async {
    final controller = StreamController<Uri>();
    final initialUri = Uri.parse('https://example.com/initial.mp3');
    final live = LiveAudioSource(
      segmentUrlStream: controller.stream,
      title: 'Live',
      initialUrl: initialUri,
    );
    await player.setQueue(CorePlayerQueue(<CoreAudioSource>[live]));
    await Future<void>.delayed(Duration.zero);

    // The initialUrl seed is the first entry.
    expect(player.queue.sources.length, 1);

    controller.add(segmentUri(1));
    await Future<void>.delayed(Duration.zero);
    controller.add(segmentUri(2));
    await Future<void>.delayed(Duration.zero);
    controller.add(segmentUri(3));
    await Future<void>.delayed(Duration.zero);

    expect(player.queue.sources.length, 4); // initial + 3 emitted

    // Native side: one `add` per emitted URL (open() handled the seed).
    expect(_addedMedias.length, 3);
    expect(_addedMedias[0].uri, segmentUri(1).toString());
    expect(_addedMedias[1].uri, segmentUri(2).toString());
    expect(_addedMedias[2].uri, segmentUri(3).toString());

    await controller.close();
  });

  test(
    'stream emits while playing: appends do not re-open or reset position',
    () async {
      final controller = StreamController<Uri>();
      final live = LiveAudioSource(
        segmentUrlStream: controller.stream,
        title: 'Live',
        initialUrl: Uri.parse('https://example.com/initial.mp3'),
      );
      await player.setQueue(CorePlayerQueue(<CoreAudioSource>[live]));
      await Future<void>.delayed(Duration.zero);

      // Simulate ongoing playback at t=12s.
      h.position.add(const Duration(seconds: 12));
      await Future<void>.delayed(Duration.zero);
      expect(player.position, const Duration(seconds: 12));

      // open() was called once for setQueue; we will verify no additional
      // open() fires for either append.
      controller.add(segmentUri(1));
      controller.add(segmentUri(2));
      await Future<void>.delayed(Duration.zero);

      verify(() => mockPlayer.open(any(), play: any(named: 'play'))).called(1);
      // Position must not reset (wrapper never re-emits zero on append).
      expect(player.position, const Duration(seconds: 12));
      expect(_addedMedias.length, 2);

      await controller.close();
    },
  );

  test('initialUrl is seeded first; subsequent emissions follow', () async {
    final controller = StreamController<Uri>();
    final initial = Uri.parse('https://example.com/initial.mp3');
    final live = LiveAudioSource(
      segmentUrlStream: controller.stream,
      title: 'Live',
      initialUrl: initial,
    );
    await player.setQueue(CorePlayerQueue(<CoreAudioSource>[live]));
    await Future<void>.delayed(Duration.zero);

    // Open() received a Playlist whose first media is the initialUrl.
    final openCalls = verify(
      () => mockPlayer.open(captureAny(), play: any(named: 'play')),
    ).captured;
    expect(openCalls, hasLength(1));
    final playlistPassed = openCalls.first as Playlist;
    expect(playlistPassed.medias, hasLength(1));
    expect(playlistPassed.medias.first.uri, initial.toString());

    controller.add(segmentUri(1));
    await Future<void>.delayed(Duration.zero);
    expect(_addedMedias.first.uri, segmentUri(1).toString());

    await controller.close();
  });

  test('dispose during live cancels the subscription; no post-dispose adds', () async {
    final controller = StreamController<Uri>();
    final live = LiveAudioSource(
      segmentUrlStream: controller.stream,
      title: 'Live',
      initialUrl: Uri.parse('https://example.com/initial.mp3'),
    );
    await player.setQueue(CorePlayerQueue(<CoreAudioSource>[live]));
    await Future<void>.delayed(Duration.zero);
    expect(player.debugLiveSubscriptionCount, 1);

    await player.dispose();

    // Late emission after dispose: must NOT translate into a `player.add`.
    final priorCount = _addedMedias.length;
    controller.add(segmentUri(99));
    await Future<void>.delayed(Duration.zero);
    expect(_addedMedias.length, priorCount);
    await controller.close();
  });

  test('setQueue replacing the live source cancels its subscription', () async {
    final controller = StreamController<Uri>();
    final live = LiveAudioSource(
      segmentUrlStream: controller.stream,
      title: 'Live',
      initialUrl: Uri.parse('https://example.com/initial.mp3'),
    );
    await player.setQueue(CorePlayerQueue(<CoreAudioSource>[live]));
    await Future<void>.delayed(Duration.zero);
    expect(player.debugLiveSubscriptionCount, 1);

    // Replace the queue with a different (non-live) source.
    await player.setQueue(CorePlayerQueue(<CoreAudioSource>[seedHttp]));
    await Future<void>.delayed(Duration.zero);
    expect(player.debugLiveSubscriptionCount, 0);

    // Emission after replacement must not append.
    final priorCount = _addedMedias.length;
    controller.add(segmentUri(99));
    await Future<void>.delayed(Duration.zero);
    expect(_addedMedias.length, priorCount);
    await controller.close();
  });

  test('headers from LiveAudioSource flow into each appended Media', () async {
    final controller = StreamController<Uri>();
    const headers = <String, String>{'Authorization': 'Bearer xyz'};
    final live = LiveAudioSource(
      segmentUrlStream: controller.stream,
      title: 'Live',
      initialUrl: Uri.parse('https://example.com/initial.mp3'),
      headers: headers,
    );
    await player.setQueue(CorePlayerQueue(<CoreAudioSource>[live]));
    await Future<void>.delayed(Duration.zero);

    controller.add(segmentUri(1));
    await Future<void>.delayed(Duration.zero);

    expect(_addedMedias.first.httpHeaders, headers);
    await controller.close();
  });
}
