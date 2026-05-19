import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/src/player/core_audio_service_bridge.dart';

/// Exercises the real [CoreMediaKitAudioServiceBridge.initialize] code path by
/// stubbing the underlying plugin method channels (audio_service +
/// audio_session). Lives in its own file because [AudioService.init] mutates
/// top-level static state in the audio_service package that we don't want
/// leaking into the rest of the suite.
///
/// After Phase 3 / K4 the bridge owns `audio_service` + `audio_session`
/// directly; this test moved here from the abstraction package.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Route sqflite through pure-Dart sqlite3 (host binary) instead of the
  // platform channel. Must run before AudioService.init / DefaultCacheManager
  // touches the database factory.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const audioServiceClient = MethodChannel(
    'com.ryanheise.audio_service.client.methods',
  );
  const audioSession = MethodChannel('com.ryanheise.audio_session');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late List<MethodCall> audioServiceCalls;
  late List<MethodCall> audioSessionCalls;

  setUp(() {
    CoreAudioHandler.setInitialized(false);
    CoreAudioHandler.debugSetBridge(null);
    audioServiceCalls = <MethodCall>[];
    audioSessionCalls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioServiceClient, (call) async {
          audioServiceCalls.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSession, (call) async {
          audioSessionCalls.add(call);
          if (call.method == 'getConfiguration') {
            return <String, dynamic>{};
          }
          return null;
        });
    // AudioService.init transitively constructs DefaultCacheManager which
    // queries path_provider; stub it so init can complete in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          // A path under the system temp dir is enough; flutter_cache_manager
          // will create subdirectories under it.
          return '${Directory.systemTemp.path}/player_core_audio_handler_test';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioServiceClient, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSession, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
  });

  group('CoreMediaKitAudioServiceBridge.initialize() platform-channel path', () {
    // AudioService.init mutates top-level static state in the audio_service
    // package (DefaultCacheManager, _config, etc.) and asserts those statics
    // are still null, so we can only run the real init path once per test
    // process. Both behaviours are therefore exercised in a single test.
    test(
      'should drive AudioService.init + AudioSession setup, expose a non-null handler instance, '
      'and CoreAudioHandler.initialize() is idempotent on subsequent calls',
      () async {
        expect(CoreAudioHandler.instance, isNull);

        // Install the bridge as `CorePlayerMediaKit.ensureInitialized` would.
        final bridge = CoreMediaKitAudioServiceBridge();
        CoreAudioHandler.registerBridge(bridge);

        await CoreAudioHandler.initialize();

        expect(CoreAudioHandler.instance, isNotNull);
        expect(
          audioServiceCalls.map((c) => c.method),
          contains('configure'),
          reason:
              'AudioService.init should invoke "configure" on the client channel',
        );

        // Phase 19 — bridge must seed a non-NONE PlaybackState after init so
        // the Android platform MediaSession binds to this handler instead of
        // falling back to whichever app last claimed the OS audio surface.
        final seeded = bridge.playbackState.value;
        expect(
          seeded.processingState,
          AudioProcessingState.idle,
          reason:
              'initialize() must seed processingState=idle (not the default empty PlaybackState)',
        );
        expect(
          seeded.playing,
          isFalse,
          reason: 'seeded state must not be playing',
        );
        expect(
          seeded.queueIndex,
          0,
          reason:
              'seeded state must populate queueIndex so the plugin treats it as alive',
        );
        expect(seeded.updatePosition, Duration.zero);
        expect(seeded.bufferedPosition, Duration.zero);
        expect(seeded.controls, contains(MediaControl.play));
        expect(seeded.systemActions, contains(MediaAction.play));

        final clientCallsAfterFirst = audioServiceCalls.length;
        final sessionCallsAfterFirst = audioSessionCalls.length;

        await CoreAudioHandler.initialize();

        expect(
          audioServiceCalls.length,
          clientCallsAfterFirst,
          reason:
              'second initialize() must not re-invoke audio_service channel',
        );
        expect(
          audioSessionCalls.length,
          sessionCallsAfterFirst,
          reason:
              'second initialize() must not re-invoke audio_session channel',
        );
        expect(CoreAudioHandler.instance, isNotNull);

        // Bridge owns the BaseAudioHandler-typed streams now.
        bridge.playbackState.add(
          PlaybackState(
            controls: const <MediaControl>[],
            systemActions: const <MediaAction>{},
            processingState: AudioProcessingState.ready,
            playing: false,
            updatePosition: const Duration(seconds: 45),
          ),
        );

        await expectLater(bridge.fastForward(), completes);
        await expectLater(bridge.rewind(), completes);
      },
    );
  });
}
