part of 'core_player_media_kit.dart';

/// Queue-navigation methods (skip / shuffle / loop mode) for
/// [CorePlayerMediaKit]. Extracted from the main class; behaviour unchanged.
mixin CorePlayerMediaKitNavigation on CorePlayer
    implements CorePlayerMediaKitConcurrency {}
