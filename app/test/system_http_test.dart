import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_proxy/platform_proxy.dart';
import 'package:platform_proxy/proxy.dart';
import 'package:baha_plus/data/system_http.dart';

class _DeviceProxy extends PlatformProxy {
  _DeviceProxy(this.port);
  final int? port;
  final requests = <String>[];

  @override
  Future<Iterable<Proxy>> getPlatformProxies({String? url}) async {
    requests.add(url!);
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
}
