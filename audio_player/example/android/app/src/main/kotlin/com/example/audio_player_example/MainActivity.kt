package com.example.audio_player_example

import com.ryanheise.audioservice.AudioServiceFragmentActivity

// MUST extend AudioServiceFragmentActivity (not FlutterActivity) for
// audio_service to receive lock-screen media button events and bind the
// MediaSession to this activity's lifecycle. Without this, the foreground
// service starts but Android's MediaSessionManager doesn't see our
// session as "the activity owning audio" — lock-screen stays on whichever
// app last claimed the surface (e.g. YouTube).
//
// See: https://pub.dev/packages/audio_service — Android XML / activity setup.
class MainActivity : AudioServiceFragmentActivity()
