import 'dart:async';
import 'dart:developer';

import 'package:meta/meta.dart';
import 'package:player_core/src/player/core_audio_handler_event.dart';
import 'package:player_core/src/player/core_audio_service_bridge.dart';
import 'package:rxdart/rxdart.dart';
import 'package:player_core/src/player/core_player.dart';

/// Registry / event hub for `CorePlayer` instances — a single **audio scope**.
///
/// Each [CoreAudioHandler] instance is an independent scope with its own set of
/// attached players, its own current player, and its own [eventStream]. Most
/// apps need only the default scope ([CoreAudioHandler.instance]); apps that
/// need parallel audio (preview + main, ambient + foreground, etc.) can
/// create additional scopes.
///
/// Process-wide singletons (shared across scopes):
///   - The platform [CoreAudioServiceBridge] (one `AudioService.init` per
///     process; OS allows only one `BaseAudioHandler`).
///   - The `AudioSession` from `audio_session` (OS singleton).
///   - The "active scope" — exactly one scope owns the OS surface
///     (lock-screen, MediaSession, audio_session activate/deactivate) at
///     any time. Transfer via [requestSystemAudioFocus].
///
/// Scope interaction rules:
///   - **Within a scope:** attaching a new player auto-pauses any other
///     attached player in the same scope (same as pre-Phase-13 behavior).
///   - **Across scopes:** players in different scopes play simultaneously.
///     Attaching to scope B does NOT pause players in scope A.
///   - **Lock-screen / MediaItem:** only the active scope drives the
///     lock-screen.
///   - **Audio session:** only the active scope toggles
///     `activateSession` / `deactivateSession`.
///   - **System events:** lock-screen play/pause/skip events flow to the
///     active scope's eventStream only.
///
/// Pre-Phase-13 code that uses [CoreAudioHandler.instance] and the legacy
/// static API (`attachPlayer`, `detachPlayer`, `attachedPlayers`,
/// `currentPlayer`, `isCurrentPlayer`) keeps working unchanged — those
/// statics delegate to the default scope.
class CoreAudioHandler {
  /// Creates a new audio scope.
  ///
  /// Each scope is independent — its attached players, current player, and
  /// event stream are all per-instance. Only the active scope (see
  /// [requestSystemAudioFocus]) drives the OS surface.
  ///
  /// For single-scope apps, use [CoreAudioHandler.instance] (the default scope)
  /// instead of constructing your own.
  CoreAudioHandler({String? debugName})
    : debugName = debugName ?? 'scope-${_scopeCounter++}';

  /// Internal-use named constructor for the default scope. Distinct from the
  /// public factory so the default scope's debugName is stable across
  /// process lifetime.
  CoreAudioHandler._default() : debugName = 'default';

  static int _scopeCounter = 0;

  /// Human-readable name used in logs. Stable for the lifetime of this scope.
  final String debugName;

  // ---- Process-wide state -------------------------------------------------

  static bool _initialized = false;

  /// Platform bridge installed by the impl package (e.g.
  /// `CorePlayerMediaKit.ensureInitialized`). May be null when running under
  /// tests that don't need the platform side. Shared across all scopes.
  static CoreAudioServiceBridge? _bridge;

  /// The default scope. Lazy-created on first access.
  static CoreAudioHandler? _defaultScopeStorage;

  /// The scope that currently owns the OS surface. Defaults to the default
  /// scope when null.
  static CoreAudioHandler? _activeScope;

  /// Backing subject for [activeScopeStream]. Lives for the process lifetime
  /// — never closed (subjects created at class load are valid forever).
  static final BehaviorSubject<CoreAudioHandler?> _activeScopeSubject =
      BehaviorSubject<CoreAudioHandler?>.seeded(null);

  /// Mutate [_activeScope] and broadcast the new value on
  /// [activeScopeStream]. All assignments to [_activeScope] must route
  /// through this helper.
  static void _setActiveScope(CoreAudioHandler? scope) {
    _activeScope = scope;
    _activeScopeSubject.add(scope);
  }

