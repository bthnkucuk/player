import 'package:equatable/equatable.dart';
import 'package:player_core/src/failures/core_player_failure.dart';

/// JSON `type` discriminator key emitted by every concrete [CoreAudioSource]
/// subtype. Faz S adds `'hls'` (S2) and `'live'` (S3); each new subtype owns
/// its own discriminator value so [CoreAudioSource.fromJson]'s switch stays
/// the single dispatch point.
///
/// Naming WHY: the previous schema used `'remote'` for HTTP sources because
/// the type list was a one-element open set. Sealed subtypes now name the
/// transport (`'http'`) so future variants (`'hls'`, `'live'`, ...) don't
/// re-litigate what "remote" means. Persistence migration is a clean break —
/// no released app reads these payloads yet, so we did not bump the queue
/// envelope's `schemaVersion`.
const String kCoreAudioSourceTypeKey = 'type';

/// Sealed source hierarchy. Use the constructor of the specific subtype
/// ([HttpAudioSource], [FileAudioSource]) — never instantiate the base
/// directly. Faz S2 and S3 add `HlsAudioSource` and `LiveAudioSource`.
///
/// `title` is required (the lock-screen / `MediaItem` always needs one).
/// `estimatedDuration` lives on the base class so every subtype inherits a
/// pre-load hint the wrapper can seed `MediaItem.duration` with before the
/// real duration arrives from the engine; consumers that know nothing leave
/// it null and the wrapper falls back to zero until the engine reports back.
sealed class CoreAudioSource extends Equatable {
  const CoreAudioSource({
    required this.title,
    this.artist,
    this.artUri,
    this.estimatedDuration,
  });

  /// Display title for the lock-screen and queue UI.
  final String title;
  final String? artist;
  final Uri? artUri;

  /// Pre-load duration hint used by the wrapper to seed
  /// `MediaItem.duration` before the real duration arrives from the engine.
  /// Optional; callers that know nothing leave it null and the wrapper
  /// emits zero until the engine reports back.
  final Duration? estimatedDuration;

  /// Serialises this source to a plain `Map<String, Object?>` suitable for
  /// `JsonCodec.encode`. The `type` discriminator is the dispatch key for
  /// [fromJson]; new sealed subtypes (Faz S2/S3) add their own value.
  Map<String, Object?> toJson();

  /// Discriminator-driven dispatch. Unknown `type` values reject with
  /// [SnapshotMalformedFailure].
  ///
  /// `'live'` is a defined-but-unrestorable discriminator: a snapshot that
  /// contains a [LiveAudioSource] cannot round-trip because the segment
  /// stream is process-local state. We reject with [SnapshotMalformedFailure]
  /// at this seam (rather than at the value-class level) so the queue-level
  /// restore loop sees a single, structurally-uniform failure shape across
  /// every "unrestorable" subtype.
  factory CoreAudioSource.fromJson(Map<String, Object?> json) {
    final type = json[kCoreAudioSourceTypeKey];
    return switch (type) {
      'http' => HttpAudioSource.fromJson(json),
      'file' => FileAudioSource.fromJson(json),
      'hls' => HlsAudioSource.fromJson(json),
      'live' => throw const SnapshotMalformedFailure(
        'LiveAudioSource entries cannot be restored from a snapshot',
      ),
      _ => throw SnapshotMalformedFailure(
        'Unknown CoreAudioSource type: $type',
      ),
    };
  }
}

/// HTTP(S) streamed source. The transport-level `headers` map (kept on the
/// subtype rather than the base) is forwarded to the engine's HTTP client
/// for auth-gated streams. Faz S2 will add a separate [HlsAudioSource] for
/// playlist-based adaptive bitrate streams — keep this class to single-URI
/// progressive HTTP.
final class HttpAudioSource extends CoreAudioSource {
  const HttpAudioSource({
    required this.url,
    required super.title,
    super.artist,
    super.artUri,
    super.estimatedDuration,
    this.headers,
  });

  final Uri url;
  final Map<String, String>? headers;

