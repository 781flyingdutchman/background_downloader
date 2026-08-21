import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('Config.tempFilePath', () {
    test('Config.tempFilePath desktop configuration', () async {
      const customPath = '/custom/temp/dir';
      var result = await FileDownloader().configure(
        globalConfig: (Config.tempFilePath, customPath),
      );
      expect(result.length, equals(1));
      expect(result.first.$1, equals(Config.tempFilePath));
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.tempFilePath, equals(customPath));

      // Reset using Config.never
      result = await FileDownloader().configure(
        globalConfig: (Config.tempFilePath, Config.never),
      );
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.tempFilePath, isNull);

      // Reset using false
      await FileDownloader().configure(
        globalConfig: (Config.tempFilePath, customPath),
      );
      result = await FileDownloader().configure(
        globalConfig: (Config.tempFilePath, false),
      );
      expect(DesktopDownloader.tempFilePath, isNull);

      // Reset using empty string
      await FileDownloader().configure(
        globalConfig: (Config.tempFilePath, customPath),
      );
      result = await FileDownloader().configure(
        globalConfig: (Config.tempFilePath, ''),
      );
      expect(DesktopDownloader.tempFilePath, isNull);
    });

    test('Config.tempFilePath platform-specific configuration', () async {
      const desktopPath = '/desktop/temp/dir';
      final result = await FileDownloader().configure(
        desktopConfig: (Config.tempFilePath, desktopPath),
      );
      expect(result.first.$1, equals(Config.tempFilePath));
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.tempFilePath, equals(desktopPath));

      // Reset
      await FileDownloader().configure(
        desktopConfig: (Config.tempFilePath, Config.never),
      );
      expect(DesktopDownloader.tempFilePath, isNull);
    });

    test('Config.tempFilePath on iOS returns not implemented', () async {
      const customPath = '/ios/temp/dir';
      final result = await FileDownloader().configure(
        iOSConfig: (Config.tempFilePath, customPath),
      );
      expect(result.first.$1, equals(Config.tempFilePath));
      expect(result.first.$2, equals('not implemented'));
    }, skip: !Platform.isIOS);
  });

  group('Config.mTLS', () {
    test('Config.mTLS desktop configuration', () async {
      const config = MTLSConfig(
        host: 'api.example.com',
        certificatePath: '/path/to/cert.pem',
        privateKeyPath: '/path/to/key.pem',
      );
      var result = await FileDownloader().configure(
        globalConfig: (Config.mTLS, config),
      );
      expect(result.length, equals(1));
      expect(result.first.$1, equals(Config.mTLS));
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.mtlsConfigs.length, equals(1));
      expect(DesktopDownloader.mtlsConfigs.first, equals(config));

      // Reset using false
      result = await FileDownloader().configure(
        globalConfig: (Config.mTLS, false),
      );
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.mtlsConfigs, isEmpty);

      // Reset using null
      await FileDownloader().configure(globalConfig: (Config.mTLS, config));
      result = await FileDownloader().configure(
        globalConfig: (Config.mTLS, null),
      );
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.mtlsConfigs, isEmpty);
    });

    test('Config.mTLS platform-specific configuration', () async {
      const config = MTLSConfig(
        certificateBytes: [1, 2, 3],
        privateKeyBytes: [4, 5, 6],
      );
      final result = await FileDownloader().configure(
        desktopConfig: (Config.mTLS, config),
      );
      expect(result.first.$1, equals(Config.mTLS));
      expect(result.first.$2, equals(''));
      expect(DesktopDownloader.mtlsConfigs.length, equals(1));

      // Reset
      await FileDownloader().configure(desktopConfig: (Config.mTLS, false));
      expect(DesktopDownloader.mtlsConfigs, isEmpty);
    });

    test('Config.mTLS on iOS returns not implemented', () async {
      const config = MTLSConfig(
        certificateBytes: [1, 2, 3],
        privateKeyBytes: [4, 5, 6],
      );
      final result = await FileDownloader().configure(
        iOSConfig: (Config.mTLS, config),
      );
      expect(result.first.$1, equals(Config.mTLS));
      expect(result.first.$2, equals('not implemented'));
    }, skip: !Platform.isIOS);
  });
}
