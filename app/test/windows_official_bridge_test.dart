import 'dart:async';
import 'dart:convert';

import 'package:baha_plus/core/browser_request.dart';
import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/data/windows_official_bridge.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class _BridgeController extends PlatformInAppWebViewController {
  _BridgeController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(
          id: 'windows-official-bridge',
        ),
      );

  final handlers = <String, JavaScriptHandlerCallback>{};
  final userScripts = <UserScript>[];
  final registrations = <String>[];
  WebUri? url = WebUri('https://ani.gamer.com.tw/search.php?keyword=test');
  Completer<WebUri?>? pendingUrl;
  int urlReads = 0;

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {
    registrations.add('handler');
    handlers[handlerName] = callback;
  }

  @override
  Future<void> addUserScript({required UserScript userScript}) async {
    registrations.add('script');
    userScripts.add(userScript);
  }

  @override
  Future<WebUri?> getUrl() async {
    urlReads++;
    return pendingUrl == null ? url : await pendingUrl!.future;
  }

  Future<dynamic> post(List<dynamic> arguments) async =>
      await handlers[windowsOfficialMessageHandler]!(arguments);
}

Future<_BridgeController> _attach(
  FutureOr<void> Function(String raw) receive,
) async {
  final platform = _BridgeController();
  await attachWindowsOfficialBridge(
    InAppWebViewController.fromPlatform(platform: platform),
    receive,
  );
  return platform;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'registers the Windows handler before an official document-start script without a listener factory',
    () async {
      final platform = await _attach((_) {});

      expect(platform.registrations, ['handler', 'script']);
      expect(platform.handlers.keys, [windowsOfficialMessageHandler]);
      expect(platform.userScripts, hasLength(1));
      final script = platform.userScripts.single;
      expect(script.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(script.forMainFrameOnly, isTrue);
      expect(script.allowedOriginRules, {'https://ani.gamer.com.tw'});
      expect(platform.urlReads, 0);
    },
  );

  test('rejects every argument shape except exactly one String', () async {
    final received = <String>[];
    final platform = await _attach(received.add);
    for (final arguments in <List<dynamic>>[
      [],
      [null],
      [true],
      [42],
      [
        {'type': 'account-guest'},
      ],
      [
        ['message'],
      ],
      ['message', 'extra'],
      ['message', null],
    ]) {
      expect(await platform.post(arguments), isNull);
      expect(received, isEmpty, reason: '$arguments');
    }
    expect(platform.urlReads, 0);
  });

  for (final length in [5000000, 5000001]) {
    test(
      'rejects a $length-character message before reading the URL',
      () async {
        final received = <String>[];
        final platform = await _attach(received.add);
        expect(await platform.post(['x' * length]), isNull);
        expect(received, isEmpty);
        expect(platform.urlReads, 0);
      },
    );
  }

  test('forwards the last allowed message length unchanged', () async {
    final received = <String>[];
    final platform = await _attach(received.add);
    final raw = 'x' * 4999999;
    expect(await platform.post([raw]), isNull);
    expect(received, hasLength(1));
    expect(received.single, same(raw));
    expect(platform.urlReads, 1);
  });

  for (final url in <String?>[
    null,
    '',
    '/search.php',
    'about:blank',
    'http://ani.gamer.com.tw/',
    'http://ani.gamer.com.tw:443/',
    'https://attacker.test/',
    'https://ani.gamer.com.tw.attacker.test/',
    'https://sub.ani.gamer.com.tw/',
    'https://user.gamer.com.tw/login.php',
    'https://ani.gamer.com.tw@attacker.test/',
    'https://user@ani.gamer.com.tw/',
    'https://fixture:fixture@ani.gamer.com.tw/',
    'https://ani.gamer.com.tw:80/',
    'https://ani.gamer.com.tw:444/',
    'https://ani.gamer.com.tw:8443/',
  ]) {
    test('rejects messages at native URL ${url ?? '<null>'}', () async {
      final received = <String>[];
      final platform = await _attach(received.add);
      platform.url = url == null ? null : WebUri(url);
      expect(
        await platform.post([
          '{"origin":"https://ani.gamer.com.tw","requestId":"current"}',
        ]),
        isNull,
      );
      expect(received, isEmpty);
      expect(platform.urlReads, 1);
    });
  }

  for (final url in [
    'https://ani.gamer.com.tw/',
    'https://ani.gamer.com.tw:443/search.php?keyword=test',
    'https://ani.gamer.com.tw/animeVideo.php?sn=20',
  ]) {
    test('forwards the original String at official native URL $url', () async {
      final received = <String>[];
      final platform = await _attach(received.add);
      platform.url = WebUri(url);
      const raw = ' \n{"requestId":"current","type":"account-guest"}\t ';
      expect(await platform.post([raw]), isNull);
      expect(received, [raw]);
      expect(platform.urlReads, 1);
    });
  }

  test(
    'preserves raw messages so the shared request verifies nonce, type, series and target',
    () async {
      final request = BrowserRequest(
        intent: BrowserIntent.favorite,
        animeId: '10',
        favoriteTarget: true,
      );
      final received = <String>[];
      final accepted = <Json>[];
      final platform = await _attach((raw) {
        received.add(raw);
        final body = request.accept(
          raw,
          origin: OfficialSite.home,
          source: OfficialSite.search('test'),
          isMainFrame: true,
        );
        if (body != null) accepted.add(body);
      });
      final body = {
        'requestId': request.id,
        'type': 'favorite-complete',
        'id': '10',
        'saved': true,
      };
      final messages = [
        ' \n${jsonEncode(body)}\t ',
        jsonEncode({...body, 'requestId': 'expired'}),
        jsonEncode({...body, 'type': 'account-synced'}),
        jsonEncode({...body, 'id': '11'}),
        jsonEncode({...body, 'saved': false}),
        '{"type":"favorite-complete","id":"10","saved":true}',
        'not JSON',
      ];
      for (final raw in messages) {
        expect(await platform.post([raw]), isNull);
      }

      expect(received, messages);
      expect(accepted, [body]);
      expect(platform.urlReads, messages.length);
    },
  );

  test(
    'the shared request still rejects oversized UTF-8 payloads below the helper character limit',
    () async {
      final request = BrowserRequest(intent: BrowserIntent.accountRefresh);
      final received = <String>[];
      final accepted = <Json>[];
      final platform = await _attach((raw) {
        received.add(raw);
        final body = request.accept(
          raw,
          origin: OfficialSite.home,
          source: OfficialSite.home,
          isMainFrame: true,
        );
        if (body != null) accepted.add(body);
      });
      final raw = jsonEncode({
        'requestId': request.id,
        'type': 'account-guest',
        'padding': '漢' * 1700000,
      });
      expect(raw.length, lessThan(5000000));
      expect(utf8.encode(raw).length, greaterThanOrEqualTo(5000000));
      await platform.post([raw]);
      expect(received, [raw]);
      expect(accepted, isEmpty);
    },
  );

  test(
    'checks the current native URL on each callback after navigation',
    () async {
      final received = <String>[];
      final platform = await _attach(received.add);
      const raw = '{"requestId":"current","type":"account-guest"}';
      await platform.post([raw]);
      expect(received, [raw]);

      platform.url = WebUri('https://attacker.test/');
      await platform.post([raw]);
      platform.url = null;
      await platform.post([raw]);
      expect(received, [raw]);

      platform.url = WebUri('https://ani.gamer.com.tw/');
      await platform.post([raw]);
      expect(received, [raw, raw]);
      expect(platform.urlReads, 4);
    },
  );

  test(
    'a pending native URL lookup rejects a changed foreign document',
    () async {
      final received = <String>[];
      final platform = await _attach(received.add);
      final lookup = platform.pendingUrl = Completer<WebUri?>();
      final delivery = platform.post([
        'message from the old official document',
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(platform.urlReads, 1);
      expect(received, isEmpty);

      lookup.complete(WebUri('https://attacker.test/'));
      expect(await delivery, isNull);
      expect(received, isEmpty);
    },
  );

  test('awaits the common receiver before finishing its callback', () async {
    final received = <String>[];
    final completion = Completer<void>();
    final platform = await _attach((raw) async {
      received.add(raw);
      await completion.future;
    });
    var finished = false;
    final delivery = platform.post(['message']).then((result) {
      finished = true;
      return result;
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, ['message']);
    expect(finished, isFalse);

    completion.complete();
    expect(await delivery, isNull);
    expect(finished, isTrue);
  });
}
