import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  late HttpServer server;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) {
      final count =
          int.tryParse(request.uri.queryParameters['count'] ?? '0') ?? 0;
      final hops =
          int.tryParse(request.uri.queryParameters['hops'] ?? '0') ?? 0;
      if (count > 0) {
        request.response.redirect(
          Uri.parse(
            'http://127.0.0.1:${server.port}/?count=${count - 1}&hops=${hops + 1}',
          ),
        );
      } else {
        request.response.headers.contentType = ContentType.text;
        request.response.write(
          "{'args': {'redirected': 'true', 'hops': '$hops'}}",
        );
        request.response.close();
      }
    });
  });

  tearDownAll(() async {
    await server.close();
  });

  group('Redirect limit', () {
    test('DesktopDownloader defaultMaxRedirects is 10', () {
      expect(DesktopDownloader.defaultMaxRedirects, equals(10));
      expect(defaultMaxRedirects, equals(10));
    });

    test(
      'DesktopDownloader.httpClient follows up to 10 redirects on get()',
      () async {
        final client = DesktopDownloader.httpClient;

        // 5 redirects (old default) succeeds
        final res5 = await client.get(
          Uri.parse('http://127.0.0.1:${server.port}/?count=5'),
        );
        expect(res5.statusCode, equals(200));
        expect(res5.body.contains("'hops': '5'"), isTrue);

        // 10 redirects (new default) succeeds
        final res10 = await client.get(
          Uri.parse('http://127.0.0.1:${server.port}/?count=10'),
        );
        expect(res10.statusCode, equals(200));
        expect(res10.body.contains("'hops': '10'"), isTrue);

        // 11 redirects fails
        expect(
          () => client.get(
            Uri.parse('http://127.0.0.1:${server.port}/?count=11'),
          ),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test(
      'DesktopDownloader.httpClient follows up to 10 redirects on send()',
      () async {
        final client = DesktopDownloader.httpClient;

        final req10 = http.Request(
          'GET',
          Uri.parse('http://127.0.0.1:${server.port}/?count=10'),
        );
        final streamedRes10 = await client.send(req10);
        final res10 = await http.Response.fromStream(streamedRes10);
        expect(res10.statusCode, equals(200));
        expect(res10.body.contains("'hops': '10'"), isTrue);

        final req11 = http.Request(
          'GET',
          Uri.parse('http://127.0.0.1:${server.port}/?count=11'),
        );
        expect(() => client.send(req11), throwsA(isA<http.ClientException>()));
      },
    );

    test('FileDownloader.request follows up to 10 redirects', () async {
      final request10 = Request(
        url: 'http://127.0.0.1:${server.port}/?count=10',
      );
      final response10 = await FileDownloader().request(request10);
      expect(response10.statusCode, equals(200));
      expect(response10.body.contains("'hops': '10'"), isTrue);

      final request11 = Request(
        url: 'http://127.0.0.1:${server.port}/?count=11',
        retries: 0,
      );
      final response11 = await FileDownloader().request(request11);
      // Because request failed with ClientException, retries exhausted and statusCode is 499 (not attempted)
      expect(response11.statusCode, equals(499));
    });
  });
}
