import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:player_core/player_core.dart';
import 'package:audio_player/audio_player.dart';

import 'demos/auto_radio_and_position_stream.dart';
import 'demos/debug_logs.dart';
import 'demos/hls.dart';
import 'demos/raw_media_kit.dart';
import 'demos/multi_scope.dart';
import 'demos/observer.dart';
import 'demos/playlist.dart';
import 'demos/queue_mutation.dart';
import 'demos/resume_from_cold_start.dart';
import 'demos/single_track.dart';

/// App-wide Talker instance. Wired to [CorePlayerConfiguration.logCallback]
/// in [main] so every log emission from the audio_player bridge
/// (init, activate/deactivate, emitPlaybackState, emitMediaItem,
/// lock-screen play/pause/skip/stop, interruption/becomingNoisy/appResume)
/// shows up in the Debug Logs demo screen. See `demos/debug_logs.dart`.
final Talker talker = Talker();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bootstrap: registers the bridge + factory and primes media_kit's native bindings.
  //
  // CorePlayerConfiguration has working defaults for the lock-screen /
  // foreground-service surface; this example overrides the Android channel
  // metadata so the notification reads as the example app and to document
  // the override pattern. Real apps should set the channel id to a unique
  // value (e.g. their package id + ".audio") and pick a user-readable name.
  CorePlayerMediaKit.ensureInitialized(
    configuration: CorePlayerConfiguration(
      androidNotificationChannelId: 'com.example.audio_player_example.audio',
      androidNotificationChannelName: 'audio_player example playback',
      // Default for this is now `true` (Android requires foreground-service
      // notifications to be ongoing). Pinned explicitly here as a note that
      // consumers can tune it if they understand the platform contract.
      androidNotificationOngoing: true,
      // Default already 'mipmap/ic_launcher'; set explicitly to document the
      // override point. The resource must exist under
      // `android/app/src/main/res/mipmap-*/ic_launcher.png` (which is what
      // `flutter create` ships). Override per-app to use a dedicated playback
      // glyph (e.g. 'drawable/ic_playback').
      androidNotificationIcon: 'mipmap/ic_launcher',
      // Wire bridge log instrumentation (Phase 21) into Talker so the
      // Debug Logs demo screen can show the live event stream. Without
      // this callback, log lines fall back to dart:developer's log.
      logCallback: (message, {error, stackTrace}) {
        // Also print to stdout so the same lines show up in `flutter run`
        // terminal output — easier to copy/paste for issue reports than
        // scrolling Talker's UI list.
        debugPrint('[player_core] $message');
        if (error != null) {
          talker.error(message, error, stackTrace);
        } else {
          talker.info(message);
        }
      },
    ),
  );
  // Wire audio_service (lock-screen, MediaSession) into the default scope.
  await CoreAudioHandler.initialize();
  runApp(const CorePlayerExampleApp());
}

class CorePlayerExampleApp extends StatelessWidget {
  const CorePlayerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'player_core example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const List<_Demo> _demos = <_Demo>[
    _Demo(
      title: 'Single track',
      subtitle: 'loadAndPlay, seek, speed, volume, loop',
      icon: Icons.audiotrack,
      builder: _buildSingleTrack,
    ),
    _Demo(
      title: 'Playlist',
      subtitle: 'queue, skipToNext/Prev, shuffle, loop modes',
      icon: Icons.queue_music,
      builder: _buildPlaylist,
    ),
    _Demo(
      title: 'Queue mutation',
      subtitle: 'insertNext / appendToQueue / removeAt / moveItem / replaceAt',
      icon: Icons.playlist_play,
      builder: _buildQueueMutation,
    ),
    _Demo(
      title: 'Multi-scope',
      subtitle: 'two parallel audio scopes; transfer OS focus',
      icon: Icons.layers,
      builder: _buildMultiScope,
    ),
    _Demo(
      title: 'Observer',
      subtitle: 'CorePlayerObserver lifecycle event log',
      icon: Icons.list_alt,
      builder: _buildObserver,
    ),
    _Demo(
      title: 'Debug Logs',
      subtitle: 'Live audio_player bridge log stream (Talker)',
      icon: Icons.bug_report,
      builder: _buildDebugLogs,
    ),
    _Demo(
      title: 'Raw media_kit (no wrapper)',
      subtitle:
          'Test seek behavior with media_kit.Player directly — bypass CorePlayer entirely',
      icon: Icons.science,
      builder: _buildRawMediaKit,
    ),
    _Demo(
      title: 'Resume from cold start',
      subtitle: 'snapshot() / restore() — Suno-tier resume-where-you-left-off',
      icon: Icons.restore,
      builder: _buildResumeFromColdStart,
    ),
    _Demo(
      title: 'Auto-radio + position stream',
      subtitle:
          'positionDataStream-fed scrubber + onQueueExhausted append callback',
      icon: Icons.radio,
      builder: _buildAutoRadio,
    ),
    _Demo(
      title: 'HLS audio source',
      subtitle: 'Play an .m3u8 manifest URL — libmpv native HLS demuxer',
      icon: Icons.cell_tower,
      builder: _buildHls,
    ),
  ];

  static Widget _buildSingleTrack(BuildContext _) => const SingleTrackDemo();
  static Widget _buildPlaylist(BuildContext _) => const PlaylistDemo();
  static Widget _buildQueueMutation(BuildContext _) => const QueueMutationDemo();
  static Widget _buildMultiScope(BuildContext _) => const MultiScopeDemo();
  static Widget _buildObserver(BuildContext _) => const ObserverDemo();
  static Widget _buildDebugLogs(BuildContext _) => const DebugLogsDemo();
  static Widget _buildRawMediaKit(BuildContext _) => const RawMediaKitDemo();
  static Widget _buildResumeFromColdStart(BuildContext _) =>
      const ResumeFromColdStartDemo();
  static Widget _buildAutoRadio(BuildContext _) =>
      const AutoRadioAndPositionStreamDemo();
  static Widget _buildHls(BuildContext _) => const HlsDemo();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('player_core example')),
      body: SafeArea(
        child: ListView(
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Tip: while playing, lock your device — playback controls should '
                'appear on the lock-screen and notification shade.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
            for (int i = 0; i < _demos.length; i++)
              ListTile(
                key: ValueKey<int>(i),
                leading: Icon(_demos[i].icon),
                title: Text(_demos[i].title),
                subtitle: Text(_demos[i].subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(builder: _demos[i].builder),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Demo {
  const _Demo({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}
