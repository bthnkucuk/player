import 'dart:convert';

import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CoreAudioSource JSON', () {
    test('round-trips an HttpAudioSource through Equatable equality', () {
      final source = HttpAudioSource(
        title: 'Science Friday',
        url: Uri.parse('https://example.com/scifri.mp3'),
      );
      final restored = CoreAudioSource.fromJson(source.toJson());
      expect(restored, isA<HttpAudioSource>());
      expect(restored, equals(source));
    });

    test('round-trips a FileAudioSource', () {
      const source = FileAudioSource(
        title: 'Local Recording',
        path: '/tmp/recording.m4a',
      );
      final restored = CoreAudioSource.fromJson(source.toJson());
      expect(restored, isA<FileAudioSource>());
      expect(restored, equals(source));
    });

    test('round-trips an HttpAudioSource with headers + artUri + metadata', () {
      final source = HttpAudioSource(
        title: 'Full',
        url: Uri.parse('https://example.com/full.mp3'),
        artist: 'Artist',
        artUri: Uri.parse('https://example.com/cover.png'),
        headers: const {'Authorization': 'Bearer abc123'},
      );
      final restored = CoreAudioSource.fromJson(source.toJson()) as HttpAudioSource;
      expect(restored, equals(source));
      expect(restored.headers, source.headers);
      expect(restored.artUri, source.artUri);
    });

    test('round-trips through JsonCodec (production cold-launch path)', () {
      final source = HttpAudioSource(
        title: 'JSON path',
        url: Uri.parse('https://example.com/json.mp3'),
        artUri: Uri.parse('https://example.com/json-cover.jpg'),
        headers: const {'X-Trace': 'abc'},
      );
      final encoded = jsonEncode(source.toJson());
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(CoreAudioSource.fromJson(decoded), equals(source));
    });

    test('emits "http" type for HttpAudioSource and "file" for FileAudioSource', () {
      final http = HttpAudioSource(title: 'r', url: Uri.parse('https://x'));
      const file = FileAudioSource(title: 'f', path: '/tmp/x');
      expect(http.toJson()['type'], 'http');
      expect(file.toJson()['type'], 'file');
    });

    test('rejects unknown type discriminator with SnapshotMalformedFailure', () {
      // 'live' is reserved for Faz S3, so use a clearly-bogus value here
      // that no shipped Faz can accidentally claim.
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'completely-bogus',
          'title': 'Future-Faz-X',
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('rejects the "live" discriminator with a dedicated error message', () {
      // LiveAudioSource is process-local — the snapshot path explicitly
      // refuses to resurrect it (see LiveAudioSource.toJson). The "live"
      // arm of fromJson is here for symmetry so a queue snapshot that
      // somehow carries a live entry fails with a clear, named reason
      // rather than the generic "unknown type" branch.
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'live',
          'title': 'Live segments',
        }),
        throwsA(
          isA<SnapshotMalformedFailure>().having(
            (f) => f.message,
            'message',
            contains('LiveAudioSource'),
          ),
        ),
      );
    });

    test('rejects HttpAudioSource missing required title', () {
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'http',
          'url': 'https://x',
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('rejects HttpAudioSource missing required url', () {
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'http',
          'title': 'no url',
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('rejects FileAudioSource missing required path', () {
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'file',
          'title': 'no path',
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('returns mutable copies of headers (no shared state)', () {
      final source = HttpAudioSource(
        title: 'mutable check',
        url: Uri.parse('https://example.com/x.mp3'),
        headers: const {'a': 'b'},
      );
      final json = source.toJson();
      final headers = json['headers'] as Map<String, String>;
      // Mutating the returned map must NOT corrupt the source.
      headers['evil'] = 'mutation';
      expect(source.headers, {'a': 'b'});
    });

    test('estimatedDuration round-trips for HttpAudioSource', () {
      final source = HttpAudioSource(
        title: 'est',
        url: Uri.parse('https://example.com/x.mp3'),
        estimatedDuration: const Duration(minutes: 2, seconds: 30),
      );
      final restored = CoreAudioSource.fromJson(source.toJson());
      expect(restored, equals(source));
      expect(restored.estimatedDuration, const Duration(minutes: 2, seconds: 30));
    });

    test('estimatedDuration round-trips for FileAudioSource', () {
      const source = FileAudioSource(
        title: 'est-file',
        path: '/tmp/x.mp3',
        estimatedDuration: Duration(seconds: 42),
      );
      final restored = CoreAudioSource.fromJson(source.toJson());
      expect(restored, equals(source));
      expect(restored.estimatedDuration, const Duration(seconds: 42));
    });

    test('null estimatedDuration is omitted from JSON', () {
      final source = HttpAudioSource(
        title: 't',
        url: Uri.parse('https://example.com/x.mp3'),
      );
      expect(source.toJson().containsKey('estimatedMs'), isFalse);
    });

    test('round-trips an HlsAudioSource', () {
      final source = HlsAudioSource(
        title: 'HLS Live',
        manifestUrl: Uri.parse('https://example.com/live.m3u8'),
      );
      final restored = CoreAudioSource.fromJson(source.toJson());
      expect(restored, isA<HlsAudioSource>());
      expect(restored, equals(source));
    });

    test('round-trips an HlsAudioSource with headers + artUri + metadata', () {
      final source = HlsAudioSource(
        title: 'HLS Full',
        manifestUrl: Uri.parse('https://example.com/full.m3u8'),
        artist: 'Broadcaster',
        artUri: Uri.parse('https://example.com/hls-cover.png'),
        estimatedDuration: const Duration(minutes: 5),
        headers: const {'Authorization': 'Bearer hls'},
      );
      final restored =
          CoreAudioSource.fromJson(source.toJson()) as HlsAudioSource;
      expect(restored, equals(source));
      expect(restored.headers, source.headers);
      expect(restored.artUri, source.artUri);
      expect(restored.estimatedDuration, source.estimatedDuration);
    });

    test('emits "hls" type discriminator for HlsAudioSource', () {
      final hls = HlsAudioSource(
        title: 'h',
        manifestUrl: Uri.parse('https://x/y.m3u8'),
      );
      expect(hls.toJson()['type'], 'hls');
    });

    test('rejects HlsAudioSource missing required manifestUrl', () {
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'hls',
          'title': 'no manifest',
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('rejects HlsAudioSource missing required title', () {
      expect(
        () => CoreAudioSource.fromJson(<String, Object?>{
          'type': 'hls',
          'manifestUrl': 'https://example.com/x.m3u8',
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('HlsAudioSource headers JSON view does not share state with the '
        'source', () {
      final source = HlsAudioSource(
        title: 'mutable check',
        manifestUrl: Uri.parse('https://example.com/x.m3u8'),
        headers: const {'a': 'b'},
      );
      final json = source.toJson();
      final headers = json['headers'] as Map<String, String>;
      headers['evil'] = 'mutation';
      expect(source.headers, {'a': 'b'});
    });

    test('exhaustive switch on sealed CoreAudioSource compiles cleanly', () {
      // Compile-time check: an exhaustive switch over the sealed
      // hierarchy that the analyzer accepts. Faz S3 will need to add an
      // arm when LiveAudioSource ships — that diff must touch this test
      // along with the rest of the codebase, which is the point of the
      // sealed type.
      final CoreAudioSource source =
          HttpAudioSource(title: 't', url: Uri.parse('https://example.com/x.mp3'));
      final kind = switch (source) {
        HttpAudioSource() => 'http',
        FileAudioSource() => 'file',
        HlsAudioSource() => 'hls',
        LiveAudioSource() => 'live',
      };
      expect(kind, 'http');
    });
  });

  group('CorePlayerQueue JSON', () {
    final src1 =
        HttpAudioSource(title: 'A', url: Uri.parse('https://example.com/a.mp3'));
    final src2 =
        HttpAudioSource(title: 'B', url: Uri.parse('https://example.com/b.mp3'));
    final src3 =
        HttpAudioSource(title: 'C', url: Uri.parse('https://example.com/c.mp3'));

    test('round-trips a multi-item queue bit-for-bit', () {
      final queue = CorePlayerQueue([src1, src2, src3], currentIndex: 2);
      final restored = CorePlayerQueue.fromJson(queue.toJson());
      expect(restored.sources, equals(queue.sources));
      expect(restored.currentIndex, queue.currentIndex);
      expect(restored.length, queue.length);
    });

    test('round-trips an empty queue', () {
      const queue = CorePlayerQueue.empty();
      final restored = CorePlayerQueue.fromJson(queue.toJson());
      expect(restored.length, 0);
      expect(restored.isEmpty, isTrue);
    });

    test('round-trips through JsonCodec', () {
      final queue = CorePlayerQueue([src1, src2], currentIndex: 1);
      final encoded = jsonEncode(queue.toJson());
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      final restored = CorePlayerQueue.fromJson(decoded);
      expect(restored.sources, queue.sources);
      expect(restored.currentIndex, 1);
    });

    test('round-trips a mixed-subtype queue', () {
      final mixed = CorePlayerQueue(<CoreAudioSource>[
        src1,
        const FileAudioSource(title: 'F', path: '/tmp/f.mp3'),
        src2,
      ], currentIndex: 1);
      final restored = CorePlayerQueue.fromJson(mixed.toJson());
      expect(restored.sources, hasLength(3));
      expect(restored.sources[0], isA<HttpAudioSource>());
      expect(restored.sources[1], isA<FileAudioSource>());
      expect(restored.sources[2], isA<HttpAudioSource>());
      expect(restored.currentIndex, 1);
    });

    test('rejects unknown schemaVersion with SnapshotSchemaMismatchFailure', () {
      expect(
        () => CorePlayerQueue.fromJson(<String, Object?>{
          'schemaVersion': 999,
          'items': <Map<String, Object?>>[],
          'activeIndex': 0,
        }),
        throwsA(isA<SnapshotSchemaMismatchFailure>()
            .having((f) => f.foundVersion, 'foundVersion', 999)
            .having((f) => f.expectedVersion, 'expectedVersion', 1)),
      );
    });

    test('rejects missing items field', () {
      expect(
        () => CorePlayerQueue.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'activeIndex': 0,
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('rejects missing activeIndex field', () {
      expect(
        () => CorePlayerQueue.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'items': <Map<String, Object?>>[],
        }),
        throwsA(isA<SnapshotMalformedFailure>()),
      );
    });

    test('clamps activeIndex into [0, length) on non-empty queues', () {
      // Defensive — a previous-version payload could carry an out-of-range
      // index if a queue was trimmed between snapshot and restore. Clamp
      // rather than throwing so the player still resumes (worst case: at
      // the last track in the queue).
      final json =
          CorePlayerQueue([src1, src2], currentIndex: 0).toJson();
      json['activeIndex'] = 99;
      final restored = CorePlayerQueue.fromJson(json);
      expect(restored.currentIndex, 1);
    });
  });
}
