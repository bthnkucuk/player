import 'package:player_core/player_core.dart';

/// Global observer hook for [CorePlayer] lifecycle events.
///
/// Set [CorePlayer.observer] once (typically in app bootstrap) to receive
/// callbacks for every player instance. Inspired by `flutter_bloc`'s
/// `BlocObserver` pattern.
///
/// Override only the callbacks you need; defaults are no-ops.
abstract class CorePlayerObserver {
  const CorePlayerObserver();

  void onCreate(CorePlayer player) {}
  void onLoad(CorePlayer player, CorePlayerAudioSource source) {}
  void onPlay(CorePlayer player) {}
  void onPause(CorePlayer player) {}
  void onStop(CorePlayer player) {}
  void onSeek(CorePlayer player, Duration position) {}
  void onStateChange(
    CorePlayer player,
    CorePlayerState from,
    CorePlayerState to,
  ) {}
  void onError(CorePlayer player, CorePlayerFailure failure) {}
  void onDispose(CorePlayer player) {}
}
