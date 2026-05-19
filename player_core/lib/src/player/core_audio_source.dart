import 'package:equatable/equatable.dart';

/// JSON `type` discriminator emitted by [CorePlayerAudioSource.toJson]. Today
/// only one source class exists, so this resolves to `'remote'` (when [url]
/// is set) or `'file'` (when [filePath] is set, or neither is set —
/// treated as a file placeholder). Future sealed subclasses (Faz S:
/// `LiveAudioSource`, `HlsAudioSource`) will add their own discriminator
/// values; [CorePlayerAudioSource.fromJson] should switch on this key.
const String kCorePlayerAudioSourceTypeKey = 'type';

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

  /// Serialises this source to a plain `Map<String, Object?>` suitable for
  /// `JsonCodec.encode`. The `type` discriminator is the extension point for
  /// future sealed subtypes (Faz S): existing readers should accept any
  /// known type and reject unknown ones at the caller's boundary.
  ///
  /// Rule: `type == 'remote'` when [url] is non-null; otherwise `'file'`.
  /// If both fields are null we still emit `'file'` so a downstream
  /// `_toMedia` call surfaces the existing [InvalidMediaSourceFailure] at
  /// play time rather than silently dropping the source here.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      kCorePlayerAudioSourceTypeKey: url != null ? 'remote' : 'file',
      'url': url,
      'filePath': filePath,
      'title': title,
      'album': album,
      'artist': artist,
      'genre': genre,
      'artUri': artUri?.toString(),
      // Coerce to a fresh map so callers cannot mutate our internal state
      // through the returned Map view.
      'httpHeaders': httpHeaders == null ? null : Map<String, String>.from(httpHeaders!),
    };
  }

  /// Rehydrates a source previously produced by [toJson]. Tolerant of
  /// nullable fields; throws [FormatException] when [title] is missing
  /// (the only required field).
  ///
  /// Unknown `type` discriminator values throw — Faz S adds new types via
  /// new factories; missing knowledge here means we don't understand the
  /// snapshot and should fail loudly rather than silently materialise an
  /// unplayable source.
  factory CorePlayerAudioSource.fromJson(Map<String, Object?> json) {
    final type = json[kCorePlayerAudioSourceTypeKey];
    if (type != null && type != 'remote' && type != 'file') {
      throw FormatException('Unknown audio-source type: $type');
    }
    final title = json['title'];
    if (title is! String) {
      throw const FormatException('Audio source JSON missing required "title"');
    }
    final headers = json['httpHeaders'];
    Map<String, String>? typedHeaders;
    if (headers is Map) {
      typedHeaders = headers.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    final artUri = json['artUri'];
    return CorePlayerAudioSource(
      title: title,
      url: json['url'] as String?,
      filePath: json['filePath'] as String?,
      album: json['album'] as String?,
      artist: json['artist'] as String?,
      genre: json['genre'] as String?,
      artUri: artUri is String ? Uri.parse(artUri) : null,
      httpHeaders: typedHeaders,
    );
  }
}
