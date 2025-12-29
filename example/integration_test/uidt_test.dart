import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

import 'test_utils.dart';

void main() {
  setUp(uidtSetup);
  tearDown(uidtTearDown);

  group('UIDT Download Tests', () {
    testWidgets('Download with pause and resume', (tester) async {
      var task = DownloadTask(
          url: urlWithLongContentLength,
          filename: 'uidt_pause_test.bin',
          updates: Updates.statusAndProgress,
          allowPause: true);

      Completer<void> runningCompleter = Completer();
      Completer<void> pausedCompleter = Completer();
      Completer<void> completeCompleter = Completer();
      Completer<void> progressCompleter = Completer();

      listenToTask(task,
          statusCompleters: {
            TaskStatus.running: runningCompleter,
            TaskStatus.paused: pausedCompleter,
            TaskStatus.complete: completeCompleter,
          },
          progressCompleter: progressCompleter,
          progressThreshold: 0.05);

      print('Enqueuing task ${task.taskId}');
      expect(await FileDownloader().enqueue(task), isTrue);

      await runningCompleter.future;
      await progressCompleter.future; // Wait for some progress

      print('Pausing task');
      expect(await FileDownloader().pause(task), isTrue);
      await pausedCompleter.future;

      print('Resuming task');
      expect(await FileDownloader().resume(task), isTrue);
      await completeCompleter.future;

      expect(File(await task.filePath()).existsSync(), isTrue);
      await File(await task.filePath()).delete();
    });

    testWidgets('Download with cancel', (tester) async {
      var task = DownloadTask(
          url: urlWithLongContentLength,
          filename: 'uidt_cancel_test.bin',
          updates: Updates.statusAndProgress,
          allowPause: true);

      Completer<void> runningCompleter = Completer();
      Completer<void> canceledCompleter = Completer();
      Completer<void> progressCompleter = Completer();

      listenToTask(task,
          statusCompleters: {
            TaskStatus.running: runningCompleter,
            TaskStatus.canceled: canceledCompleter,
          },
          progressCompleter: progressCompleter,
          progressThreshold: 0.01);

      expect(await FileDownloader().enqueue(task), isTrue);
      await runningCompleter.future;
      await progressCompleter.future;

      expect(await FileDownloader().cancelTaskWithId(task.taskId), isTrue);
      await canceledCompleter.future;

      expect(File(await task.filePath()).existsSync(), isFalse);
    });

    testWidgets('Download with retries', (tester) async {
      // Using urlWithFailure to test retries
      var task = DownloadTask(
          url: urlWithFailure,
          filename: 'uidt_retry_test.bin',
          updates: Updates.statusAndProgress,
          retries: 2);

      Completer<void> waitingToRetryCompleter = Completer();
      Completer<void> failedCompleter = Completer();

      listenToTask(task, statusCompleters: {
        TaskStatus.waitingToRetry: waitingToRetryCompleter,
        TaskStatus.failed: failedCompleter
      });

      expect(await FileDownloader().enqueue(task), isTrue);

      // It might take time to fail and retry
      await waitingToRetryCompleter.future.timeout(const Duration(seconds: 30));
      await failedCompleter.future.timeout(const Duration(minutes: 1));
    });
  });

  group('UIDT Upload Tests', () {
    testWidgets('Regular Upload', (tester) async {
      var task = UploadTask(
          url: uploadTestUrl,
          filename: uploadFilename,
          updates: Updates.statusAndProgress,
          group: 'uploadTest');

      Completer<void> completeCompleter = Completer();

      listenToTask(task,
          statusCompleters: {TaskStatus.complete: completeCompleter});

      expect(await FileDownloader().enqueue(task), isTrue);
      await completeCompleter.future;
    });

    testWidgets('Upload with cancel', (tester) async {
      // Create a 25MB file to ensure we have time to cancel
      final docDir = await getApplicationDocumentsDirectory();
      final bigFile = File(join(docDir.path, 'big_upload_file.bin'));
      await bigFile.writeAsBytes(Uint8List(25 * 1024 * 1024));

      var task = UploadTask(
          url: uploadTestUrl,
          filename: 'big_upload_file.bin',
          updates: Updates.statusAndProgress,
          group: 'uploadTest');

      Completer<void> runningCompleter = Completer();
      Completer<void> canceledCompleter = Completer();
      Completer<void> progressCompleter = Completer();

      listenToTask(task,
          statusCompleters: {
            TaskStatus.running: runningCompleter,
            TaskStatus.canceled: canceledCompleter
          },
          progressCompleter: progressCompleter,
          progressThreshold: 0.01);

      expect(await FileDownloader().enqueue(task), isTrue);

      await runningCompleter.future;
      await progressCompleter.future; // Ensure we made some progress

      expect(await FileDownloader().cancelTasksWithIds([task.taskId]), isTrue);
      await canceledCompleter.future;
      await bigFile.delete();
    });
  });

  group('UIDT Parallel Download Tests', () {
    testWidgets('Regular parallel download', (tester) async {
      var task = ParallelDownloadTask(
          url: urlWithLongContentLength,
          filename: 'parallel_regular.bin',
          chunks: 3,
          updates: Updates.statusAndProgress);

      Completer<void> completeCompleter = Completer();

      listenToTask(task,
          statusCompleters: {TaskStatus.complete: completeCompleter});

      expect(await FileDownloader().enqueue(task), isTrue);
      await completeCompleter.future;

      expect(File(await task.filePath()).existsSync(), isTrue);
      await File(await task.filePath()).delete();
    });

    testWidgets('Parallel download with pause and resume', (tester) async {
      var task = ParallelDownloadTask(
          url: urlWithLongContentLength,
          filename: 'parallel_pause.bin',
          chunks: 3,
          updates: Updates.statusAndProgress,
          allowPause: true);

      Completer<void> runningCompleter = Completer();
      Completer<void> pausedCompleter = Completer();
      Completer<void> completeCompleter = Completer();
      Completer<void> progressCompleter = Completer();

      listenToTask(task,
          statusCompleters: {
            TaskStatus.running: runningCompleter,
            TaskStatus.paused: pausedCompleter,
            TaskStatus.complete: completeCompleter,
          },
          progressCompleter: progressCompleter,
          progressThreshold: 0.05);

      print('Enqueuing task ${task.taskId}');
      expect(await FileDownloader().enqueue(task), isTrue);

      await runningCompleter.future;
      await progressCompleter.future;

      print('Pausing task');
      expect(await FileDownloader().pause(task), isTrue);
      await pausedCompleter.future;
      print('Status is now paused, waiting a moment...');
      await Future.delayed(const Duration(seconds: 2));

      print('Resuming task');
      expect(await FileDownloader().resume(task), isTrue);
      await completeCompleter.future;

      expect(File(await task.filePath()).existsSync(), isTrue);
      await File(await task.filePath()).delete();
    });

    testWidgets('Parallel download with cancel', (tester) async {
      var task = ParallelDownloadTask(
          url: urlWithLongContentLength,
          filename: 'parallel_cancel.bin',
          chunks: 3,
          updates: Updates.statusAndProgress);

      Completer<void> runningCompleter = Completer();
      Completer<void> canceledCompleter = Completer();
      Completer<void> progressCompleter = Completer();

      listenToTask(task,
          statusCompleters: {
            TaskStatus.running: runningCompleter,
            TaskStatus.canceled: canceledCompleter,
          },
          progressCompleter: progressCompleter,
          progressThreshold: 0.01);

      expect(await FileDownloader().enqueue(task), isTrue);
      await runningCompleter.future;
      await progressCompleter.future;

      expect(await FileDownloader().cancelTasksWithIds([task.taskId]), isTrue);
      await canceledCompleter.future;

      expect(File(await task.filePath()).existsSync(), isFalse);
    });
  });

  group('UIDT DataTask Tests', () {
    testWidgets('DataTask execution', (tester) async {
      var task = DataTask(url: dataTaskGetUrl, updates: Updates.status);

      Completer<void> completeCompleter = Completer();
      String? responseBody;

      listenToTask(task,
          statusCompleters: {TaskStatus.complete: completeCompleter},
          callback: (update) {
        if (update is TaskStatusUpdate &&
            update.status == TaskStatus.complete) {
          responseBody = update.responseBody;
        }
      });

      expect(await FileDownloader().enqueue(task), isTrue);
      await completeCompleter.future;

      expect(responseBody, isNotNull);
    });
  });
}