  /// Stream of active-scope changes. Emits when [requestSystemAudioFocus]
  /// or [releaseSystemAudioFocus] transfers OS surface ownership.
  /// Seeded with the default scope after [initialize] completes (or null
  /// if not yet initialized).
  static ValueStream<CoreAudioHandler?> get activeScopeStream =>
      _activeScopeSubject.stream;

  /// Install the platform bridge. Idempotent: called once during
  /// `CorePlayerMediaKit.ensureInitialized` (or equivalent).
  static void registerBridge(CoreAudioServiceBridge bridge) {
    _bridge = bridge;
  }

  @visibleForTesting
  static CoreAudioServiceBridge? get debugBridge => _bridge;

  @visibleForTesting
  static void debugSetBridge(CoreAudioServiceBridge? bridge) {
    _bridge = bridge;
  }

  @visibleForTesting
  static void setInitialized(bool value) {
    _initialized = value;
  }

  /// Full cleanup for test isolation: clears attached players, current player,
  /// resets [_initialized] to false, and nulls the cached bridge. Also clears
  /// any non-default scopes and resets the active-scope pointer.
  @visibleForTesting
  static void resetForTest() {
    _defaultScopeStorage?._attachedPlayers.clear();
    _defaultScopeStorage?._currentPlayer = null;
    _setActiveScope(null);
    _initialized = false;
    _bridge = null;
  }

  /// Clears multi-scope state: empties every known scope's attached players,
  /// nulls every current player, and resets the active-scope pointer. The
  /// default-scope storage is preserved so subsequent
  /// [CoreAudioHandler.instance] reads continue to return the same object —
  /// matching pre-Phase-13 singleton identity in tests that compare across
  /// reset boundaries.
  @visibleForTesting
  static void resetAllScopes() {
    final defaultScope = _defaultScopeStorage;
    if (defaultScope != null) {
      defaultScope._attachedPlayers.clear();
      defaultScope._currentPlayer = null;
    }
    _setActiveScope(null);
    _scopeCounter = 0;
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    // Ensure the default scope exists and is the active scope on first init.
    final scope = _defaultScopeStorage ??= CoreAudioHandler._default();
    if (_activeScope == null) {
      _setActiveScope(scope);
    }
    await _bridge?.initialize(scope);
    _initialized = true;
  }

  /// The default scope. Lazy-created on first access.
  ///
  /// All single-scope code (and pre-Phase-13 call sites) implicitly use this
  /// scope. Returns `null` when [initialize] has not been called yet —
  /// matching the historical contract — but the default scope object itself
  /// is created lazily for back-compat statics to delegate to.
  static CoreAudioHandler? get instance => _initialized ? _defaultScope : null;

  /// Internal accessor that always returns the default scope object, lazily
  /// creating it. Used by the back-compat statics so they can target the
  /// default scope even when [initialize] has not been called yet (the
  /// statics themselves throw via [_requireInitialized] when appropriate).
  static CoreAudioHandler get _defaultScope =>
      _defaultScopeStorage ??= CoreAudioHandler._default();

  /// The scope that currently owns the OS surface (lock-screen, audio
  /// session, MediaItem). Defaults to the default scope. Never null after
  /// [initialize]; may be null before.
  static CoreAudioHandler? get activeScope =>
      _activeScope ?? (_initialized ? _defaultScope : null);

  // ---- Per-scope state ----------------------------------------------------

  CorePlayer? _currentPlayer;
  final Set<CorePlayer> _attachedPlayers = {};

  final StreamController<CoreAudioHandlerEvent?> _eventController =
      StreamController<CoreAudioHandlerEvent?>.broadcast();

  /// Inbound event stream for this scope: system controls (notification,
  /// lock screen, `BaseAudioHandler` overrides) flow through here to the
  /// active player IN THIS SCOPE. Only the active scope receives system
  /// events from the bridge.
  Stream<CoreAudioHandlerEvent?> get eventStream => _eventController.stream;

