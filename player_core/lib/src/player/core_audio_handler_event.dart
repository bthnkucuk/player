/// Event types and registry that wire `CorePlayer` instances to platform-level
/// audio control (notifications, lock screen, audio focus). Platform-specific
/// setup (audio_service / audio_session) is provided by impl packages via
/// [CoreAudioServiceBridge] — see `audio_player` for the reference impl.
library;

abstract class CoreAudioHandlerEvent {}

class CoreAudioHandlerPlayEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerPlayEvent';
  }
}

class CoreAudioHandlerPauseEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerPauseEvent';
  }
}

class CoreAudioHandlerStopEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerStopEvent';
  }
}

class CoreAudioHandlerSeekEvent extends CoreAudioHandlerEvent {
  final Duration position;
  CoreAudioHandlerSeekEvent(this.position);
  @override
  String toString() {
    return 'CoreAudioHandlerSeekEvent(position: $position)';
  }
}

class CoreAudioHandlerTaskRemovedEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerTaskRemovedEvent';
  }
}

/// Fired by the platform bridge when the system requests "skip to next".
/// Lock-screen / notification "next" buttons and the corresponding
/// [MediaControl] / [MediaAction] route through this event so the active
/// [CorePlayer] can advance its queue.
class CoreAudioHandlerSkipToNextEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerSkipToNextEvent';
  }
}

/// Fired by the platform bridge when the system requests "skip to previous".
/// See [CoreAudioHandlerSkipToNextEvent] for the analogous next-direction event.
class CoreAudioHandlerSkipToPreviousEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerSkipToPreviousEvent';
  }
}

/// Abstraction over `audio_session`'s `AudioInterruptionType` so the
/// `player_core` package does not leak the platform-typed enum across its
/// public surface.
enum CoreAudioInterruptionType { pause, duck, unknown }

/// Fired by the platform bridge when the OS reports that another audio app
/// or system event is about to begin interrupting our playback (phone call,
/// Instagram Reels, etc.). Impls typically pause in response.
class CoreAudioHandlerInterruptionBeginEvent extends CoreAudioHandlerEvent {
  final CoreAudioInterruptionType type;
  CoreAudioHandlerInterruptionBeginEvent(this.type);
  @override
  String toString() {
    return 'CoreAudioHandlerInterruptionBeginEvent(type: $type)';
  }
}

/// Fired by the platform bridge when an interruption ends. [shouldResume] is
/// true when the bridge believes we were playing at the start of the
/// interruption AND the OS hint indicates we are allowed to resume.
class CoreAudioHandlerInterruptionEndEvent extends CoreAudioHandlerEvent {
  final bool shouldResume;
  CoreAudioHandlerInterruptionEndEvent({required this.shouldResume});
  @override
  String toString() {
    return 'CoreAudioHandlerInterruptionEndEvent(shouldResume: $shouldResume)';
  }
}

/// Fired when the output route becomes "noisy" (e.g. headphones unplugged).
/// Impls should pause playback so audio does not blast through speakers.
class CoreAudioHandlerBecomingNoisyEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerBecomingNoisyEvent';
  }
}

/// Fired when the host app comes back to the foreground. Used as a fallback
/// for iOS, where some interrupting apps (Reels/TikTok) do not emit a
/// well-formed interruption-end with `shouldResume`.
class CoreAudioHandlerAppResumeEvent extends CoreAudioHandlerEvent {
  @override
  String toString() {
    return 'CoreAudioHandlerAppResumeEvent';
  }
}
