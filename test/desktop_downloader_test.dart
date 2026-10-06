import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Storage that throws when retrieving resume data for [failingTaskId]
class ThrowingStorage extends LocalStorePersistentStorage {
  static const failingTaskId = 'storage_failure';

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async {
    if (taskId == failingTaskId) {
      throw StateError('Storage failure');
    }
    return null;
  }

  @override
  Future<void> removeResumeData(String? taskId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test(
    'desktop task that throws before running fails, and frees its slot',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        FileDownloader(persistentStorage: ThrowingStorage());
        await FileDownloader().configure(
          globalConfig: (Config.holdingQueue, (1, null, null)),
        );
        final failingTask = DownloadTask(
          taskId: ThrowingStorage.failingTaskId,
          url: 'https://example.com/file.bin',
        );
        final result = await FileDownloader()
            .download(failingTask)
            .timeout(const Duration(seconds: 5));
        expect(result.status, equals(TaskStatus.failed));
        expect(result.exception?.description, contains('Storage failure'));
        // with maxConcurrent 1, a next task can only reach a final state if
        // the failing task released its slot
        final nextTask = DownloadTask(url: 'https://example.com/file2.bin');
        final nextResult = await FileDownloader()
            .download(nextTask)
            .timeout(const Duration(seconds: 5));
        expect(nextResult.status.isFinalState, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
