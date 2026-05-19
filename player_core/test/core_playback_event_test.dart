import 'package:player_core/player_core.dart';
import 'package:test/test.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  final src = HttpAudioSource(
    title: 'A',
    url: Uri.parse('https://example.com/a.mp3'),
  );
  final src2 = HttpAudioSource(
    title: 'B',
    url: Uri.parse('https://example.com/b.mp3'),
  );
  // Fixed timestamp so equality assertions are deterministic — `DateTime.now`
  // would defeat the round-trip checks below.
  final ts = DateTime.utc(2026, 1, 1);

  group('CorePlaybackEvent equality', () {
    test('PlaybackStartedEvent: equal when source + timestamp match', () {
      final a = PlaybackStartedEvent(source: src, timestamp: ts);
      final b = PlaybackStartedEvent(source: src, timestamp: ts);
      final c = PlaybackStartedEvent(source: src2, timestamp: ts);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('PlaybackEndedBySkipEvent includes skippedFromPosition in props', () {
      final a = PlaybackEndedBySkipEvent(
        source: src,
        timestamp: ts,
        skippedFromPosition: const Duration(seconds: 10),
      );
      final b = PlaybackEndedBySkipEvent(
        source: src,
        timestamp: ts,
        skippedFromPosition: const Duration(seconds: 10),
      );
      final c = PlaybackEndedBySkipEvent(
        source: src,
        timestamp: ts,
        skippedFromPosition: const Duration(seconds: 11),
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('PlaybackSeekEvent carries from + to positions', () {
      final a = PlaybackSeekEvent(
        source: src,
        timestamp: ts,
        fromPosition: const Duration(seconds: 5),
        toPosition: const Duration(seconds: 30),
      );
      expect(a.fromPosition, const Duration(seconds: 5));
      expect(a.toPosition, const Duration(seconds: 30));
    });

    test('PlaybackStallEndedEvent carries stallDuration', () {
      final a = PlaybackStallEndedEvent(
        source: src,
        timestamp: ts,
        stallDuration: const Duration(milliseconds: 750),
      );
      expect(a.stallDuration, const Duration(milliseconds: 750));
    });

    test('PlaybackHeartbeatEvent carries elapsedSinceStart', () {
      final a = PlaybackHeartbeatEvent(
        source: src,
        timestamp: ts,
        elapsedSinceStart: const Duration(seconds: 30),
      );
      expect(a.elapsedSinceStart, const Duration(seconds: 30));
    });
  });

  group('CorePlaybackEvent sealed switch exhaustiveness', () {
    // Compile-time check: the analyzer enforces exhaustive switches on
    // sealed classes. If a future subtype is added without updating this
    // switch, the test fails to compile — surfacing the contract change
    // to every consumer that wraps the stream.
    String classify(CorePlaybackEvent e) => switch (e) {
      PlaybackStartedEvent() => 'started',
      PlaybackEndedByCompletionEvent() => 'completed',
      PlaybackEndedBySkipEvent() => 'skip',
      PlaybackEndedByStopEvent() => 'stop',
      PlaybackSeekEvent() => 'seek',
      PlaybackStallStartedEvent() => 'stall_start',
      PlaybackStallEndedEvent() => 'stall_end',
      PlaybackHeartbeatEvent() => 'heartbeat',
    };

    test('classifies every subtype', () {
      expect(
        classify(PlaybackStartedEvent(source: src, timestamp: ts)),
        'started',
      );
      expect(
        classify(PlaybackEndedByCompletionEvent(source: src, timestamp: ts)),
        'completed',
      );
      expect(
        classify(
          PlaybackEndedBySkipEvent(
            source: src,
            timestamp: ts,
            skippedFromPosition: Duration.zero,
          ),
        ),
        'skip',
      );
      expect(
        classify(PlaybackEndedByStopEvent(source: src, timestamp: ts)),
        'stop',
      );
      expect(
        classify(
          PlaybackSeekEvent(
            source: src,
            timestamp: ts,
            fromPosition: Duration.zero,
            toPosition: Duration.zero,
          ),
        ),
        'seek',
      );
      expect(
        classify(PlaybackStallStartedEvent(source: src, timestamp: ts)),
        'stall_start',
      );
      expect(
        classify(
          PlaybackStallEndedEvent(
            source: src,
            timestamp: ts,
            stallDuration: Duration.zero,
          ),
        ),
        'stall_end',
      );
      expect(
        classify(
          PlaybackHeartbeatEvent(
            source: src,
            timestamp: ts,
            elapsedSinceStart: Duration.zero,
          ),
        ),
        'heartbeat',
      );
    });
  });

  group('CorePlayerConfiguration.heartbeatInterval', () {
    test('default is null (opt-in)', () {
      const config = CorePlayerConfiguration();
      expect(config.heartbeatInterval, isNull);
    });

    test('can be set explicitly', () {
      const config = CorePlayerConfiguration(
        heartbeatInterval: Duration(seconds: 30),
      );
      expect(config.heartbeatInterval, const Duration(seconds: 30));
    });
  });
}
