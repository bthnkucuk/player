part of 'core_player_media_kit.dart';

/// Network-state hook for [CorePlayerMediaKit]. The wrapper does NOT
/// probe connectivity itself — the consumer pushes hints via
/// [CorePlayer.notifyNetworkHint] and the configured [NetworkPolicy]
/// decides whether to auto-pause / auto-resume.
///
/// The mixin tracks the most recent hint, plus a boolean
/// `_pausedByNetworkPolicy` flag that distinguishes a wrapper-issued
/// pause (eligible for auto-resume) from a user-driven pause (NOT
/// eligible — auto-resume after a manual pause would feel like the
/// player is fighting the user).
mixin CorePlayerMediaKitNetwork on CorePlayer {
  // Host-class members accessed from this mixin. Satisfied by the
  // concrete [CorePlayerMediaKit] at mix-in time.
  bool get _disposed;
  Never _throwAndEmit(CorePlayerFailure failure);

  final BehaviorSubject<NetworkHint> _networkHintSubject =
      BehaviorSubject<NetworkHint>.seeded(NetworkHint.unmetered);

  /// True when the most recent pause was issued by the network-policy
  /// applier in [notifyNetworkHint]. Cleared by ANY of:
  ///   - a user-driven [play] (the user explicitly resumed; the prior
  ///     policy-pause no longer represents the current intent),
  ///   - a user-driven [pause] (we already are paused for a non-network
  ///     reason; auto-resume must not fight the user),
  ///   - a successful auto-resume.
  bool _pausedByNetworkPolicy = false;

  /// Re-entrancy guard: true while [notifyNetworkHint] is actively
  /// dispatching pause()/play() through the wrapper's public transport
  /// methods. The user-facing transport hooks ([_clearNetworkAutoResume])
  /// skip flag-clearing while this is set so the auto-resume bookkeeping
  /// survives the recursion.
  bool _inNetworkPolicyDispatch = false;

  @override
  NetworkHint get currentNetworkHint => _networkHintSubject.value;

  @override
  Stream<NetworkHint> get networkHintStream => _networkHintSubject.stream;

  @override
  Future<void> notifyNetworkHint(NetworkHint hint) async {
    if (_disposed) {
      _throwAndEmit(const PlayerDisposedFailure());
    }
    final previous = _networkHintSubject.value;
    // Idempotent: identical back-to-back hints don't emit and don't
    // re-trigger policy. Without this guard a chatty connectivity
    // listener could spam pause()/play() with no observable transition.
    if (previous == hint) return;

    final policy = CorePlayerMediaKit._configuration.networkPolicy;
    final wasPlaying = isPlaying;

    _networkHintSubject.add(hint);

    // Pause on offline: wrapper-issued, so mark `_pausedByNetworkPolicy`
    // for the auto-resume eligibility check on the next unmetered hint.
    if (hint == NetworkHint.offline &&
        wasPlaying &&
        policy.pauseOnOffline) {
      await _dispatchPolicyPause();
      return;
    }

    // Pause on transition to metered. Same eligibility-flag bookkeeping.
    if (hint == NetworkHint.metered &&
        previous != NetworkHint.metered &&
        wasPlaying &&
        policy.pauseOnMetered) {
      await _dispatchPolicyPause();
      return;
    }

    // Auto-resume on transition back to unmetered. Gated on the flag so
    // a user pause between offline and unmetered cancels the resume.
    if (hint == NetworkHint.unmetered &&
        _pausedByNetworkPolicy &&
        policy.resumeWhenBackOnline) {
      await _dispatchPolicyResume();
      return;
    }
  }

  /// Issue a policy-driven pause and mark the player as eligible for
  /// auto-resume. Sets the re-entrancy guard so the user-facing pause
  /// hook does not clear the eligibility flag we just set.
  Future<void> _dispatchPolicyPause() async {
    _inNetworkPolicyDispatch = true;
    try {
      await pause();
      _pausedByNetworkPolicy = true;
    } finally {
      _inNetworkPolicyDispatch = false;
    }
  }

  /// Issue a policy-driven resume. Clears the eligibility flag so a
  /// subsequent offline -> unmetered cycle starts fresh.
  Future<void> _dispatchPolicyResume() async {
    _inNetworkPolicyDispatch = true;
    try {
      _pausedByNetworkPolicy = false;
      await play();
    } finally {
      _inNetworkPolicyDispatch = false;
    }
  }

  /// Drop the auto-resume eligibility flag. Called from the user-facing
  /// [play] / [pause] paths so a manual transport action overrides any
  /// pending policy-driven resume. No-op while a policy dispatch is in
  /// progress (the dispatcher itself manages the flag).
  // Referenced from [CorePlayerMediaKitPlayback] via an abstract redeclaration;
  // the analyzer's unused-element scan does not follow the cross-mixin call.
  // ignore: unused_element
  void _clearNetworkAutoResume() {
    if (_inNetworkPolicyDispatch) return;
    _pausedByNetworkPolicy = false;
  }
}
