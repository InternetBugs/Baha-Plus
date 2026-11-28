import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:url_launcher/url_launcher.dart';

class AppRelease {
  const AppRelease(this.version, {this.notes = ''});

  final Version version;
  final String notes;

  static final _atxHeading = RegExp(r'^\s*(#{1,6})\s+(.+?)\s*#*\s*$');
  static final _fenceLine = RegExp(r'^\s*(`{3,}|~{3,})');
  static final _headingDecoration = RegExp(r'^[*_\s]+|[*_\s:：]+$');

  static const _installHeadings = {
    '下载说明',
    '下載說明',
    '安装说明',
    '安裝說明',
    '下载与安装',
    '下載與安裝',
    '下载与安装说明',
    '下載與安裝說明',
    '下载和安装',
    '下載和安裝',
    '下载和安装说明',
    '下載和安裝說明',
    '安装与下载',
    '安裝與下載',
    '下载方式',
    '下載方式',
    '安装方式',
    '安裝方式',
    '安装包说明',
    '安裝包說明',
    'download',
    'downloads',
    'download instructions',
    'install',
    'installation',
    'install instructions',
  };

  static const _changelogHeadings = {
    '更新内容',
    '更新內容',
    '更新日志',
    '更新日誌',
    '更新说明',
    '更新說明',
    'changelog',
    'release notes',
    "what's changed",
  };

  /// Release notes formatted for the in-app update dialog: omits download and
  /// installation instruction sections plus the redundant outer changelog
  /// heading so only the actual update content is shown.
  String get changelog => extractChangelog(notes);

  static String extractChangelog(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.trim().isEmpty) return '';

    final kept = <String>[];
    String? fenceChar;
    var fenceLength = 0;
    int? skipLevel;

    for (final line in normalized.split('\n')) {
      final fence = _fenceLine.firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        if (fenceChar == null) {
          fenceChar = marker[0];
          fenceLength = marker.length;
        } else if (marker[0] == fenceChar && marker.length >= fenceLength) {
          fenceChar = null;
          fenceLength = 0;
        }
        if (skipLevel == null) kept.add(line);
        continue;
      }

      if (fenceChar != null) {
        if (skipLevel == null) kept.add(line);
        continue;
      }

      final heading = _atxHeading.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final title = heading
            .group(2)!
            .replaceAll(_headingDecoration, '')
            .toLowerCase();

        if (skipLevel != null && level <= skipLevel) {
          skipLevel = null;
        }

        if (skipLevel == null) {
          if (_installHeadings.contains(title)) {
            skipLevel = level;
            continue;
          }
          if (level <= 2 && _changelogHeadings.contains(title)) {
            continue;
          }
          kept.add(line);
        }
        continue;
      }

      if (skipLevel == null) {
        kept.add(line);
      }
    }

    var start = 0;
    while (start < kept.length && kept[start].trim().isEmpty) {
      start++;
    }
    var end = kept.length;
    while (end > start && kept[end - 1].trim().isEmpty) {
      end--;
    }
    if (start >= end) return '';

    final compact = <String>[];
    var consecutiveBlanks = 0;
    for (var i = start; i < end; i++) {
      final line = kept[i];
      if (line.trim().isEmpty) {
        consecutiveBlanks++;
        if (consecutiveBlanks <= 1) compact.add('');
      } else {
        consecutiveBlanks = 0;
        compact.add(line);
      }
    }
    return compact.join('\n').trim();
  }

  static AppRelease? fromJson(Map<String, dynamic> json) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'];
    if (tag is! String) throw const FormatException('Missing release version');
    final version = Version.parse(tag.startsWith('v') ? tag.substring(1) : tag);
    return version.isPreRelease
        ? null
        : AppRelease(version, notes: json['body'] as String? ?? '');
  }
}

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    http.Client? client,
    Future<String> Function()? versionLoader,
    Future<bool> Function(Uri)? openUrl,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client,
       _versionLoader = versionLoader ?? _installedVersion,
       _openUrl = openUrl ?? _openExternal;

  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/InternetBugs/Baha-Plus/releases/latest',
  );
  static final downloadsUri = Uri.https(
    'github.com',
    '/InternetBugs/Baha-Plus/releases',
  );

  static Future<String> _installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  static Future<bool> _openExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  final Future<String> Function() _versionLoader;
  final Future<bool> Function(Uri) _openUrl;
  final Duration timeout;
  final http.Client? _client;
  Future<AppRelease?>? _pending;
  Completer<AppRelease?>? _result;
  Completer<void>? _abort;
  Timer? _deadline;
  int _generation = 0;
  bool _startupChecked = false, _disposed = false;
  bool checking = false;
  String? currentVersion;

  Future<AppRelease?> check({bool automatic = false}) {
    if (_disposed) return Future.value();
    if (automatic) {
      if (_startupChecked) return Future.value();
      _startupChecked = true;
    }
    if (_pending case final pending?) return pending;
    checking = true;
    final generation = ++_generation;
    final result = Completer<AppRelease?>();
    final abort = Completer<void>();
    final pending = result.future.whenComplete(() {
      _deadline?.cancel();
      _deadline = null;
      _pending = null;
      _result = null;
      _abort = null;
      checking = false;
      if (!_disposed) notifyListeners();
    });
    _result = result;
    _abort = abort;
    _pending = pending;
    _deadline = Timer(timeout, () {
      _generation++;
      if (!abort.isCompleted) abort.complete();
      result.completeError(
        TimeoutException('Release check timed out', timeout),
      );
    });
    unawaited(
      _check(generation, abort.future).then(
        (release) {
          if (!result.isCompleted) result.complete(release);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    notifyListeners();
    return pending;
  }

  Future<AppRelease?> _check(int generation, Future<void> abort) async {
    final version = currentVersion ?? await _versionLoader();
    if (_disposed || generation != _generation) return null;
    currentVersion = version;
    final installed = Version.parse(currentVersion!);
    notifyListeners();
    final client = _client ?? http.Client();
    final request =
        http.AbortableRequest('GET', latestReleaseUri, abortTrigger: abort)
          ..headers.addAll({
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'Baha-Plus/$currentVersion',
          });
    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request));
    } finally {
      if (_client == null) client.close();
    }
    if (_disposed ||
        generation != _generation ||
        response.statusCode == HttpStatus.notFound) {
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Release check failed (${response.statusCode})');
    }
    final release = AppRelease.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
    if (release == null) return null;
    // Build metadata does not make an otherwise identical version newer.
    final current = Version(
      installed.major,
      installed.minor,
      installed.patch,
      pre: installed.preRelease.isEmpty ? null : installed.preRelease.join('.'),
    );
    final latest = Version(
      release.version.major,
      release.version.minor,
      release.version.patch,
    );
    return latest > current ? release : null;
  }

  Future<void> openDownloads() async {
    if (!await _openUrl(downloadsUri).timeout(timeout)) {
      throw StateError('Could not open release downloads');
    }
  }

  void cancelCheck() {
    _generation++;
    _deadline?.cancel();
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    final result = _result;
    if (result != null && !result.isCompleted) result.complete(null);
  }

  @override
  void dispose() {
    _disposed = true;
    cancelCheck();
    super.dispose();
  }
}
