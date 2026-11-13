import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, Rect;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

typedef DiagnosticShare = Future<void> Function(File file, Rect origin);

/// Opt-in, bounded diagnostics for release builds. Raw browser messages, HTTP
/// bodies, cookies, media URLs and exception messages must never be recorded.
class AppDiagnostics extends ChangeNotifier {
  AppDiagnostics({
    Future<Directory> Function()? directoryLoader,
    Future<Map<String, Object?>> Function()? metadataLoader,
    DiagnosticShare? shareFile,
  }) : _directoryLoader = directoryLoader ?? getApplicationSupportDirectory,
       _metadataLoader = metadataLoader ?? _metadata,
       _shareFile = shareFile ?? _share;

  static final instance = AppDiagnostics();
  static const maxFileBytes = 512 * 1024;
  static const maxEntryBytes = 16 * 1024;
  final Future<Directory> Function() _directoryLoader;
  final Future<Map<String, Object?>> Function() _metadataLoader;
  final DiagnosticShare _shareFile;
  Directory? _directory;
  Future<void>? _initializing;
  Future<void> _pending = Future.value();
  bool _enabled = false, _writeFailed = false, _hooksInstalled = false;
  bool _hasLogs = false;
  int _queuedEntries = 0, _droppedEntries = 0, _exportSequence = 0;
  int _currentBytes = 0;
  bool get enabled => _enabled;
  bool get hasLogs => _hasLogs;
  bool get writeFailed => _writeFailed;
  File get _current => File('${_directory!.path}/current.jsonl');
  File get _previous => File('${_directory!.path}/previous.jsonl');
  File get _flag => File('${_directory!.path}/enabled');