  @override
  List<Object?> get props => [
    url,
    title,
    artist,
    artUri,
    estimatedDuration,
    headers,
  ];

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    kCoreAudioSourceTypeKey: 'http',
    'url': url.toString(),
    'title': title,
    if (artist != null) 'artist': artist,
    if (artUri != null) 'artUri': artUri!.toString(),
    if (estimatedDuration != null)
      'estimatedMs': estimatedDuration!.inMilliseconds,
    // Coerce to a fresh map so callers cannot mutate our internal state
    // through the returned Map view.
    if (headers != null && headers!.isNotEmpty)
      'headers': Map<String, String>.from(headers!),
  };

  factory HttpAudioSource.fromJson(Map<String, Object?> json) {
    final url = json['url'];
    if (url is! String) {
      throw const SnapshotMalformedFailure('HttpAudioSource missing "url"');
    }
    final title = json['title'];
    if (title is! String) {
      throw const SnapshotMalformedFailure('HttpAudioSource missing "title"');
    }
    final artUriRaw = json['artUri'];
    final estimatedMs = json['estimatedMs'];
    final headersRaw = json['headers'];
    Map<String, String>? typedHeaders;
    if (headersRaw is Map) {
      typedHeaders = headersRaw.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    return HttpAudioSource(
      url: Uri.parse(url),
      title: title,
      artist: json['artist'] as String?,
      artUri: artUriRaw is String ? Uri.parse(artUriRaw) : null,
      estimatedDuration:
          estimatedMs is int ? Duration(milliseconds: estimatedMs) : null,
      headers: typedHeaders,
    );
  }
}

/// Local filesystem source. `path` is the absolute or relative filesystem
/// path the engine hands to its native open call.
///
/// The class deliberately does NOT depend on `dart:io` — the abstraction
/// stays import-safe from web builds; the engine layer is the one that
/// translates [path] into a `File` (or refuses, on web).
final class FileAudioSource extends CoreAudioSource {
  const FileAudioSource({
    required this.path,
    required super.title,
    super.artist,
    super.artUri,
    super.estimatedDuration,
  });

  final String path;

  @override
  List<Object?> get props => [path, title, artist, artUri, estimatedDuration];

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    kCoreAudioSourceTypeKey: 'file',
    'path': path,
    'title': title,
    if (artist != null) 'artist': artist,
    if (artUri != null) 'artUri': artUri!.toString(),
    if (estimatedDuration != null)
      'estimatedMs': estimatedDuration!.inMilliseconds,
  };

  factory FileAudioSource.fromJson(Map<String, Object?> json) {
    final path = json['path'];
    if (path is! String) {
      throw const SnapshotMalformedFailure('FileAudioSource missing "path"');
    }
    final title = json['title'];
    if (title is! String) {
      throw const SnapshotMalformedFailure('FileAudioSource missing "title"');
    }
    final artUriRaw = json['artUri'];
    final estimatedMs = json['estimatedMs'];
    return FileAudioSource(
      path: path,
      title: title,
      artist: json['artist'] as String?,
      artUri: artUriRaw is String ? Uri.parse(artUriRaw) : null,
      estimatedDuration:
          estimatedMs is int ? Duration(milliseconds: estimatedMs) : null,
    );
  }
}

/// HLS audio source. Plays an `.m3u8` manifest URL — libmpv handles
/// rolling-manifest refresh and gapless segment transitions natively, so the
/// wrapper doesn't need any segment-bookkeeping beyond what HTTP sources
/// already do.
///
/// Use this for live radio, podcasts published via HLS, and any source where
/// the upstream serves byte-range-friendly HLS over HTTP. Single-URI
/// progressive HTTP audio stays on [HttpAudioSource]; pure segment-append
/// scenarios (no upstream manifest) use [LiveAudioSource] below.
///
/// Kept as a peer of [HttpAudioSource] rather than a subclass: the sealed
/// dispatch is per-transport (manifest vs progressive) so callers can pattern
/// match exhaustively without runtime introspection.
final class HlsAudioSource extends CoreAudioSource {
  const HlsAudioSource({
    required this.manifestUrl,
    required super.title,
    super.artist,
    super.artUri,
    super.estimatedDuration,
    this.headers,
  });

  /// `.m3u8` manifest URL. libmpv detects the content-type and switches its
  /// demuxer to HLS without extra configuration.
  final Uri manifestUrl;

  /// Optional HTTP headers (auth, geo-bypass tokens, …) forwarded verbatim
  /// to libmpv's HTTP client when it fetches the manifest and its segments.
  final Map<String, String>? headers;

