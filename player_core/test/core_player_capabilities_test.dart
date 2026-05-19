import 'package:test/test.dart';
import 'package:player_core/player_core.dart';

import 'test_setup.dart';

void main() {
  setUpAll(enableEquatableStringify);

  group('CorePlayerCapabilities', () {
    test('default ctor sets every flag to false', () {
      const caps = CorePlayerCapabilities();

      expect(caps.supportsLiveSource, isFalse);
      expect(caps.supportsHls, isFalse);
      expect(caps.supportsCrossfade, isFalse);
      expect(caps.supportsCast, isFalse);
      expect(caps.supportsDrm, isFalse);
      expect(caps.supportsEqualizer, isFalse);
    });

    test('two instances with identical flags are == via Equatable', () {
      const a = CorePlayerCapabilities(
        supportsLiveSource: true,
        supportsHls: true,
      );
      const b = CorePlayerCapabilities(
        supportsLiveSource: true,
        supportsHls: true,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('a flag flip breaks equality', () {
      const a = CorePlayerCapabilities(supportsHls: true);
      const b = CorePlayerCapabilities(supportsHls: false);

      expect(a, isNot(equals(b)));
    });

    test('props round-trips every flag in declaration order', () {
      const caps = CorePlayerCapabilities(
        supportsLiveSource: true,
        supportsHls: false,
        supportsCrossfade: true,
        supportsCast: false,
        supportsDrm: true,
        supportsEqualizer: false,
      );

      expect(caps.props, <Object?>[true, false, true, false, true, false]);
    });
  });
}
