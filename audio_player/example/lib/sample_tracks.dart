import 'package:player_core/player_core.dart';

/// Sample audio sources used by the example demos.
///
/// MP3 URLs match the [just_audio example](https://github.com/ryanheise/just_audio/tree/minor/just_audio/example)
/// so playback works against real audio out of the box.
///
/// Cover art uses [picsum.photos](https://picsum.photos/) with deterministic
/// seeds so each track has a stable 600x600 image across runs. Square images
/// are required by lock-screen artwork on iOS/Android.
class SampleTracks {
  const SampleTracks._();

  /// Science Friday — single-track demo source.
  static final CorePlayerAudioSource scienceFridayEpisode = CorePlayerAudioSource(
    title: 'Science Friday — Episode',
    artist: 'Science Friday and WNYC Studios',
    album: 'Podcast',
    url: 'https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3',
    artUri: Uri.parse('https://picsum.photos/seed/scifri-episode/600/600'),
  );

  /// Science Friday — second podcast segment, used in the playlist demo.
  static final CorePlayerAudioSource scienceFridaySegment = CorePlayerAudioSource(
    title: 'Science Friday — Segment',
    artist: 'Science Friday and WNYC Studios',
    album: 'Podcast',
    url: 'https://s3.amazonaws.com/scifri-segments/scifri201711241.mp3',
    artUri: Uri.parse('https://picsum.photos/seed/scifri-segment/600/600'),
  );

  /// SoundHelix royalty-free tracks — used in the playlist demo so we have at
  /// least three sources to demonstrate skipToNext / skipToPrevious wrap-around.
  static final CorePlayerAudioSource soundHelix1 = CorePlayerAudioSource(
    title: 'SoundHelix Song 1',
    artist: 'SoundHelix',
    album: 'Royalty-Free Demo',
    url: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-1/600/600'),
  );

  static final CorePlayerAudioSource soundHelix2 = CorePlayerAudioSource(
    title: 'SoundHelix Song 2',
    artist: 'SoundHelix',
    album: 'Royalty-Free Demo',
    url: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-2/600/600'),
  );

  static final CorePlayerAudioSource soundHelix3 = CorePlayerAudioSource(
    title: 'SoundHelix Song 3',
    artist: 'SoundHelix',
    album: 'Royalty-Free Demo',
    url: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-3/600/600'),
  );

  /// Default queue for the playlist demo.
  static final List<CorePlayerAudioSource> playlist = <CorePlayerAudioSource>[
    scienceFridayEpisode,
    scienceFridaySegment,
    soundHelix1,
    soundHelix2,
    soundHelix3,
  ];
}
