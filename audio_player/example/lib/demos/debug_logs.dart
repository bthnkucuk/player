import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../main.dart' show talker;

/// Live view of the [Talker] log stream wired up in `main.dart` to the
/// [CorePlayerConfiguration.logCallback]. Use this to diagnose lock-screen /
/// MediaSession binding issues on real devices: open this screen, then trigger
/// a play / lock / interruption flow in another demo and copy the log out.
class DebugLogsDemo extends StatelessWidget {
  const DebugLogsDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return TalkerScreen(talker: talker, appBarTitle: 'Debug Logs');
  }
}
