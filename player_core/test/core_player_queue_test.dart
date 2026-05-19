import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerQueue', () {
    final src1 =
        HttpAudioSource(title: 'A', url: Uri.parse('https://example.com/a.mp3'));
    final src2 =
        HttpAudioSource(title: 'B', url: Uri.parse('https://example.com/b.mp3'));
    final src3 =
        HttpAudioSource(title: 'C', url: Uri.parse('https://example.com/c.mp3'));

    test('CorePlayerQueue.single produces a single-item queue at index 0', () {
      final q = CorePlayerQueue.single(src1);
      expect(q.length, 1);
      expect(q.currentIndex, 0);
      expect(q.current, src1);
      expect(q.isEmpty, isFalse);
      expect(q.isNotEmpty, isTrue);
    });

    test('CorePlayerQueue.empty produces a length-0 queue with null current', () {
      const q = CorePlayerQueue.empty();
      expect(q.length, 0);
      expect(q.isEmpty, isTrue);
      expect(q.isNotEmpty, isFalse);
      expect(q.current, isNull);
    });

    test('multi-item construction exposes sources and currentIndex', () {
      final q = CorePlayerQueue([src1, src2, src3]);
      expect(q.length, 3);
      expect(q.currentIndex, 0);
      expect(q.current, src1);
      expect(q.sources, [src1, src2, src3]);
    });

    test('withIndex returns a new queue with the cursor moved', () {
      final q = CorePlayerQueue([src1, src2, src3]);
      final moved = q.withIndex(2);
      expect(moved.currentIndex, 2);
      expect(moved.current, src3);
      // Original unchanged.
      expect(q.currentIndex, 0);
      expect(moved.sources, q.sources);
    });

    test('withIndex(-1) trips an assertion', () {
      final q = CorePlayerQueue([src1, src2]);
      expect(() => q.withIndex(-1), throwsA(isA<AssertionError>()));
    });

    test('withIndex(length) trips an assertion', () {
      final q = CorePlayerQueue([src1, src2]);
      expect(() => q.withIndex(2), throwsA(isA<AssertionError>()));
    });

    test('indexed access returns the right source', () {
      final q = CorePlayerQueue([src1, src2, src3]);
      expect(q[0], src1);
      expect(q[1], src2);
      expect(q[2], src3);
    });

    test('two queues sharing the same source list compare equal (record-based ==)', () {
      // CorePlayerQueue is a zero-cost extension type over a record. Record
      // equality compares fields by Object.==, so two queues built around
      // the SAME underlying list with the SAME currentIndex are equal.
      // Distinct list instances containing equal elements are not — that's
      // the standard list-identity contract, not specific to this type.
      final shared = [src1, src2];
      final a = CorePlayerQueue(shared);
      final b = CorePlayerQueue(shared);
      expect(a == b, isTrue);
    });

    test('queues differing in currentIndex are not equal', () {
      final shared = [src1, src2];
      final a = CorePlayerQueue(shared);
      final b = a.withIndex(1);
      expect(a == b, isFalse);
    });
  });
}
