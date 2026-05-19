import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerFailure', () {
    test('all subtypes are CorePlayerFailure and Exception', () {
      const CorePlayerFailure disposed = PlayerDisposedFailure();
      const CorePlayerFailure mediaNotSet = MediaItemNotSetFailure();
      const CorePlayerFailure invalid = InvalidMediaSourceFailure();
      const CorePlayerFailure load = LoadFailure('boom');
      const CorePlayerFailure speed = PlaybackSpeedFailure('bad rate');

      expect(disposed, isA<CorePlayerFailure>());
      expect(mediaNotSet, isA<CorePlayerFailure>());
      expect(invalid, isA<CorePlayerFailure>());
      expect(load, isA<CorePlayerFailure>());
      expect(speed, isA<CorePlayerFailure>());

      // Every CorePlayerFailure is an Exception (catchable as such).
      expect(disposed, isA<Exception>());
      expect(mediaNotSet, isA<Exception>());
      expect(invalid, isA<Exception>());
      expect(load, isA<Exception>());
      expect(speed, isA<Exception>());
    });

    test('toString includes runtimeType and message', () {
      expect(const PlayerDisposedFailure().toString(), 'PlayerDisposedFailure: Player disposed');
      expect(const MediaItemNotSetFailure().toString(), 'MediaItemNotSetFailure: Media item is not set');
      expect(const InvalidMediaSourceFailure().toString(), 'InvalidMediaSourceFailure: Media item is invalid');
      expect(const LoadFailure('failed').toString(), 'LoadFailure: failed');
      expect(const PlaybackSpeedFailure('bad rate').toString(), 'PlaybackSpeedFailure: bad rate');
    });

    test('LoadFailure preserves cause', () {
      final cause = Exception('network timeout');
      final failure = LoadFailure('Failed to load media: $cause', cause: cause);

      expect(failure.cause, same(cause));
      expect(failure.message, contains('network timeout'));
    });

    test('PlaybackSpeedFailure preserves cause', () {
      final cause = Exception('rate out of range');
      final failure = PlaybackSpeedFailure('Failed to set speed 99', cause: cause);

      expect(failure.cause, same(cause));
      expect(failure.message, contains('99'));
    });

    test('LoadFailure cause is nullable', () {
      const failure = LoadFailure('plain');
      expect(failure.cause, isNull);
    });

    test('subtypes carry the canned message field', () {
      expect(const PlayerDisposedFailure().message, 'Player disposed');
      expect(const MediaItemNotSetFailure().message, 'Media item is not set');
      expect(const InvalidMediaSourceFailure().message, 'Media item is invalid');
    });
  });
}
