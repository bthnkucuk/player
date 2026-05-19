import 'package:equatable/equatable.dart';

class CorePlayerAudioSource extends Equatable {
  /// Remote URL (http/https/etc). Mutually exclusive with [filePath]; when
  /// both are null `CorePlayer.load` throws.
  final String? url;

  /// Local filesystem path. Replaces the previous `File` field — the
  /// abstraction no longer depends on `dart:io` (which is not safe to import
  /// from web builds).
  final String? filePath;

  final String title;
  final String? album;
  final String? artist;
  final String? genre;
  final Uri? artUri;

  final Map<String, String>? httpHeaders;

  const CorePlayerAudioSource({
    this.url,
    this.filePath,
    required this.title,
    this.album,
    this.artist,
    this.genre,
    this.artUri,
    this.httpHeaders,
  });

  @override
  List<Object?> get props => [
    url,
    filePath,
    title,
    album,
    artist,
    genre,
    artUri,
    httpHeaders,
  ];
}