  /// Push a system-control event onto this scope's [eventStream]. Intended
  /// for use by platform bridges (e.g. `audio_player`) and tests —
  /// not for application code.
  @internal
  void postEvent(CoreAudioHandlerEvent? event) {
    if (_eventController.isClosed) return;
    _eventController.add(event);
  }

  @visibleForTesting
  void debugPostEvent(CoreAudioHandlerEvent? event) =>
      _eventController.add(event);

  /// True if this scope currently owns the OS surface (lock-screen,
  /// MediaSession, audio_session). Exactly one scope is active at a time.
  bool get isActiveScope =>
      identical(_activeScope ?? _defaultScopeStorage, this);

  /// Transfer OS surface ownership to this scope.
  ///
  /// What changes:
  ///   - Lock-screen MediaItem switches to this scope's [current] player.
  ///   - Subsequent system events (lock-screen play/pause/skip) flow to
  ///     this scope's [eventStream].
  ///   - Audio session activate/deactivate calls are owned by this scope.
  ///
  /// What does NOT change:
  ///   - The previously-active scope's players keep playing — they are NOT
  ///     paused (mixed audio).
  ///   - The audio session stays active as long as any scope has attached
  ///     players (the previously-active scope already activated it; we
  ///     don't deactivate on focus transfer).
  ///
  /// No-op when this scope is already active.
  Future<void> requestSystemAudioFocus() async {
    if (isActiveScope) return;
    _setActiveScope(this);
    _bridge?.refreshMediaItemForActiveScope();
  }

  /// Relinquish OS surface ownership.
  ///
  /// The [fallbackTo] scope becomes active; defaults to the default scope.
  /// The lock-screen MediaItem updates to reflect the fallback scope's
  /// current player (or clears if it has none). The previously-active
  /// scope's players are NOT paused.
  Future<void> releaseSystemAudioFocus({CoreAudioHandler? fallbackTo}) async {
    if (!isActiveScope) return;
    _setActiveScope(fallbackTo ?? _defaultScope);
    _bridge?.refreshMediaItemForActiveScope();
  }

  // ---- Instance attach/detach (multi-scope API) ---------------------------

  /// Attach [player] to this scope.
  ///
  /// Returns `true` if [player] was not already attached, `false` otherwise
  /// (matches the legacy static API's return contract — semantically "this
  /// player just became the new current player AND was not previously
  /// already current").
  ///
  /// Within-scope: other attached players in THIS scope are auto-paused.
  /// Cross-scope: players in OTHER scopes are NOT touched (mixed audio).
  ///
  /// Does NOT activate the audio session — that is deferred to actual
  /// playback intent via [requestActiveSession], called by impls from
  /// inside [CorePlayer.play]. This prevents opening a screen with a player
  /// from interrupting other apps' audio (Spotify/YouTube) before the user
  /// presses play.
  Future<bool> attach(CorePlayer player) async {
    if (!_initialized) {
      throw Exception('AudioHandler not initialized');
    }

    final bool wasNew = _currentPlayer != player;

    _attachedPlayers.add(player);
    _currentPlayer = player;

    for (var p in _attachedPlayers) {
      if (!p.isDisposed && p != _currentPlayer) {
        unawaited(p.pause());
      }
    }

    return wasNew;
  }

  /// Activates the underlying audio session if conditions are met:
  /// this scope is currently active, has at least one attached player,
  /// and the bridge is registered. Idempotent — the bridge's
  /// `_hasUserActivatedSession` gate skips redundant calls.
  ///
  /// Called by impls from inside [CorePlayer.play] to defer OS focus
  /// acquisition until actual playback intent is signaled.
  Future<void> requestActiveSession() async {
    if (!isActiveScope || _attachedPlayers.isEmpty || _bridge == null) return;
    await _bridge!.activateSession();
  }

  /// Detach [player] from this scope. Audio-session deactivation fires only
  /// when this scope is the active scope AND its player set just emptied.
  Future<void> detach(CorePlayer player) async {
    if (!_initialized) {
      throw Exception('AudioHandler not initialized');
    }
    _attachedPlayers.remove(player);
    if (_currentPlayer == player) {
      _currentPlayer = null;
    }

    // Release the audio session when no players remain attached in the
    // active scope so other audio apps can resume on iOS / regain focus
    // on Android.
    if (_attachedPlayers.isEmpty && isActiveScope) {
      await _bridge?.deactivateSession();
    }
  }

