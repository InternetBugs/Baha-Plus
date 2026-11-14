import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/playback_state.dart';

enum _Kind { playlist, segment, key, initialization }

typedef _Bytes = ({int start, int length});
typedef _Segment = ({
  PlaybackBufferRange time,
  _Resource media,
  List<_Resource> dependencies,
});

class _Resource {
  _Resource(this.id, this.uri, this.kind, this.bytes);

  final int id;
  final Uri uri;
  final _Kind kind;
  final _Bytes? bytes;
  final children = <_Resource>[];
  List<_Segment> segments = [];
  Uint8List? memory;
  File? file;
  int size = 0, requested = 0;
  Future<Uint8List>? pending;
  bool get cached => memory != null || file != null;
}

/// A session-only HLS cache for AVPlayer's otherwise disposable media buffer.
///
/// Only URLs registered from the authorized CDN's playlists can be requested.
/// Signed URLs and encryption keys stay in memory; complete encrypted media
/// segments use private temporary files. No background task or prefetch runs.
class NativeHlsCache {
  NativeHlsCache({
    required Map<String, String> headers,
    this.onChanged,
    this.maxBytes = 256 * 1024 * 1024,
    http.Client? client,
    Future<Directory> Function()? createDirectory,
  }) : _headers = Map.unmodifiable(headers),
       _client = client ?? http.Client(),
       _createDirectory = createDirectory ?? _temporaryDirectory;

  final Map<String, String> _headers;
  final http.Client _client;
  final Future<Directory> Function() _createDirectory;
  final void Function()? onChanged;
  final int maxBytes;
  final _resources = <String, _Resource>{};
  final _byId = <int, _Resource>{};
  final _lru = <_Resource>{};
  final _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  HttpServer? _server;
  Directory? _directory;
  Future<void>? _starting, _closing;
  bool _closed = false;
  int _diskBytes = 0, _requestSequence = 0;
  int downloadedBytes = 0;
  Future<void> _writes = Future.value();
  static Future<void>? _cleanup;

