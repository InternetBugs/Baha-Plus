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
  http.Client? _client;
  Future<AppRelease?>? _pending;
  Completer<AppRelease?>? _result;
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
    final pending = result.future.whenComplete(() {
      _deadline?.cancel();
      _deadline = null;
      _pending = null;
      _result = null;
      checking = false;
      if (!_disposed) notifyListeners();
    });
    _result = result;
    _pending = pending;
    _deadline = Timer(timeout, () {
      _generation++;
      result.completeError(
        TimeoutException('Release check timed out', timeout),
      );
    });
    unawaited(
      _check(generation).then(
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

  Future<AppRelease?> _check(int generation) async {
    final version = currentVersion ?? await _versionLoader();
    if (_disposed || generation != _generation) return null;
    currentVersion = version;
    final installed = Version.parse(currentVersion!);
    notifyListeners();
    final client = _client ??= http.Client();
    final response = await client.get(
      latestReleaseUri,
      headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Baha-Plus/$currentVersion',
      },
    );
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
    final result = _result;
    if (result != null && !result.isCompleted) result.complete(null);
  }

  @override
  void dispose() {
    _disposed = true;
    cancelCheck();
    _client?.close();
    super.dispose();
  }
}
