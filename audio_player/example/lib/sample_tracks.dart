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
  static final CoreAudioSource scienceFridayEpisode = HttpAudioSource(
    title: 'Science Friday — Episode',
    artist: 'Science Friday and WNYC Studios',
    url: Uri.parse(
      'https://s3.amazonaws.com/scifri-episodes/scifri20181123-episode.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/scifri-episode/600/600'),
  );

  /// Science Friday — second podcast segment, used in the playlist demo.
  static final CoreAudioSource scienceFridaySegment = HttpAudioSource(
    title: 'Science Friday — Segment',
    artist: 'Science Friday and WNYC Studios',
    url: Uri.parse(
      'https://s3.amazonaws.com/scifri-segments/scifri201711241.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/scifri-segment/600/600'),
  );

  /// SoundHelix royalty-free tracks — used in the playlist demo so we have at
  /// least three sources to demonstrate skipToNext / skipToPrevious wrap-around.
  static final CoreAudioSource soundHelix1 = HttpAudioSource(
    title: 'SoundHelix Song 1',
    artist: 'SoundHelix',
    url: Uri.parse(
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-1/600/600'),
  );

  static final CoreAudioSource soundHelix2 = HttpAudioSource(
    title: 'SoundHelix Song 2',
    artist: 'SoundHelix',
    url: Uri.parse(
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-2/600/600'),
  );

  static final CoreAudioSource soundHelix3 = HttpAudioSource(
    title: 'SoundHelix Song 3',
    artist: 'SoundHelix',
    url: Uri.parse(
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-3/600/600'),
  );

  /// HLS audio rendition from Apple's public bipbop sample.
  ///
  /// Used by the HLS demo. This is an audio-only HLS rendition (AAC segments
  /// behind an `.m3u8` manifest) — a VOD playlist hosted on
  /// `devstreaming-cdn.apple.com`, which has been live since 2014 and is the
  /// canonical reference stream Apple ships in every HLS spec update.
  ///
  /// VOD HLS gives the demo a finite, repeatable signal (the position bar
  /// converges on a real duration once the demuxer reports back). For a true
  /// live HLS feed swap in any rolling-manifest URL; libmpv handles both
  /// transparently.
  ///
  /// Verify with:
  ///   curl -I https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/a1/prog_index.m3u8
  /// Expected: HTTP/1.1 200 + Content-Type: application/x-mpegURL
  static final CoreAudioSource hlsLiveRadio = HlsAudioSource(
    title: 'BipBop Audio (HLS)',
    artist: 'Apple HLS reference',
    manifestUrl: Uri.parse(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/a1/prog_index.m3u8',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/hls-bipbop/600/600'),
  );

  static final CoreAudioSource soundHelix4 = HttpAudioSource(
    title: 'SoundHelix Song 4',
    artist: 'SoundHelix',
    url: Uri.parse(
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-4/600/600'),
  );

  static final CoreAudioSource soundHelix5 = HttpAudioSource(
    title: 'SoundHelix Song 5',
    artist: 'SoundHelix',
    url: Uri.parse(
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-5.mp3',
    ),
    artUri: Uri.parse('https://picsum.photos/seed/soundhelix-5/600/600'),
  );

  /// Bare URLs for demos that bring their own stream of segment URIs
  /// (e.g. the live-source demo). Lower-level than [playlist] — exposed so
  /// a demo can simulate a backend that emits segment URLs over time.
  static final List<Uri> soundHelixUrls = <Uri>[
    Uri.parse('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3'),
    Uri.parse('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3'),
    Uri.parse('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3'),
    Uri.parse('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3'),
    Uri.parse('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-5.mp3'),
  ];

  /// Default queue for the playlist demo.
  static final List<CoreAudioSource> playlist = <CoreAudioSource>[
    scienceFridayEpisode,
    scienceFridaySegment,
    soundHelix1,
    soundHelix2,
    soundHelix3,
  ];
}
