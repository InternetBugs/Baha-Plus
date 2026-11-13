import 'package:baha_plus/data/native_danmaku_sender.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native cookie access and mocked send require no WebView or account',
    (tester) async {
      await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
      final manager = CookieManager.instance();
      final url = WebUri('https://ani.gamer.com.tw/ajax/danmuSet.php');
      const name = 'baha_plus_native_sender_probe';
      final requests = <http.Request>[];
      final sender = NativeDanmakuSender(
        client: MockClient((request) async {
          requests.add(request);
          expect(request.url.origin, 'https://ani.gamer.com.tw');
          expect(
            request.headers['cookie']
                ?.split('; ')
                .contains('$name=offline-probe'),
            isTrue,
            reason:
                'The native test cookie must be available without a WebView',
          );
          return http.Response(switch (request.url.path) {
            '/mygather.php' =>
              '<a class="user-info"><span class="user-id">offline-probe</span></a>',
            '/ajax/getCSRFToken.php' => 'offline-csrf',
            '/ajax/danmuSet.php' => '{"sn":91}',
            _ => throw StateError('Unexpected mocked endpoint'),
          }, 200);
        }),
      );
      try {
        expect(
          await manager.setCookie(
            url: url,
            name: name,
            value: 'offline-probe',
            path: '/',
            isSecure: true,
            isHttpOnly: true,
          ),
          isTrue,
        );
        final item = await sender.send(
          videoId: '40190',
          owner: 'offline-probe',
          text: 'offline only',
          color: '#FFFFFF',
          position: 0,
          size: 1,
          checkCurrent: () {},
          currentPosition: () => 37.89,
        );
        expect(item.id, '91');
        expect(item.time, 37.8);
        expect(requests.length, 3);
        expect(
          requests
              .where((request) => request.method == 'POST')
              .single
              .bodyFields['time'],
          '378',
        );
        expect(find.byType(InAppWebView, skipOffstage: false), findsNothing);
        binding.reportData = {
          'nativeCookiePlugin': true,
          'httpOnlyProbeRead': true,
          'httpRequestsMocked': requests.length,
          'realNetworkRequests': 0,
          'realPublications': 0,
          'noWebView': true,
        };
      } finally {
        sender.dispose();
        await manager.deleteCookie(url: url, name: name, path: '/');
      }
    },
  );
}
