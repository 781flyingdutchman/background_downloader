import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_downloader/file_downloader_method_channel.dart';

void main() {
  MethodChannelFileDownloader platform = MethodChannelFileDownloader();
  const MethodChannel channel = MethodChannel('file_downloader');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      return '42';
    });
  });

  tearDown(() {
    channel.setMockMethodCallHandler(null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