/// Helper to listen to task updates and complete completers
void listenToTask(Task task,
    {Map<TaskStatus, Completer<void>>? statusCompleters,
    Completer<void>? progressCompleter,
    double progressThreshold = 0.0,
    Function(TaskUpdate)? callback}) {
  listenToTasks([task],
      statusCompleters:
          statusCompleters != null ? {task: statusCompleters} : null,
      progressCompleters:
          progressCompleter != null ? {task: progressCompleter} : null,
      progressThreshold: progressThreshold,
      callback: callback);
}

/// Helper to listen to multiple tasks in the same group
void listenToTasks(List<Task> tasks,
    {Map<Task, Map<TaskStatus, Completer<void>>>? statusCompleters,
    Map<Task, Completer<void>>? progressCompleters,
    double progressThreshold = 0.0,
    Function(TaskUpdate)? callback}) {
  final groups = tasks.map((e) => e.group).toSet();
  for (final group in groups) {
    FileDownloader().registerCallbacks(
        group: group,
        taskStatusCallback: (update) {
          final task = tasks.firstWhere((t) => t.taskId == update.task.taskId,
              orElse: () => update.task);
          if (tasks.any((t) => t.taskId == update.task.taskId)) {
            print('[${update.task.taskId}] Status: ${update.status}');
            final completer = statusCompleters?[task]?[update.status];
            if (completer != null && !completer.isCompleted) {
              completer.complete();
            }
            callback?.call(update);
          }
        },
        taskProgressCallback: (update) {
          final task = tasks.firstWhere((t) => t.taskId == update.task.taskId,
              orElse: () => update.task);
          if (tasks.any((t) => t.taskId == update.task.taskId)) {
            if (update.progress > progressThreshold) {
              final completer = progressCompleters?[task];
              if (completer != null && !completer.isCompleted) {
                completer.complete();
              }
            }
            callback?.call(update);
          }
        });
  }
}

Future<void> uidtSetup() async {
  await defaultSetup();
  await FileDownloader().reset(group: 'uploadTest');
  await FileDownloader()
      .configure(globalConfig: [(Config.runInForegroundIfFileLargerThan, 0)]);

  await FileDownloader().configureNotification(
      running: const TaskNotification('Running', 'Task is downloading'),
      complete: const TaskNotification('Complete', 'Task is finished'),
      progressBar: true);
}

Future<void> uidtTearDown() async {
  await defaultTearDown();
}
