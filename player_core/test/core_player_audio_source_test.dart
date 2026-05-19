import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('HttpAudioSource', () {
    group('constructor', () {
      test('should construct with url and required title', () {
        final source = HttpAudioSource(
          title: 'Title',
          url: Uri.parse('https://example.com/a.mp3'),
        );

        expect(source.title, 'Title');
        expect(source.url, Uri.parse('https://example.com/a.mp3'));
        expect(source.artist, isNull);
        expect(source.artUri, isNull);
        expect(source.headers, isNull);
        expect(source.estimatedDuration, isNull);
      });

      test('should construct with all metadata fields populated', () {
        final artUri = Uri.parse('https://example.com/cover.png');
        final source = HttpAudioSource(
          title: 'Full',
          url: Uri.parse('https://example.com/full.mp3'),
          artist: 'Artist',
          artUri: artUri,
          estimatedDuration: const Duration(minutes: 3),
          headers: const {'Authorization': 'Bearer t'},
        );

        expect(source.title, 'Full');
        expect(source.url, Uri.parse('https://example.com/full.mp3'));
        expect(source.artist, 'Artist');
        expect(source.artUri, artUri);
        expect(source.estimatedDuration, const Duration(minutes: 3));
        expect(source.headers, {'Authorization': 'Bearer t'});
      });
    });

    group('equality', () {
      test('should be equal when url, title, and headers match', () {
        final a = HttpAudioSource(
          title: 'A',
          url: Uri.parse('https://example.com/x.mp3'),
          headers: const {'k': 'v'},
        );
        final b = HttpAudioSource(
          title: 'A',
          url: Uri.parse('https://example.com/x.mp3'),
          headers: const {'k': 'v'},
        );

        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('should not be equal when url differs', () {
        final a =
            HttpAudioSource(title: 'A', url: Uri.parse('https://example.com/1.mp3'));
        final b =
            HttpAudioSource(title: 'A', url: Uri.parse('https://example.com/2.mp3'));

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when titles differ', () {
        final a =
            HttpAudioSource(title: 'Title A', url: Uri.parse('https://example.com/x.mp3'));
        final b =
            HttpAudioSource(title: 'Title B', url: Uri.parse('https://example.com/x.mp3'));

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when headers differ', () {
        final a = HttpAudioSource(
          title: 'A',
          url: Uri.parse('https://example.com/x.mp3'),
          headers: const {'k': 'v1'},
        );
        final b = HttpAudioSource(
          title: 'A',
          url: Uri.parse('https://example.com/x.mp3'),
          headers: const {'k': 'v2'},
        );

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when estimatedDuration differs', () {
        final a = HttpAudioSource(
          title: 'A',
          url: Uri.parse('https://example.com/x.mp3'),
          estimatedDuration: const Duration(seconds: 30),
        );
        final b = HttpAudioSource(
          title: 'A',
          url: Uri.parse('https://example.com/x.mp3'),
          estimatedDuration: const Duration(seconds: 60),
        );

        expect(a, isNot(equals(b)));
      });
    });

    group('props', () {
      test('should expose url, title, artist, artUri, estimatedDuration, headers', () {
        final source = HttpAudioSource(
          title: 'Title',
          url: Uri.parse('https://example.com/x.mp3'),
          artist: 'Artist',
          estimatedDuration: const Duration(seconds: 90),
          headers: const {'key': 'value'},
        );

        expect(source.props, [
          Uri.parse('https://example.com/x.mp3'),
          'Title',
          'Artist',
          null,
          const Duration(seconds: 90),
          {'key': 'value'},
        ]);
      });
    });
  });

  group('FileAudioSource', () {
    test('should construct with path and required title', () {
      const source = FileAudioSource(
        title: 'Local Recording',
        path: '/tmp/recording.m4a',
      );

      expect(source.path, '/tmp/recording.m4a');
      expect(source.title, 'Local Recording');
      expect(source.artist, isNull);
      expect(source.estimatedDuration, isNull);
    });

    test('should be equal when path and title match', () {
      const a = FileAudioSource(title: 'A', path: '/tmp/x.mp3');
      const b = FileAudioSource(title: 'A', path: '/tmp/x.mp3');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('should not be equal when paths differ', () {
      const a = FileAudioSource(title: 'A', path: '/tmp/one.mp3');
      const b = FileAudioSource(title: 'A', path: '/tmp/two.mp3');

      expect(a, isNot(equals(b)));
    });

    test('props expose path, title, artist, artUri, estimatedDuration', () {
      const source = FileAudioSource(
        title: 'T',
        path: '/tmp/x.mp3',
        artist: 'Artist',
      );

      expect(source.props, ['/tmp/x.mp3', 'T', 'Artist', null, null]);
    });
  });

  group('HlsAudioSource', () {
    test('should construct with manifestUrl and required title', () {
      final source = HlsAudioSource(
        title: 'Live Stream',
        manifestUrl: Uri.parse('https://example.com/live.m3u8'),
      );

      expect(source.title, 'Live Stream');
      expect(source.manifestUrl, Uri.parse('https://example.com/live.m3u8'));
      expect(source.artist, isNull);
      expect(source.artUri, isNull);
      expect(source.headers, isNull);
      expect(source.estimatedDuration, isNull);
    });

    test('equality holds across two instances with the same fields', () {
      final a = HlsAudioSource(
        title: 'A',
        manifestUrl: Uri.parse('https://example.com/a.m3u8'),
        headers: const {'k': 'v'},
      );
      final b = HlsAudioSource(
        title: 'A',
        manifestUrl: Uri.parse('https://example.com/a.m3u8'),
        headers: const {'k': 'v'},
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality when manifestUrl differs', () {
      final a = HlsAudioSource(
        title: 'A',
        manifestUrl: Uri.parse('https://example.com/a.m3u8'),
      );
      final b = HlsAudioSource(
        title: 'A',
        manifestUrl: Uri.parse('https://example.com/b.m3u8'),
      );

      expect(a, isNot(equals(b)));
    });

    test('props expose manifestUrl, title, artist, artUri, '
        'estimatedDuration, headers', () {
      final source = HlsAudioSource(
        title: 'Title',
        manifestUrl: Uri.parse('https://example.com/x.m3u8'),
        artist: 'Artist',
        estimatedDuration: const Duration(seconds: 90),
        headers: const {'key': 'value'},
      );

      expect(source.props, [
        Uri.parse('https://example.com/x.m3u8'),
        'Title',
        'Artist',
        null,
        const Duration(seconds: 90),
        {'key': 'value'},
      ]);
    });
  });

  group('Sealed type discrimination', () {
    test('HttpAudioSource and FileAudioSource are not equal', () {
      // Different subtypes with the same title are never equal — they
      // carry different transport payloads (Uri vs path).
      final http = HttpAudioSource(
        title: 'Same',
        url: Uri.parse('https://example.com/same.mp3'),
      );
      const file = FileAudioSource(title: 'Same', path: '/tmp/same.mp3');

      expect(http, isNot(equals(file)));
    });

    test('HttpAudioSource and HlsAudioSource are not equal even when the '
        'transport URL string matches', () {
      // Sealed-type discrimination: two subtypes carrying the same URI
      // string must never compare equal — they go through different demuxer
      // paths (progressive HTTP vs HLS manifest).
      final http = HttpAudioSource(
        title: 'Same',
        url: Uri.parse('https://example.com/same.m3u8'),
      );
      final hls = HlsAudioSource(
        title: 'Same',
        manifestUrl: Uri.parse('https://example.com/same.m3u8'),
      );

      expect(http, isNot(equals(hls)));
    });

    test('exhaustive switch on the sealed type compiles and dispatches', () {
      // Compile-time check: this switch is exhaustive over the sealed
      // hierarchy. Faz S3 must add an arm when LiveAudioSource ships.
      final CoreAudioSource source = HttpAudioSource(
        title: 'X',
        url: Uri.parse('https://example.com/x.mp3'),
      );
      final result = switch (source) {
        HttpAudioSource(:final url) => 'http:${url.toString()}',
        FileAudioSource(:final path) => 'file:$path',
        HlsAudioSource(:final manifestUrl) => 'hls:${manifestUrl.toString()}',
      };
      expect(result, 'http:https://example.com/x.mp3');
    });
  });
}