  /// Set of players attached to this scope (unmodifiable snapshot).
  Set<CorePlayer> get players => Set.unmodifiable(_attachedPlayers);

  /// Player most recently attached to this scope (the "current" player for
  /// this scope), or null if nothing is attached / current was detached.
  CorePlayer? get current => _currentPlayer;

  /// True if [player] is the current player IN THIS SCOPE.
  bool isCurrent(CorePlayer player) => _currentPlayer == player;

  // ---- Back-compat static API (delegates to default scope) ----------------

  /// Snapshot of players attached to the default scope.
  ///
  /// Back-compat with pre-Phase-13: multi-scope users should prefer the
  /// instance getter [players] on their specific scope.
  static List<CorePlayer> get attachedPlayers =>
      _defaultScope._attachedPlayers.toList();

  /// Current player of the default scope.
  ///
  /// Back-compat with pre-Phase-13: multi-scope users should prefer the
  /// instance getter [current] on their specific scope.
  static CorePlayer? get currentPlayer => _defaultScope._currentPlayer;

  /// True if [player] is the current player of the default scope.
  ///
  /// Back-compat with pre-Phase-13: multi-scope users should prefer the
  /// instance method [isCurrent] on their specific scope.
  static bool isCurrentPlayer(CorePlayer player) {
    return _defaultScope._currentPlayer == player;
  }

  /// Attach [player] to the default scope.
  ///
  /// Back-compat with pre-Phase-13: multi-scope users should prefer the
  /// instance method [attach] on their specific scope.
  static Future<bool> attachPlayer(CorePlayer player) =>
      _defaultScope.attach(player);

  /// Detach [player] from the default scope.
  ///
  /// Back-compat with pre-Phase-13: multi-scope users should prefer the
  /// instance method [detach] on their specific scope.
  static Future<void> detachPlayer(CorePlayer player) =>
      _defaultScope.detach(player);

  // ---- Instance: bridge passthrough --------------------------------------

  /// Forward an opaque `PlaybackState` value to the bridge's notification
  /// stream. No-op when no bridge is installed.
  void emitPlaybackState(Object state) {
    _bridge?.emitPlaybackState(state);
  }

  /// Forward an opaque `MediaItem` value (nullable) to the bridge's
  /// notification stream. No-op when no bridge is installed.
  void emitMediaItem(Object? item) {
    _bridge?.emitMediaItem(item);
  }

  /// Current `MediaItem` (opaque) — accessed via the bridge. Returns null
  /// when no bridge / no MediaItem.
  Object? get currentMediaItem => _bridge?.currentMediaItem;

  /// Called by the bridge's `BaseAudioHandler.onTaskRemoved` override OR
  /// directly by tests. Clears attached players IN THIS SCOPE, stops live
  /// ones, emits a task-removed event to this scope's listeners, and
  /// releases the audio session if this scope is active.
  Future<void> onTaskRemoved() async {
    log('CoreAudioHandler($debugName) onTaskRemoved');
    _currentPlayer = null;
    if (isActiveScope) {
      _bridge?.emitStopState();
    }
    // Distinct from a user-initiated stop: consumers (and the per-player
    // bridge in impls) can react differently to "system tore down our task"
    // vs "user pressed stop".
    if (!_eventController.isClosed) {
      _eventController.add(CoreAudioHandlerTaskRemovedEvent());
    }

    final attachedPlayers = _attachedPlayers.toList(growable: false);
    _attachedPlayers.clear();

    for (final player in attachedPlayers) {
      if (!player.isDisposed) {
        await player.stop();
      }
    }

    // Release the audio session when the task is torn down so other audio
    // apps regain focus immediately. Only the active scope drives this.
    if (isActiveScope) {
      await _bridge?.deactivateSession();
    }
  }
}
