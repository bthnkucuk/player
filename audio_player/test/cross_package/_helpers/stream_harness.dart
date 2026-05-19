import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:player_core/player_core.dart';

import '../../helpers/test_mocks.dart';

class StreamHarness {
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

void wirePlayer(MockPlayer mockPlayer, MockPlayerStream mockStream, MockPlayerState mockState, StreamHarness h) {
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

  // Model real media_kit behavior: open(Playlist) drives a matching
  // playlist emission on player.stream.playlist; next/previous/jump
  // advance the in-memory cursor and re-emit. This is the contract the
  // wrapper's single-source-of-truth queue projection relies on.
  Playlist? lastPlaylist;
  when(() => mockPlayer.open(any(), play: any(named: 'play'))).thenAnswer((inv) async {
    final playable = inv.positionalArguments[0];
    if (playable is Playlist) {
      lastPlaylist = playable;
      h.playlist.add(playable);
    }
  });
  when(() => mockPlayer.play()).thenAnswer((_) async {});
  when(() => mockPlayer.pause()).thenAnswer((_) async {});
  when(() => mockPlayer.stop()).thenAnswer((_) async {
    lastPlaylist = null;
  });
  when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setRate(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setVolume(any())).thenAnswer((_) async {});
  when(() => mockPlayer.setPlaylistMode(any())).thenAnswer((_) async {});
  when(() => mockPlayer.next()).thenAnswer((_) async {
    final pl = lastPlaylist;
    if (pl == null) return;
    final next = pl.index + 1 >= pl.medias.length ? 0 : pl.index + 1;
    lastPlaylist = Playlist(pl.medias, index: next);
    h.playlist.add(lastPlaylist!);
  });
  when(() => mockPlayer.previous()).thenAnswer((_) async {
    final pl = lastPlaylist;
    if (pl == null) return;
    final prev = pl.index - 1 < 0 ? pl.medias.length - 1 : pl.index - 1;
    lastPlaylist = Playlist(pl.medias, index: prev);
    h.playlist.add(lastPlaylist!);
  });
  when(() => mockPlayer.jump(any())).thenAnswer((inv) async {
    final pl = lastPlaylist;
    if (pl == null) return;
    final to = inv.positionalArguments[0] as int;
    lastPlaylist = Playlist(pl.medias, index: to);
    h.playlist.add(lastPlaylist!);
  });
  when(() => mockPlayer.setShuffle(any())).thenAnswer((_) async {});
  when(() => mockPlayer.dispose()).thenAnswer((_) async {});
}

Future<void> detachAllPlayers() async {
  for (final p in CoreAudioHandler.attachedPlayers) {
    await CoreAudioHandler.detachPlayer(p);
  }
}