  static Future<Directory> _temporaryDirectory() async {
    final root = await getTemporaryDirectory();
    // A killed process cannot dispose its session. Sweep those private
    // directories once before this process creates its first cache.
    await (_cleanup ??= () async {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory ||
            !entity.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last
                .startsWith('baha-hls-')) {
          continue;
        }
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // OS cleanup can race with ours; cache cleanup never gates playback.
        }
      }
    }());
    return root.createTemp('baha-hls-');
  }

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (_closed) throw StateError('Media cache is closed');
    _directory = await _createDirectory();
    if (_closed) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await _server!.close(force: true);
      return;
    }
    _server!.listen((request) => unawaited(_serve(request)));
  }

  Uri playlist(Uri source) => _local(_register(source, _Kind.playlist));

  static void _validate(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'bahamut.akamaized.net' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443) ||
        uri.toString().length > 4096) {
      throw const FormatException('Invalid cached media origin');
    }
  }

  _Resource _register(Uri uri, _Kind kind, [_Bytes? bytes]) {
    _validate(uri);
    final key = '$kind|$uri|${bytes?.start}|${bytes?.length}';
    final existing = _resources[key];
    if (existing != null) return existing;
    if (_resources.length >= 20000) {
      throw const FormatException('Too many media resources');
    }
    final resource = _Resource(_resources.length, uri, kind, bytes);
    _resources[key] = resource;
    _byId[resource.id] = resource;
    return resource;
  }

  Uri _local(_Resource resource) {
    final server = _server;
    if (_closed || server == null) throw StateError('Media cache is not ready');
    final original = resource.uri.path.split('/').last;
    final suffix = RegExp(r'\.[a-zA-Z0-9]{1,6}$').firstMatch(original)?[0];
    final extension = resource.kind == _Kind.playlist
        ? '.m3u8'
        : suffix ?? '.bin';
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/$_token/${resource.id}$extension',
    );
  }

  /// Report only whole segments whose keys and initialization data are cached.
  /// The most recently requested variant represents AVPlayer's adaptive choice.
  List<PlaybackBufferRange> bufferedRanges(Uri source) {
    final root = _resources['${_Kind.playlist}|$source|null|null'];
    if (root == null) return const [];
    final visited = <_Resource>{};
    _Resource? selected;
    void visit(_Resource resource) {
      if (!visited.add(resource)) return;
      if (resource.segments.isNotEmpty &&
          (selected == null || resource.requested > selected!.requested)) {
        selected = resource;
      }
      for (final child in resource.children) {
        visit(child);
      }
    }

    visit(root);
    final ranges = <PlaybackBufferRange>[];
    for (final segment in selected?.segments ?? const <_Segment>[]) {
      if (!segment.media.cached ||
          segment.dependencies.any((resource) => !resource.cached)) {
        continue;
      }
      if (ranges.isNotEmpty && segment.time.start <= ranges.last.end + .001) {
        ranges[ranges.length - 1] = (
          start: ranges.last.start,
          end: segment.time.end,
        );
      } else {
        ranges.add(segment.time);
      }
    }
    return ranges;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.pathSegments;
      final id = path.length == 2
          ? int.tryParse(path.last.split('.').first)
          : null;
      final resource = _byId[id];
      if (_closed ||
          path.length != 2 ||
          path.first != _token ||
          request.uri.hasQuery ||
          resource == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (resource.kind == _Kind.playlist) {
        resource.requested = ++_requestSequence;
      }
      final data = await _read(resource);
      if (_closed) return;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentType = resource.kind == _Kind.playlist
            ? ContentType('application', 'vnd.apple.mpegurl')
            : resource.uri.path.endsWith('.ts')
            ? ContentType('video', 'mp2t')
            : resource.uri.path.endsWith('.mp4') ||
                  resource.uri.path.endsWith('.m4s')
            ? ContentType('video', 'mp4')
            : ContentType.binary;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0, end = data.length - 1;
      if (range != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        if (match == null ||
            (match[1]!.isEmpty && match[2]!.isEmpty) ||
            data.isEmpty) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('Content-Range', 'bytes */${data.length}');
          return;
        }
        if (match[1]!.isEmpty) {
          final length = int.tryParse(match[2]!);
          start = length == null ? data.length : max(0, data.length - length);
        } else {
          start = int.tryParse(match[1]!) ?? data.length;
          if (match[2]!.isNotEmpty) {
            end = min(int.tryParse(match[2]!) ?? -1, end);
          }
        }
        if (start >= data.length || end < start) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('Content-Range', 'bytes */${data.length}');
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          'Content-Range',
          'bytes $start-$end/${data.length}',
        );
      }
      response.contentLength = max(0, end - start + 1);
      if (request.method == 'GET' && data.isNotEmpty) {
        response.add(Uint8List.sublistView(data, start, end + 1));
      }
    } catch (_) {
      // Neither CDN URLs nor response bodies belong in server errors or logs.
      response.statusCode = HttpStatus.badGateway;
    } finally {
      try {
        await response.close();
      } catch (_) {
        // AVPlayer can cancel a request on seek, background or disposal.
      }
    }
  }

  Future<Uint8List> _read(_Resource resource) async {
    final memory = resource.memory;
    if (memory != null) return memory;
    final pending = resource.pending;
    if (pending != null) return pending;
    final work = _readOrDownload(resource);
    resource.pending = work;
    try {
      return await work;
    } finally {
      resource.pending = null;
    }
  }

  Future<Uint8List> _readOrDownload(_Resource resource) async {
    final file = resource.file;
    if (file != null) {
      try {
        final data = await file.readAsBytes();
        if (data.length == resource.size) {
          _lru.remove(resource);
          _lru.add(resource);
          return data;
        }
      } on FileSystemException {
        // iOS can purge temporary files under storage pressure.
      }
      _forget(resource);
    }
    final request = http.Request('GET', resource.uri)
      ..followRedirects = false
      ..headers.addAll(_headers);
    final bytes = resource.bytes;
    if (bytes != null) {
      request.headers[HttpHeaders.rangeHeader] =
          'bytes=${bytes.start}-${bytes.start + bytes.length - 1}';
    }
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    final limit = switch (resource.kind) {
      _Kind.playlist => 1024 * 1024,
      _Kind.key => 64 * 1024,
      _ => 64 * 1024 * 1024,
    };
    final contentRange = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(response.headers['content-range'] ?? '');
    if (response.statusCode != (bytes == null ? 200 : 206) ||
        (response.contentLength ?? 0) > limit ||
        (bytes != null &&
            (contentRange == null ||
                int.tryParse(contentRange[1]!) != bytes.start ||
                int.tryParse(contentRange[2]!) !=
                    bytes.start + bytes.length - 1 ||
                (int.tryParse(contentRange[3]!) ?? 0) <
                    bytes.start + bytes.length))) {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('Invalid media response');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (_closed || builder.length + chunk.length > limit) {
        throw const FormatException('Media response exceeds limit');
      }
      downloadedBytes += chunk.length;
      builder.add(chunk);
    }
    var data = builder.takeBytes();
    if (_closed ||
        data.isEmpty ||
        (response.contentLength != null &&
            response.contentLength != data.length) ||
        (bytes != null && data.length != bytes.length)) {
      throw const FormatException('Incomplete media response');
    }
    if (resource.kind == _Kind.playlist) {
      data = Uint8List.fromList(
        utf8.encode(_rewrite(resource, utf8.decode(data))),
      );
      resource.memory = data;
    } else if (resource.kind == _Kind.key) {
      resource.memory = data;
    } else if (data.length <= maxBytes) {
      final write = _writes.then((_) async {
        if (_closed) return;
        while (_diskBytes + data.length > maxBytes && _lru.isNotEmpty) {
          final oldest = _lru.first;
          final oldFile = oldest.file;
          _forget(oldest);
          try {
            await oldFile?.delete();
          } on FileSystemException {
            // A purged file has already released its disk space.
          }
        }
        final target = File('${_directory!.path}/${resource.id}.media');
        try {
          await target.writeAsBytes(data, flush: true);
        } on FileSystemException {
          // Storage pressure must not prevent using the downloaded segment.
          return;
        }
        if (_closed) return;
        resource
          ..file = target
          ..size = data.length;
        _diskBytes += data.length;
        _lru.add(resource);
      });
      _writes = write;
      await write;
    }
    onChanged?.call();
    return data;
  }

  void _forget(_Resource resource) {
    _diskBytes -= resource.size;
    resource
      ..file = null
      ..size = 0;
    _lru.remove(resource);
    onChanged?.call();
  }

  String _rewrite(_Resource playlist, String body) {
    if (!body.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('Invalid HLS playlist');
    }
    final lines = const LineSplitter().convert(body);
    // Cache only immutable, complete VOD playlists. Live playlists must be
    // refreshed and cannot safely reuse this session's static time mapping.
    if (lines.any((line) => line.startsWith('#EXTINF:')) &&
        !lines.any((line) => line.trim() == '#EXT-X-ENDLIST')) {
      throw const FormatException('Expected complete media playlist');
    }
    final output = <String>[];
    final segments = <_Segment>[];
    _Resource? key, initialization;
    String? range;
    Uri? previousRangeUri;
    var previousRangeEnd = 0;
    var time = 0.0;
    double? duration;
    var variant = false;
    for (final raw in lines) {
      var line = raw.trim();
      if (line.startsWith('#EXTINF:')) {
        duration = double.tryParse(line.substring(8).split(',').first);
        if (duration == null ||
            !duration.isFinite ||
            duration <= 0 ||
            time + duration > 172800) {
          throw const FormatException('Invalid HLS duration');
        }
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        range = line.substring(17);
        continue;
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        variant = true;
      }
      if (line.startsWith('#') && line.contains('URI="')) {
        final isKey =
            line.startsWith('#EXT-X-KEY:') ||
            line.startsWith('#EXT-X-SESSION-KEY:');
        final isMap = line.startsWith('#EXT-X-MAP:');
        final mapRange = isMap
            ? RegExp(r'BYTERANGE="([^"]+)"').firstMatch(line)?.group(1)
            : null;
        _Resource? dependency;
        line = line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
          final uri = playlist.uri.resolve(match[1]!);
          final resource = _register(
            uri,
            isKey
                ? _Kind.key
                : isMap
                ? _Kind.initialization
                : _Kind.playlist,
            mapRange == null ? null : _byteRange(mapRange, 0),
          );
          dependency = resource;
          if (resource.kind == _Kind.playlist) {
            playlist.children.add(resource);
          }
          return 'URI="${_local(resource)}"';
        });
        if (isKey) key = dependency;
        if (isMap) {
          initialization = dependency;
          line = line
              .replaceAll(RegExp(r'BYTERANGE="[^"]+",?'), '')
              .replaceFirst(RegExp(r',$'), '');
        }
      } else if (line.startsWith('#EXT-X-KEY:') &&
          line.contains('METHOD=NONE')) {
        key = null;
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final uri = playlist.uri.resolve(line);
        if (variant) {
          final child = _register(uri, _Kind.playlist);
          playlist.children.add(child);
          line = _local(child).toString();
          variant = false;
        } else {
          if (duration == null) {
            throw const FormatException('Missing HLS segment duration');
          }
          final bytes = range == null
              ? null
              : _byteRange(
                  range,
                  previousRangeUri == uri ? previousRangeEnd : null,
                );
          final media = _register(uri, _Kind.segment, bytes);
          segments.add((
            time: (start: time, end: time + duration),
            media: media,
            dependencies: [?key, ?initialization],
          ));
          time += duration;
          duration = null;
          range = null;
          previousRangeUri = bytes == null ? null : uri;
          previousRangeEnd = bytes == null ? 0 : bytes.start + bytes.length;
          line = _local(media).toString();
        }
      }
      output.add(line);
    }
    playlist.segments = segments;
    return '${output.join('\n')}\n';
  }

  static _Bytes _byteRange(String value, int? implicitStart) {
    final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(value);
    final length = match == null ? null : int.tryParse(match[1]!);
    final start = match?[2] == null ? implicitStart : int.tryParse(match![2]!);
    if (length == null ||
        length <= 0 ||
        length > 64 * 1024 * 1024 ||
        start == null ||
        start < 0) {
      throw const FormatException('Invalid HLS byte range');
    }
    return (start: start, length: length);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _client.close();
    try {
      await _starting;
    } catch (_) {
      // A failed start can still leave a temporary directory to release.
    }
    await _server?.close(force: true);
    final pending = _resources.values
        .map((resource) => resource.pending)
        .whereType<Future<Uint8List>>()
        .toList();
    await Future.wait(
      pending.map((work) async {
        try {
          await work;
        } catch (_) {
          // Closing cancels unfinished transfers without caching partial data.
        }
      }),
    );
    _resources.clear();
    _byId.clear();
    _lru.clear();
    final directory = _directory;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Temporary session data can already have been purged by the OS.
      }
    }
  }
}
