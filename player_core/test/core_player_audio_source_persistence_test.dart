import 'dart:convert';

import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerAudioSource JSON', () {
    test('round-trips a url-only source through Equatable equality', () {
      const source = CorePlayerAudioSource(
        title: 'Science Friday',
        url: 'https://example.com/scifri.mp3',
      );
      final restored = CorePlayerAudioSource.fromJson(source.toJson());
      expect(restored, equals(source));
    });

    test('round-trips a file-only source', () {
      const source = CorePlayerAudioSource(
        title: 'Local Recording',
        filePath: '/tmp/recording.m4a',
      );
      final restored = CorePlayerAudioSource.fromJson(source.toJson());
      expect(restored, equals(source));
    });

    test('round-trips a source with httpHeaders + artUri + metadata', () {
      final source = CorePlayerAudioSource(
        title: 'Full',
        url: 'https://example.com/full.mp3',
        album: 'Album',
        artist: 'Artist',
        genre: 'Genre',
        artUri: Uri.parse('https://example.com/cover.png'),
        httpHeaders: const {'Authorization': 'Bearer abc123'},
      );
      final restored = CorePlayerAudioSource.fromJson(source.toJson());
      expect(restored, equals(source));
      expect(restored.httpHeaders, source.httpHeaders);
      expect(restored.artUri, source.artUri);
    });

    test('round-trips through JsonCodec (production cold-launch path)', () {
      final source = CorePlayerAudioSource(
        title: 'JSON path',
        url: 'https://example.com/json.mp3',
        artUri: Uri.parse('https://example.com/json-cover.jpg'),
        httpHeaders: const {'X-Trace': 'abc'},
      );
      final encoded = jsonEncode(source.toJson());
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(CorePlayerAudioSource.fromJson(decoded), equals(source));
    });

    test('emits "remote" type when url is set, "file" otherwise', () {
      const remote = CorePlayerAudioSource(title: 'r', url: 'https://x');
      const file = CorePlayerAudioSource(title: 'f', filePath: '/tmp/x');
      const neither = CorePlayerAudioSource(title: 'n');
      expect(remote.toJson()['type'], 'remote');
      expect(file.toJson()['type'], 'file');
      // Neither url nor filePath: still emit 'file' so play-time
      // InvalidMediaSourceFailure (not silent drop in fromJson) surfaces.
      expect(neither.toJson()['type'], 'file');
    });

    test('rejects unknown type discriminator', () {
      expect(
        () => CorePlayerAudioSource.fromJson(<String, Object?>{
          'type': 'live',
          'title': 'Future-Faz-S',
        }),
        throwsFormatException,
      );
    });

    test('rejects missing required title', () {
      expect(
        () => CorePlayerAudioSource.fromJson(<String, Object?>{'type': 'remote', 'url': 'https://x'}),
        throwsFormatException,
      );
    });

    test('returns mutable copies of httpHeaders (no shared state)', () {
      final source = CorePlayerAudioSource(
        title: 'mutable check',
        url: 'https://example.com/x.mp3',
        httpHeaders: const {'a': 'b'},
      );
      final json = source.toJson();
      final headers = json['httpHeaders'] as Map<String, String>;
      // Mutating the returned map must NOT corrupt the source.
      headers['evil'] = 'mutation';
      expect(source.httpHeaders, {'a': 'b'});
    });
  });

  group('CorePlayerQueue JSON', () {
    const src1 = CorePlayerAudioSource(title: 'A', url: 'https://example.com/a.mp3');
    const src2 = CorePlayerAudioSource(title: 'B', url: 'https://example.com/b.mp3');
    const src3 = CorePlayerAudioSource(title: 'C', url: 'https://example.com/c.mp3');

    test('round-trips a multi-item queue bit-for-bit', () {
      const queue = CorePlayerQueue([src1, src2, src3], currentIndex: 2);
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
      const queue = CorePlayerQueue([src1, src2], currentIndex: 1);
      final encoded = jsonEncode(queue.toJson());
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      final restored = CorePlayerQueue.fromJson(decoded);
      expect(restored.sources, queue.sources);
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
      final json = const CorePlayerQueue([src1, src2], currentIndex: 0).toJson();
      json['activeIndex'] = 99;
      final restored = CorePlayerQueue.fromJson(json);
      expect(restored.currentIndex, 1);
    });
  });
}
