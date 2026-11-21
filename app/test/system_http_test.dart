import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_proxy/platform_proxy.dart';
import 'package:platform_proxy/proxy.dart';
import 'package:baha_plus/data/system_http.dart';

class _DeviceProxy extends PlatformProxy {
  _DeviceProxy(this.port, {this.entries, this.error});
  int? port;
  Iterable<Proxy>? entries;
  Object? error;
  final requests = <String>[];

  @override
  Future<Iterable<Proxy>> getPlatformProxies({String? url}) async {
    requests.add(url!);
    if (error != null) throw error!;
    if (entries != null) return entries!;
    return [
      Proxy.fromJson(
        port == null
            ? {'type': 'none'}
            : {'host': '127.0.0.1', 'port': '$port', 'type': 'http'},
      ),
    ];
  }
}

void main() {
  test(
    'image HTTP requests follow the device proxy without DNS lookup',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = _DeviceProxy(server.port);
      final client = SystemHttpOverrides(
        platformProxy: proxy,
      ).createHttpClient(null);
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
      });
      final handled = server.first.then((request) async {
        expect(request.requestedUri.host, 'artwork.invalid');
        request.response.write('proxied artwork');
        await request.response.close();
      });
      final uri = Uri.parse('http://artwork.invalid/series.jpg');
      final response = await (await client.getUrl(uri)).close();
      expect(await utf8.decodeStream(response), 'proxied artwork');
      expect(proxy.requests, [uri.toString()]);
      await handled;
    },
  );

  test('devices without a proxy retain direct HTTP networking', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _DeviceProxy(null);
    final client = SystemHttpOverrides(
      platformProxy: proxy,
    ).createHttpClient(null);
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });
    final handled = server.first.then((request) async {
      request.response.write('direct artwork');
      await request.response.close();
    });
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/series.jpg'),
    )).close();
    expect(await utf8.decodeStream(response), 'direct artwork');
    expect(proxy.requests, hasLength(1));
    await handled;
  });

  test('proxy cache refreshes after TTL when device proxy changes', () async {
    final firstServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final secondServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var now = DateTime.utc(2026, 11, 22, 0, 0, 0);
    final proxy = _DeviceProxy(firstServer.port);
    final client = SystemProxyHttpClient(
      client: HttpClient(),
      platformProxy: proxy,
      proxyCacheTtl: const Duration(seconds: 3),
      now: () => now,
    );
    addTearDown(() async {
      client.close(force: true);
      await firstServer.close(force: true);
      await secondServer.close(force: true);
    });
    final firstHandled = firstServer.first.then((request) async {
      request.response.write('via-first');
      await request.response.close();
    });
    final secondHandled = secondServer.first.then((request) async {
      request.response.write('via-second');
      await request.response.close();
    });

    final uri = Uri.parse('http://artwork.invalid/series.jpg');
    final firstResponse = await (await client.getUrl(uri)).close();
    expect(await utf8.decodeStream(firstResponse), 'via-first');
    await firstHandled;

    proxy.port = secondServer.port;
    now = now.add(const Duration(seconds: 4));

    final secondResponse = await (await client.getUrl(uri)).close();
    expect(await utf8.decodeStream(secondResponse), 'via-second');
    expect(proxy.requests, hasLength(2));
    await secondHandled;
  });

  test('open failure evicts cached proxy so immediate retry re-resolves', () async {
    final deadServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = deadServer.port;
    await deadServer.close(force: true);

    final liveServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _DeviceProxy(deadPort);
    final client = SystemHttpOverrides(
      platformProxy: proxy,
      proxyCacheTtl: const Duration(minutes: 5),
    ).createHttpClient(null);
    addTearDown(() async {
      client.close(force: true);
      await liveServer.close(force: true);
    });
    final handled = liveServer.first.then((request) async {
      request.response.write('recovered');
      await request.response.close();
    });

    final uri = Uri.parse('http://artwork.invalid/retry.jpg');
    await expectLater(client.getUrl(uri), throwsA(isA<SocketException>()));

    proxy.port = liveServer.port;
    final response = await (await client.getUrl(uri)).close();
    expect(await utf8.decodeStream(response), 'recovered');
    expect(proxy.requests, hasLength(2));
    await handled;
  });

  test('malformed proxy entries and lookup errors fall back to direct', () async {
    expect(
      SystemProxyHttpClient.formatPac([
        Proxy.fromJson({'host': '', 'port': '', 'type': 'https'}),
        Proxy.fromJson({'host': '127.0.0.1', 'port': 'abc', 'type': 'http'}),
      ]),
      isEmpty,
    );
    expect(
      SystemProxyHttpClient.formatPac([
        Proxy.fromJson({'host': '::1', 'port': '7890', 'type': 'https'}),
        Proxy.fromJson({'host': '', 'port': '', 'type': 'none'}),
      ]),
      'PROXY [::1]:7890; DIRECT',
    );

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _DeviceProxy(
      null,
      error: const FormatException('Malformed plugin JSON'),
    );
    final client = SystemHttpOverrides(
      platformProxy: proxy,
    ).createHttpClient(null);
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });
    final handled = server.first.then((request) async {
      request.response.write('direct-fallback');
      await request.response.close();
    });
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/direct'),
    )).close();
    expect(await utf8.decodeStream(response), 'direct-fallback');
    await handled;
  });
}