  @override
  List<Object?> get props => [
    manifestUrl,
    title,
    artist,
    artUri,
    estimatedDuration,
    headers,
  ];

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    kCoreAudioSourceTypeKey: 'hls',
    'manifestUrl': manifestUrl.toString(),
    'title': title,
    if (artist != null) 'artist': artist,
    if (artUri != null) 'artUri': artUri!.toString(),
    if (estimatedDuration != null)
      'estimatedMs': estimatedDuration!.inMilliseconds,
    // Coerce to a fresh map so callers cannot mutate our internal state
    // through the returned Map view (mirrors HttpAudioSource).
    if (headers != null && headers!.isNotEmpty)
      'headers': Map<String, String>.from(headers!),
  };

  factory HlsAudioSource.fromJson(Map<String, Object?> json) {
    final manifestUrl = json['manifestUrl'];
    if (manifestUrl is! String) {
      throw const SnapshotMalformedFailure(
        'HlsAudioSource missing "manifestUrl"',
      );
    }
    final title = json['title'];
    if (title is! String) {
      throw const SnapshotMalformedFailure('HlsAudioSource missing "title"');
    }
    final artUriRaw = json['artUri'];
    final estimatedMs = json['estimatedMs'];
    final headersRaw = json['headers'];
    Map<String, String>? typedHeaders;
    if (headersRaw is Map) {
      typedHeaders = headersRaw.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    return HlsAudioSource(
      manifestUrl: Uri.parse(manifestUrl),
      title: title,
      artist: json['artist'] as String?,
      artUri: artUriRaw is String ? Uri.parse(artUriRaw) : null,
      estimatedDuration:
          estimatedMs is int ? Duration(milliseconds: estimatedMs) : null,
      headers: typedHeaders,
    );
  }
}

/// Live audio source whose segments arrive over time via a stream of URLs.
/// The wrapper subscribes to [segmentUrlStream] and appends each emitted URL
/// to the active playlist as a sibling [HttpAudioSource]-like entry.
/// media_kit's native [Playlist] primitive provides gapless transitions
/// between successive segments.
///
/// Use case: streaming-while-generating UX where the upstream backend emits
/// one URL per finished segment (AI-generated music chunks, on-the-fly TTS
/// sections, anything where segments become ready asynchronously).
///
/// Contract:
/// - [segmentUrlStream] MUST be a single-subscription stream — the wrapper
///   subscribes exactly once. Use a backing [StreamController] + `addStream`
///   if you need to merge multiple producers.
/// - The stream MUST eventually close. The wrapper uses `done` to mark the
///   live source as exhausted, after which the normal `onQueueExhausted`
///   lifecycle takes over.
/// - The stream MAY emit before the source becomes the active queue entry
///   (segments pre-buffered ahead of play time).
/// - [headers] are attached to every emitted URL — per-segment headers are
///   out of scope for v1.
///
/// Serialization: [toJson] throws [UnsupportedError]. A live segment stream
/// is process-local state, not durable data; consumers persisting queues
/// must filter or recreate live entries from app state on restore.
final class LiveAudioSource extends CoreAudioSource {
  const LiveAudioSource({
    required this.segmentUrlStream,
    required super.title,
    super.artist,
    super.artUri,
    super.estimatedDuration,
    this.headers,
    this.initialUrl,
  });

  /// Stream of segment URLs to play in arrival order. Single-subscription;
  /// the wrapper subscribes once when the live source enters the queue.
  final Stream<Uri> segmentUrlStream;

  /// Headers attached to each segment's HTTP request. Common case: an auth
  /// bearer token for a backend that gates segment URLs.
  final Map<String, String>? headers;

  /// Optional priming URL: when non-null, the wrapper begins playback on
  /// this URL immediately (in parallel with subscribing to
  /// [segmentUrlStream]). Useful when the first segment is already known
  /// (e.g. a quick prelude file) and the stream starts emitting later
  /// segments after a delay.
  ///
  /// When null, the wrapper waits for the first emission from
  /// [segmentUrlStream] before issuing `player.open(...)`.
  final Uri? initialUrl;

  @override
  List<Object?> get props => [
    // Streams are uncomparable by value — fall back to identity so two
    // distinct LiveAudioSource instances pointing at the same controller
    // compare equal while two with different controllers do not.
    identityHashCode(segmentUrlStream),
    title,
    artist,
    artUri,
    estimatedDuration,
    headers,
    initialUrl,
  ];

  /// Live segments are process-local — serialising one would resurrect a
  /// stream that no longer has a producer. Callers that snapshot a queue
  /// containing a [LiveAudioSource] MUST either filter live entries before
  /// serialising or surface a clear failure to the user.
  @override
  Map<String, Object?> toJson() => throw UnsupportedError(
    'LiveAudioSource cannot be serialized. Live segment streams are '
    'process-local; recreate the source from your app state on restore.',
  );
}
