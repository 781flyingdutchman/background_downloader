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
}
