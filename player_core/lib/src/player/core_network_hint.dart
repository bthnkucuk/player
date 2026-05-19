/// Connectivity classification the consumer pushes into the player. The
/// wrapper does NOT detect connectivity itself — apps wire this from
/// `connectivity_plus`, a platform channel, or their own backend
/// heartbeat. The wrapper's only job is to honour a policy mapping
/// (configured via [CorePlayerConfiguration.networkPolicy]) when the hint
/// changes.
enum NetworkHint {
  /// Wi-Fi, ethernet, or any unmetered connection. Default behaviour:
  /// play freely.
  unmetered,

  /// Cellular / mobile data or any metered connection. Default
  /// behaviour: play (consumer can override via policy).
  metered,

  /// No usable network. Default behaviour: pause if currently playing;
  /// resume on the next non-offline hint if the consumer opts in.
  offline,
}

/// Behaviour mapping for [NetworkHint] transitions. Configure once via
/// [CorePlayerConfiguration.networkPolicy]; runtime changes happen via
/// the [CorePlayer.notifyNetworkHint] entry point.
class NetworkPolicy {
  const NetworkPolicy({
    this.pauseOnOffline = true,
    this.pauseOnMetered = false,
    this.resumeWhenBackOnline = false,
  });

  /// Pause playback when [NetworkHint.offline] arrives mid-playback.
  /// Default true — offline + playing is almost always a stall in the
  /// making; pausing is the courteous behaviour. Disable for apps that
  /// want to play out cached content past the offline boundary.
  final bool pauseOnOffline;

  /// Pause when transitioning from unmetered → metered while playing.
  /// Default false; opt-in for data-conservative apps.
  final bool pauseOnMetered;

  /// On hint transitions back to [NetworkHint.unmetered] from offline,
  /// auto-resume IF the wrapper paused this player due to a prior
  /// network event. Defaults to false — explicit user-driven resume is
  /// usually less surprising. Enable for kiosk / always-on apps.
  final bool resumeWhenBackOnline;

  /// No-op policy: never auto-pause or resume on hints. Hints are
  /// recorded but ignored.
  static const NetworkPolicy none = NetworkPolicy(
    pauseOnOffline: false,
    pauseOnMetered: false,
    resumeWhenBackOnline: false,
  );
}
