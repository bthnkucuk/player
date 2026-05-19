import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerAudioSource', () {
    group('constructor', () {
      test('should construct with url-only and required title', () {
        const source = CorePlayerAudioSource(title: 'Title', url: 'https://example.com/a.mp3');

        expect(source.title, 'Title');
        expect(source.url, 'https://example.com/a.mp3');
        expect(source.filePath, isNull);
        expect(source.album, isNull);
        expect(source.artist, isNull);
        expect(source.genre, isNull);
        expect(source.artUri, isNull);
        expect(source.httpHeaders, isNull);
      });

      test('should construct with filePath-only', () {
        const source = CorePlayerAudioSource(title: 'Title', filePath: '/local/path/local.mp3');

        expect(source.filePath, '/local/path/local.mp3');
        expect(source.url, isNull);
      });

      test('should construct with both url and filePath null', () {
        const source = CorePlayerAudioSource(title: 'Empty');

        expect(source.url, isNull);
        expect(source.filePath, isNull);
        expect(source.title, 'Empty');
      });

      test('should construct with all metadata fields populated', () {
        final artUri = Uri.parse('https://example.com/cover.png');
        final source = CorePlayerAudioSource(
          title: 'Full',
          url: 'https://example.com/full.mp3',
          filePath: '/tmp/full.mp3',
          album: 'Album',
          artist: 'Artist',
          genre: 'Genre',
          artUri: artUri,
          httpHeaders: const {'Authorization': 'Bearer t'},
        );

        expect(source.title, 'Full');
        expect(source.url, 'https://example.com/full.mp3');
        expect(source.filePath, '/tmp/full.mp3');
        expect(source.album, 'Album');
        expect(source.artist, 'Artist');
        expect(source.genre, 'Genre');
        expect(source.artUri, artUri);
        expect(source.httpHeaders, {'Authorization': 'Bearer t'});
      });
    });

    group('equality', () {
      test('should be equal when url, title, and httpHeaders match', () {
        const a = CorePlayerAudioSource(title: 'A', url: 'https://example.com/x.mp3', httpHeaders: {'k': 'v'});
        const b = CorePlayerAudioSource(title: 'A', url: 'https://example.com/x.mp3', httpHeaders: {'k': 'v'});

        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('should not be equal when url differs', () {
        const a = CorePlayerAudioSource(title: 'A', url: 'https://example.com/1.mp3');
        const b = CorePlayerAudioSource(title: 'A', url: 'https://example.com/2.mp3');

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when titles differ (B3: metadata is now part of equality)', () {
        const a = CorePlayerAudioSource(title: 'Title A', url: 'https://example.com/x.mp3', album: 'Album A');
        const b = CorePlayerAudioSource(title: 'Title B', url: 'https://example.com/x.mp3', album: 'Album B');

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when httpHeaders differ', () {
        const a = CorePlayerAudioSource(title: 'A', url: 'https://example.com/x.mp3', httpHeaders: {'k': 'v1'});
        const b = CorePlayerAudioSource(title: 'A', url: 'https://example.com/x.mp3', httpHeaders: {'k': 'v2'});

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when filePaths differ', () {
        const a = CorePlayerAudioSource(title: 'A', filePath: '/tmp/one.mp3');
        const b = CorePlayerAudioSource(title: 'A', filePath: '/tmp/two.mp3');

        expect(a, isNot(equals(b)));
      });

      test('should not be equal when genre differs (regression: genre missing from props)', () {
        const a = CorePlayerAudioSource(title: 'A', url: 'https://example.com/x.mp3', genre: 'Pop');
        const b = CorePlayerAudioSource(title: 'A', url: 'https://example.com/x.mp3', genre: 'Rock');

        expect(a, isNot(equals(b)));
      });
    });

    group('props', () {
      test('should expose url, filePath, title, album, artist, genre, artUri, and httpHeaders', () {
        const source = CorePlayerAudioSource(
          title: 'Title',
          url: 'url',
          filePath: '/tmp/test.mp3',
          album: 'Album',
          artist: 'Artist',
          genre: 'Genre',
          httpHeaders: {'key': 'value'},
        );

        expect(source.props, [
          'url',
          '/tmp/test.mp3',
          'Title',
          'Album',
          'Artist',
          'Genre',
          null,
          {'key': 'value'},
        ]);
      });

      test('should expose nulls when optional fields omitted', () {
        const source = CorePlayerAudioSource(title: 'T');

        expect(source.props, [null, null, 'T', null, null, null, null, null]);
      });
    });
  });
}
