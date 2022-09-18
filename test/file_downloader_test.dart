import 'package:flutter_test/flutter_test.dart';
import 'package:file_downloader/file_downloader.dart';
import 'package:file_downloader/file_downloader_platform_interface.dart';
import 'package:file_downloader/file_downloader_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFileDownloaderPlatform
    with MockPlatformInterfaceMixin
    implements FileDownloaderPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FileDownloaderPlatform initialPlatform = FileDownloaderPlatform.instance;

  test('$MethodChannelFileDownloader is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFileDownloader>());
  });

  test('getPlatformVersion', () async {
    FileDownloader fileDownloaderPlugin = FileDownloader();
    MockFileDownloaderPlatform fakePlatform = MockFileDownloaderPlatform();
    FileDownloaderPlatform.instance = fakePlatform;

    expect(await fileDownloaderPlugin.getPlatformVersion(), '42');
  });
}