  Future<void> initialize() async {
    if (_directory != null) return;
    final pending = _initializing ??= _open();
    try {
      await pending;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _open() async {
    final root = await _directoryLoader();
    final directory = Directory('${root.path}/diagnostics');
    await directory.create(recursive: true);
    final flag = File('${directory.path}/enabled');
    final enabled = await flag.exists() && await flag.readAsString() == 'true';
    final current = File('${directory.path}/current.jsonl');
    _currentBytes = await current.exists() ? await current.length() : 0;
    _hasLogs =
        _currentBytes > 0 ||
        await File('${directory.path}/previous.jsonl').exists();
    _directory = directory;
    _enabled = enabled;
    if (enabled) record('capture.resumed');
    notifyListeners();
  }

  /// Uses the same isolate as the binding, avoiding a runApp zone mismatch.
  /// Preserve the host's error handling and do not mark failures as handled.
  void installErrorHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;
    final flutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      recordError('flutter.error', details.exception, details.stack);
      flutterHandler?.call(details);
    };
    final platformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      recordError('dart.error', error, stack);
      return platformHandler?.call(error, stack) ?? false;
    };
  }

  Future<void> start() async {
    await initialize();
    await _pending;
    // Retain earlier sessions until the user explicitly clears them. This also
    // preserves the tail of a session that ended with a process crash.
    await _flag.writeAsString('true', flush: true);
    _writeFailed = false;
    _enabled = true;
    record('capture.started');
    notifyListeners();
    await flush();
  }

  Future<void> stop() async {
    await initialize();
    record('capture.stopped');
    _enabled = false;
    notifyListeners();
    await _flag.writeAsString('false', flush: true);
    await flush();
  }

  void recordError(String event, Object error, [StackTrace? stack]) {
    record(event, {
      'type': error.runtimeType.toString(),
      if (error is PlatformException &&
          RegExp(r'^[\w.-]{1,64}$').hasMatch(error.code))
        'code': error.code,
      // Native exceptions frequently embed signed media URLs or headers in
      // their messages/details. Stack frames carry the useful code locations.
      if (stack != null)
        'stack': stack.toString().split('\n').take(24).toList(),
    });
  }

  void record(String event, [Map<String, Object?> data = const {}]) {
    if (!_enabled || _directory == null) return;
    if (_queuedEntries >= 128) {
      _droppedEntries++;
      return;
    }
    var line =
        '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': _cleanString(event), 'data': _clean(data)})}\n';
    if (utf8.encode(line).length > maxEntryBytes) {
      line =
          '${jsonEncode({
            'time': DateTime.now().toUtc().toIso8601String(),
            'event': _cleanString(event),
            'data': {'truncated': true},
          })}\n';
    }
    _queuedEntries++;
    if (!_hasLogs) {
      _hasLogs = true;
      notifyListeners();
    }
    _pending = _pending
        .then((_) async {
          final bytes = utf8.encode(line);
          if (_currentBytes + bytes.length > maxFileBytes) {
            if (await _previous.exists()) await _previous.delete();
            if (await _current.exists()) {
              await _current.rename(_previous.path);
            }
            _currentBytes = 0;
          }
          await _current.writeAsBytes(
            bytes,
            mode: FileMode.append,
            flush: true,
          );
          _currentBytes += bytes.length;
        })
        .catchError((Object _) {
          _writeFailed = true;
          notifyListeners();
        })
        .whenComplete(() => _queuedEntries--);
  }

  Future<void> flush() async {
    await _pending;
    if (_writeFailed) {
      throw const FileSystemException('Diagnostic write failed');
    }
  }

  Future<void> clear() async {
    await initialize();
    // Pause producers while deleting, then resume the user's current choice.
    final wasEnabled = _enabled;
    _enabled = false;
    try {
      await _pending;
      for (final file in [_current, _previous]) {
        if (await file.exists()) await file.delete();
      }
      final exports = Directory('${_directory!.path}/exports');
      if (await exports.exists()) await exports.delete(recursive: true);
      _currentBytes = _droppedEntries = 0;
      _hasLogs = false;
      _writeFailed = false;
    } finally {
      _enabled = wasEnabled;
      notifyListeners();
    }
    record('capture.cleared');
  }

  /// Keep a single immutable report for sharing. The journal remains private.
  Future<File> export({Map<String, Object?> context = const {}}) async {
    await initialize();
    record('capture.exported');
    final metadata = await _metadataLoader();
    final buffer = StringBuffer()
      ..writeln('Baha Plus diagnostic report (v1)')
      ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln(
        jsonEncode(
          _clean({
            ...metadata,
            'capturing': _enabled,
            'droppedEntries': _droppedEntries,
            ...context,
          }),
        ),
      )
      ..writeln('--- Events (UTC, oldest first) ---');
    // Serialize the snapshot with append/rotation, including events arriving
    // while native package metadata is being loaded.
    final snapshot = _pending.then((_) async {
      if (_writeFailed) {
        throw const FileSystemException('Diagnostic write failed');
      }
      for (final file in [_previous, _current]) {
        if (await file.exists()) {
          final input = await file.open();
          try {
            buffer.write(
              utf8.decode(await input.read(maxFileBytes), allowMalformed: true),
            );
          } finally {
            await input.close();
          }
        }
      }
    });
    _pending = snapshot.catchError((Object _) {});
    await snapshot;
    final exports = Directory('${_directory!.path}/exports');
    await exports.create(recursive: true);
    // Old reports may be referenced by a share extension. Retain a small,
    // bounded window rather than deleting the file immediately after sharing.
    final files = await exports
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files.take((files.length - 2).clamp(0, files.length))) {
      await file.delete();
    }
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final report = File(
      '${exports.path}/BahaPlus-logs-$stamp-${_exportSequence++}.txt',
    );
    await report.writeAsString(buffer.toString(), flush: true);
    return report;
  }

  Future<void> share(File file, Rect origin) => _shareFile(file, origin);

  static Future<void> _share(File file, Rect origin) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Baha Plus diagnostics',
        sharePositionOrigin: origin,
      ),
    );
  }

  static Future<Map<String, Object?>> _metadata() async {
    final info = await PackageInfo.fromPlatform();
    return {
      'appVersion': info.version,
      'buildNumber': info.buildNumber,
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
      'buildMode': kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug'),
    };
  }

  static final _privateKey = RegExp(
    r'cookie|authorization|password|token|secret|csrf|account|email|username|userid|^document$|url|uri|headers|^body$',
    caseSensitive: false,
  );
  static final _url = RegExp(
    r'''(?:https?|file|content)://[^\s"'<>]+''',
    caseSensitive: false,
  );
  static final _localPath = RegExp(r'\b[A-Za-z]:[\\/][^\s]+');
  static final _email = RegExp(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}');

  static String _cleanString(String value) {
    // Bound before applying expressions, even for unexpected browser input.
    final bounded = value.length > 2048
        ? '${value.substring(0, 2048)}…'
        : value;
    return bounded
        .replaceAll(_url, '[url removed]')
        .replaceAll(_localPath, '[path removed]')
        .replaceAll(_email, '[email removed]');
  }

  static Object? _clean(Object? value, [int depth = 0]) {
    if (value == null || value is bool || value is int) return value;
    if (value is double) return value.isFinite ? value : null;
    if (value is String) return _cleanString(value);
    if (depth >= 4) return '[truncated]';
    if (value is Map) {
      return {
        for (final entry in value.entries.take(48))
          _cleanString(
            entry.key.toString(),
          ): _privateKey.hasMatch(entry.key.toString())
              ? '[redacted]'
              : _clean(entry.value, depth + 1),
      };
    }
    if (value is Iterable) {
      return value.take(32).map((e) => _clean(e, depth + 1)).toList();
    }
    return value.runtimeType.toString();
  }
}
