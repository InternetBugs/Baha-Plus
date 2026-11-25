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

class _HlsCachePool {
  _HlsCachePool(this.client);
  final http.Client client;
  int inFlight = 0;
  bool retired = false;
  bool closed = false;

  void closeIfUnused() {
    if (!closed && retired && inFlight == 0) {
      closed = true;
      client.close();
    }
  }
}

class _TransientMediaError implements Exception {
  const _TransientMediaError(this.reason, {this.isTimeout = false});
  final String reason;
  final bool isTimeout;
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
    this.onDiagnostic,
    this.maxBytes = 256 * 1024 * 1024,
    this.retryDelay = const Duration(milliseconds: 200),
    http.Client? client,
    http.Client Function()? clientFactory,
    Future<Directory> Function()? createDirectory,
  }) : _headers = Map.unmodifiable(headers),
       _ownsClient = client == null,
       _clientFactory = clientFactory ?? http.Client.new,
       _pool = _HlsCachePool(
         client ?? (clientFactory?.call() ?? http.Client()),
       ),
       _createDirectory = createDirectory ?? _temporaryDirectory {
    _pools.add(_pool);
  }

  final Map<String, String> _headers;
  final bool _ownsClient;
  final http.Client Function() _clientFactory;
  final Duration retryDelay;
  _HlsCachePool _pool;
  final _pools = <_HlsCachePool>{};
  final _waits = <Completer<void>>{};
  final Future<Directory> Function() _createDirectory;
  final void Function()? onChanged;

  /// Explains a refused resource to the diagnostic log. Only constant texts
  /// and playlist tags are reported: signed URLs, headers and keys never are.
  final void Function(String event, Map<String, Object?> data)? onDiagnostic;
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
  int _diskBytes = 0, _requestSequence = 0, _version = 0;
  int downloadedBytes = 0;
  int get version => _version;
  final _bufferedRangesCache = <Uri, List<PlaybackBufferRange>>{};
  Future<void> _writes = Future.value();
  static Future<void>? _cleanup;
  static final _extensionPattern = RegExp(r'\.[a-zA-Z0-9]{1,6}$');
  static final _rangeHeaderPattern = RegExp(r'^bytes=(\d*)-(\d*)$');
  static final _contentRangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');
  static final _byteRangeAttrPattern = RegExp(r'BYTERANGE="([^"]+)"');
  static final _uriAttrPattern = RegExp(r'URI="([^"]+)"');
  static final _stripByteRangeAttrPattern = RegExp(r'BYTERANGE="[^"]+",?');
  static final _trailingCommaPattern = RegExp(r',$');
  static final _byteRangeValuePattern = RegExp(r'^(\d+)(?:@(\d+))?$');

  void _invalidateBufferedRanges() {
    _version++;
    _bufferedRangesCache.clear();
  }

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
    final suffix = _extensionPattern.firstMatch(original)?[0];
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
    final cached = _bufferedRangesCache[source];
    if (cached != null) return cached;
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
    final result = List<PlaybackBufferRange>.unmodifiable(ranges);
    _bufferedRangesCache[source] = result;
    return result;
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
        _invalidateBufferedRanges();
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
        final match = _rangeHeaderPattern.firstMatch(range);
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
    } catch (error) {
      // Neither CDN URLs nor response bodies belong in server errors or logs.
      response.statusCode = HttpStatus.badGateway;
      onDiagnostic?.call('player.cache-reject', {
        'reason': error is FormatException
            ? error.message
            : error is _TransientMediaError
            ? error.reason
            : error.runtimeType.toString(),
      });
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

  void _rotateClient() {
    if (!_ownsClient || _closed) return;
    final previous = _pool;
    previous.retired = true;
    previous.closeIfUnused();
    if (previous.closed) _pools.remove(previous);
    _pool = _HlsCachePool(_clientFactory());
    _pools.add(_pool);
  }

  Future<void> _waitRetry(Duration delay) async {
    final wake = Completer<void>();
    _waits.add(wake);
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    try {
      await wake.future;
    } finally {
      timer.cancel();
      _waits.remove(wake);
    }
  }

  Future<Uint8List> _download(_Resource resource) async {
    for (var attempt = 0; ; attempt++) {
      if (_closed) throw const FormatException('Media cache is closed');
      try {
        return await _downloadOnce(
          resource,
          persistentConnection: attempt == 0,
        );
      } on _TransientMediaError catch (error) {
        final maxRetries = error.isTimeout ? 1 : 2;
        if (_closed || attempt >= maxRetries) rethrow;
        _rotateClient();
        final delay = retryDelay * (attempt == 0 ? 1 : 2);
        if (delay > Duration.zero) {
          await _waitRetry(delay);
        }
      }
    }
  }

  Future<Uint8List> _downloadOnce(
    _Resource resource, {
    required bool persistentConnection,
  }) async {
    final pool = _pool;
    pool.inFlight++;
    try {
      final request = http.Request('GET', resource.uri)
        ..followRedirects = false
        ..persistentConnection = persistentConnection
        ..headers.addAll(_headers);
      final bytes = resource.bytes;
      if (bytes != null) {
        request.headers[HttpHeaders.rangeHeader] =
            'bytes=${bytes.start}-${bytes.start + bytes.length - 1}';
      }
      final http.StreamedResponse response;
      try {
        response = await pool.client
            .send(request)
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw const _TransientMediaError(
          'Media response timed out',
          isTimeout: true,
        );
      } on SocketException {
        throw const _TransientMediaError('Media transport failed');
      } on HandshakeException {
        throw const _TransientMediaError('Media TLS failed');
      } on HttpException {
        throw const _TransientMediaError('Media HTTP failed');
      } on http.ClientException {
        throw const _TransientMediaError('Media client failed');
      }
      final limit = switch (resource.kind) {
        _Kind.playlist => 1024 * 1024,
        _Kind.key => 64 * 1024,
        _ => 64 * 1024 * 1024,
      };
      final expectedStatus = bytes == null ? 200 : 206;
      if (response.statusCode != expectedStatus) {
        await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
        if (response.statusCode == 429 ||
            (response.statusCode >= 500 && response.statusCode <= 599)) {
          throw const _TransientMediaError('Upstream media unavailable');
        }
        throw const FormatException('Invalid media response');
      }
      final contentRange = _contentRangePattern.firstMatch(
        response.headers['content-range'] ?? '',
      );
      if ((response.contentLength ?? 0) > limit ||
          (bytes != null &&
              (contentRange == null ||
                  int.tryParse(contentRange[1]!) != bytes.start ||
                  int.tryParse(contentRange[2]!) !=
                      bytes.start + bytes.length - 1 ||
                  (int.tryParse(contentRange[3]!) ?? 0) <
                      bytes.start + bytes.length))) {
        await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
        throw const FormatException('Invalid media response');
      }
      final builder = BytesBuilder(copy: false);
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 20),
        )) {
          if (_closed || builder.length + chunk.length > limit) {
            throw const FormatException('Media response exceeds limit');
          }
          downloadedBytes += chunk.length;
          builder.add(chunk);
        }
      } on TimeoutException {
        throw const _TransientMediaError(
          'Media stream timed out',
          isTimeout: true,
        );
      } on SocketException {
        throw const _TransientMediaError('Media stream failed');
      } on HttpException {
        throw const _TransientMediaError('Media stream HTTP failed');
      } on http.ClientException {
        throw const _TransientMediaError('Media stream client failed');
      }
      final data = builder.takeBytes();
      if (_closed) throw const FormatException('Media cache is closed');
      if (data.isEmpty ||
          (response.contentLength != null &&
              response.contentLength != data.length) ||
          (bytes != null && data.length != bytes.length)) {
        throw const _TransientMediaError('Incomplete media response');
      }
      return data;
    } finally {
      pool.inFlight--;
      if (_ownsClient) {
        pool.closeIfUnused();
        if (pool.closed) _pools.remove(pool);
      }
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
    var data = await _download(resource);
    if (resource.kind == _Kind.playlist) {
      final body = utf8.decode(data, allowMalformed: true);
      data = Uint8List.fromList(
        utf8.encode(_rewriteOrDescribe(resource, body)),
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
          await target.writeAsBytes(data);
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
    _invalidateBufferedRanges();
    onChanged?.call();
    return data;
  }

  void _forget(_Resource resource) {
    _diskBytes -= resource.size;
    resource
      ..file = null
      ..size = 0;
    _lru.remove(resource);
    _invalidateBufferedRanges();
    onChanged?.call();
  }

  String _rewriteOrDescribe(_Resource playlist, String body) {
    try {
      return _rewrite(playlist, body);
    } on FormatException {
      onDiagnostic?.call('player.cache-playlist', _shape(body));
      rethrow;
    }
  }

  /// Describes a refused playlist by its tags alone, which is what tells the
  /// encryption or playlist form a device was served apart.
  static Map<String, Object?> _shape(String body) {
    final methods = <String>{};
    final formats = <String>{};
    for (final line in const LineSplitter().convert(body)) {
      if (!line.startsWith('#EXT-X-KEY:') &&
          !line.startsWith('#EXT-X-SESSION-KEY:')) {
        continue;
      }
      final method = RegExp(r'METHOD=([A-Za-z0-9-]+)').firstMatch(line);
      final format = RegExp(r'KEYFORMAT="([^"]{1,48})"').firstMatch(line);
      if (method != null) methods.add(method[1]!);
      if (format != null) formats.add(format[1]!);
    }
    return {
      'version': RegExp(r'#EXT-X-VERSION:(\d+)').firstMatch(body)?[1] ?? '',
      'segments': RegExp(r'^#EXTINF:', multiLine: true).allMatches(body).length,
      'methods': methods.toList(),
      'keyFormats': formats.toList(),
      'map': body.contains('#EXT-X-MAP:'),
      'byterange': body.contains('#EXT-X-BYTERANGE:'),
      'endlist': body.contains('#EXT-X-ENDLIST'),
    };
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
            ? _byteRangeAttrPattern.firstMatch(line)?.group(1)
            : null;
        _Resource? dependency;
        line = line.replaceAllMapped(_uriAttrPattern, (match) {
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
              .replaceAll(_stripByteRangeAttrPattern, '')
              .replaceFirst(_trailingCommaPattern, '');
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
    final match = _byteRangeValuePattern.firstMatch(value);
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
    for (final wake in _waits.toList()) {
      if (!wake.isCompleted) wake.complete();
    }
    for (final pool in _pools.toList()) {
      if (!pool.closed) {
        pool.closed = true;
        pool.client.close();
      }
    }
    _pools.clear();
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
    _invalidateBufferedRanges();
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
