import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Level previousRootLevel;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '/tmp',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (MethodCall call) async => ['wifi'],
    );
  });

  setUp(() {
    previousRootLevel = Logger.root.level;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    Logger.root.level = previousRootLevel;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'FileDownloader.request preserves Logger.root.level and emits warnings',
    () async {
      // Bind and immediately close a loopback port to trigger a fast connection error
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final unusedPort = server.port;
      await server.close(force: true);

      Logger.root.level = Level.WARNING;
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      try {
        final response = await FileDownloader().request(
          Request(url: 'http://127.0.0.1:$unusedPort/test', retries: 0),
        );
        expect(response.statusCode, equals(499));
        expect(Logger.root.level, equals(Level.WARNING));
        expect(
          records.any(
            (r) =>
                r.loggerName == 'FileDownloader.request' &&
                r.level == Level.WARNING,
          ),
          isTrue,
        );

        // Verify SEVERE suppresses FileDownloader.request warnings and isn't reset
        records.clear();
        Logger.root.level = Level.SEVERE;
        final response2 = await FileDownloader().request(
          Request(url: 'http://127.0.0.1:$unusedPort/test', retries: 0),
        );
        expect(response2.statusCode, equals(499));
        expect(Logger.root.level, equals(Level.SEVERE));
        expect(
          records.where((r) => r.loggerName == 'FileDownloader.request'),
          isEmpty,
        );
      } finally {
        await sub.cancel();
      }
    },
  );
}
