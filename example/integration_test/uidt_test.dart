import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

import 'test_utils.dart';

void main() {
  setUp(defaultSetup);

  tearDown(defaultTearDown);

  testWidgets('UIDT flow (foreground execution) test', (tester) async {
    // 1. Configure for always foreground (Config.always is 0)
    // This combined with notification config and API >= 34 should trigger UIDT via JobScheduler
    var configResult = await FileDownloader()
        .configure(globalConfig: [(Config.runInForegroundIfFileLargerThan, 0)]);

    // Verify config was set (on Android/iOS where implemented)
    if (Platform.isAndroid) {
      expect(configResult.first.$2, equals(''));
    }

    // 2. Configure notification (essential for UIDT)
    await FileDownloader().configureNotification(
        running: const TaskNotification('Running', 'Video is downloading'),
        complete: const TaskNotification('Complete', 'Video download finished'),
        progressBar: true);

    // 3. Define task
    // Using a URL known to work from test_utils (if available) or raw string
    // Reuse urlWithContentLength if possible, but I don't have direct access to test_utils constants via import unless I check test_utils content.
    // I'll use a hardcoded safe URL from typical tests or test_utils.dart if I viewed it.
    // I viewed general_test, it uses 'urlWithContentLength'.
    // I'll assume 'test_utils.dart' has it.

    final task = DownloadTask(
      url: urlWithContentLength,
      filename: 'uidt_test_file.bin',
      updates: Updates.statusAndProgress,
    );

    final path =
        join((await getApplicationDocumentsDirectory()).path, task.filename);
    // Clean up first
    try {
      File(path).deleteSync();
    } on FileSystemException {}

    // Register listener
    final completer = Completer<TaskStatus>();
    FileDownloader().registerCallbacks(taskStatusCallback: (update) {
      if (update.task == task && update.status.isFinalState) {
        if (!completer.isCompleted) {
          completer.complete(update.status);
        }
      }
    });

    print('Enqueuing UIDT task...');
    final enqueueSuccess = await FileDownloader().enqueue(task);
    expect(enqueueSuccess, isTrue);

    print('Waiting for task completion...');
    final status = await completer.future.timeout(const Duration(minutes: 2));
    print('Task finished with status: $status');

    expect(status, equals(TaskStatus.complete));
    expect(File(path).existsSync(), isTrue);

    // Cleanup
    await File(path).delete();
  });
}
