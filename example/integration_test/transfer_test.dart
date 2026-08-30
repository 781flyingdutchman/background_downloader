// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_utils.dart';

void main() {
  setUp(() async {
    await defaultSetup();
  });

  tearDown(() async {
    await defaultTearDown();
  });

  group('Transfer Basics & Lifecycle', () {
    testWidgets(
      'Download transfer execution, result future and file resolution',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final downloadTask = DownloadTask(
          url: urlWithContentLength,
          filename: 'transfer_download_test.bin',
          updates: Updates.statusAndProgress,
        );

        final transfer = await FileDownloader().transfers.start(downloadTask);
        expect(transfer.taskId, equals(downloadTask.taskId));
        expect(transfer.status, isNot(equals(TaskStatus.complete)));

        // Await the high-level result Future
        final result = await transfer.result;
        expect(result.status, equals(TaskStatus.complete));
        expect(transfer.status, equals(TaskStatus.complete));
        expect(transfer.progress, equals(1.0));

        // Await the downloaded file handle
        final file = await transfer.file;
        expect(file.existsSync(), isTrue);
        expect(file.lengthSync(), equals(urlWithContentLengthFileSize));

        await file.delete();
      },
    );

    testWidgets(
      'Upload transfer execution and responseBody resolution',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final uploadTaskToRun = UploadTask(
          url: uploadTestUrl,
          filename: uploadFilename,
          updates: Updates.statusAndProgress,
        );

        final transfer = await FileDownloader().transfers.start(uploadTaskToRun);
        final result = await transfer.result;

        expect(result.status, equals(TaskStatus.complete));
        expect(transfer.status, equals(TaskStatus.complete));

        final response = await transfer.responseBody;
        expect(response, isNotNull);
      },
    );

    testWidgets(
      'Binary upload transfer with TransferHint.binaryUpload',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final binUploadTask = UploadTask(
          url: uploadBinaryTestUrl,
          filename: uploadFilename,
          transferHints: {TransferHint.binaryUpload},
          updates: Updates.statusAndProgress,
        );

        expect(binUploadTask.post, equals('binary'));

        final transfer = await FileDownloader().transfers.start(binUploadTask);
        final result = await transfer.result;

        expect(result.status, equals(TaskStatus.complete));
        expect(transfer.status, equals(TaskStatus.complete));
      },
    );

    testWidgets(
      'DataTask transfer execution',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final dataTask = DataTask(
          url: dataTaskGetUrl,
          headers: dataTaskHeaders,
        );

        final transfer = await FileDownloader().transfers.start(dataTask);
        final result = await transfer.result;

        expect(result.status, equals(TaskStatus.complete));
        expect(transfer.status, equals(TaskStatus.complete));

        final response = await transfer.responseBody;
        expect(response, isNotNull);
      },
    );

    testWidgets(
      'Transfer error handling on failing endpoint',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final failTask = DownloadTask(
          url: urlWithFailure,
          filename: 'fail_transfer.bin',
          retries: 0,
        );

        final transfer = await FileDownloader().transfers.start(failTask);
        final result = await transfer.result;

        expect(
          result.status == TaskStatus.failed ||
              result.status == TaskStatus.notFound,
          isTrue,
        );
        expect(transfer.status.isFinalState, isTrue);

        // transfer.file should throw TaskException when failed
        expect(() async => await transfer.file, throwsA(isA<TaskException>()));
      },
    );
  });

  group('Transfer Controls: Pause, Resume, and Cancel', () {
    testWidgets(
      'Pause and resume live download transfer',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final pauseResumeTask = DownloadTask(
          url: urlWithLongContentLength,
          filename: 'transfer_pause_resume.bin',
          updates: Updates.statusAndProgress,
          allowPause: true,
        );

        final transfer = await FileDownloader().transfers.start(pauseResumeTask);

        // Wait for some progress
        final progressCompleter = Completer<void>();
        void progressListener() {
          if ((transfer.progress ?? 0.0) > 0.03 &&
              !progressCompleter.isCompleted) {
            progressCompleter.complete();
          }
        }

        transfer.progressNotifier.addListener(progressListener);
        if ((transfer.progress ?? 0.0) > 0.03 &&
            !progressCompleter.isCompleted) {
          progressCompleter.complete();
        }
        await progressCompleter.future;
        transfer.progressNotifier.removeListener(progressListener);

        // Pause the transfer
        print('Pausing transfer ${transfer.taskId}');
        final paused = await transfer.pause();
        expect(paused, isTrue);

        // Wait for paused status
        if (transfer.status != TaskStatus.paused) {
          final pauseCompleter = Completer<void>();
          void statusListener() {
            if (transfer.status == TaskStatus.paused &&
                !pauseCompleter.isCompleted) {
              pauseCompleter.complete();
            }
          }

          transfer.statusNotifier.addListener(statusListener);
          if (transfer.status == TaskStatus.paused &&
              !pauseCompleter.isCompleted) {
            pauseCompleter.complete();
          }
          await pauseCompleter.future.timeout(const Duration(seconds: 15));
          transfer.statusNotifier.removeListener(statusListener);
        }
        expect(transfer.status, equals(TaskStatus.paused));

        await Future.delayed(const Duration(seconds: 1));

        // Resume the transfer
        print('Resuming transfer ${transfer.taskId}');
        final resumed = await transfer.resume();
        expect(resumed, isTrue);

        final result = await transfer.result;
        expect(result.status, equals(TaskStatus.complete));

        final file = await transfer.file;
        expect(file.existsSync(), isTrue);
        await file.delete();
      },
    );

    testWidgets(
      'Cancel active download transfer',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final cancelTask = DownloadTask(
          url: urlWithLongContentLength,
          filename: 'transfer_cancel.bin',
          updates: Updates.statusAndProgress,
          allowPause: true,
        );

        final transfer = await FileDownloader().transfers.start(cancelTask);

        // Wait for initial progress
        final progressCompleter = Completer<void>();
        void progressListener() {
          if ((transfer.progress ?? 0.0) > 0.01 &&
              !progressCompleter.isCompleted) {
            progressCompleter.complete();
          }
        }

        transfer.progressNotifier.addListener(progressListener);
        if ((transfer.progress ?? 0.0) > 0.01 &&
            !progressCompleter.isCompleted) {
          progressCompleter.complete();
        }
        await progressCompleter.future;
        transfer.progressNotifier.removeListener(progressListener);

        // Cancel the transfer
        final canceled = await transfer.cancel();
        expect(canceled, isTrue);

        final result = await transfer.result;
        expect(result.status, equals(TaskStatus.canceled));
        expect(transfer.status, equals(TaskStatus.canceled));

        final filePath = await cancelTask.filePath();
        expect(File(filePath).existsSync(), isFalse);
      },
    );
  });

  group('Batch Transfers (startAll)', () {
    testWidgets(
      'startAll with multiple tasks and aggregate progress tracking',
      timeout: const Timeout(Duration(minutes: 3)),
      (tester) async {
        final tasks = [
          DownloadTask(
            url: urlWithoutContentLength,
            filename: 'batch_part_1.bin',
          ),
          DownloadTask(
            url: urlWithoutContentLength,
            filename: 'batch_part_2.bin',
          ),
          DownloadTask(
            url: urlWithoutContentLength,
            filename: 'batch_part_3.bin',
          ),
        ];

        final progressEvents = <(int, int)>[];
        final transfers = await FileDownloader().transfers.startAll(
          tasks,
          onProgress: (succeeded, failed) {
            progressEvents.add((succeeded, failed));
            print('Batch progress: $succeeded succeeded, $failed failed');
          },
        );

        expect(transfers.length, equals(3));

        // Await all transfers
        final results = await Future.wait(transfers.map((t) => t.result));
        for (final result in results) {
          expect(result.status, equals(TaskStatus.complete));
        }

        expect(progressEvents.isNotEmpty, isTrue);
        expect(progressEvents.last.$1, equals(3));
        expect(progressEvents.last.$2, equals(0));

        // Clean up files
        for (final task in tasks) {
          final file = File(await task.filePath());
          if (file.existsSync()) await file.delete();
        }
      },
    );

    testWidgets(
      'startAll with mixed success and failure',
      timeout: const Timeout(Duration(minutes: 3)),
      (tester) async {
        final tasks = [
          DownloadTask(
            url: urlWithoutContentLength,
            filename: 'batch_mix_1.bin',
          ),
          DownloadTask(
            url: urlWithFailure,
            filename: 'batch_mix_fail.bin',
            retries: 0,
          ),
          DownloadTask(
            url: urlWithoutContentLength,
            filename: 'batch_mix_2.bin',
          ),
        ];

        final progressEvents = <(int, int)>[];
        final transfers = await FileDownloader().transfers.startAll(
          tasks,
          onProgress: (succeeded, failed) {
            progressEvents.add((succeeded, failed));
          },
        );

        expect(transfers.length, equals(3));

        final results = await Future.wait(transfers.map((t) => t.result));
        expect(results[0].status, equals(TaskStatus.complete));
        expect(
          results[1].status == TaskStatus.failed ||
              results[1].status == TaskStatus.notFound,
          isTrue,
        );
        expect(results[2].status, equals(TaskStatus.complete));

        expect(progressEvents.isNotEmpty, isTrue);
        expect(progressEvents.last.$1, equals(2));
        expect(progressEvents.last.$2, equals(1));

        for (final task in tasks) {
          final file = File(await task.filePath());
          if (file.existsSync()) await file.delete();
        }
      },
    );
  });

  group('Matching & getOrStart', () {
    testWidgets(
      'getOrStart reuses completed transfer without re-downloading',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final task1 = DownloadTask(
          taskId: 'session1_task',
          url: urlWithoutContentLength,
          filename: 'match_test.bin',
        );

        final transfer1 = await FileDownloader().transfers.start(task1);
        final result1 = await transfer1.result;
        expect(result1.status, equals(TaskStatus.complete));

        // Create a new task object with a different taskId pointing to the same file/url
        final task2 = DownloadTask(
          taskId: 'session2_new_task',
          url: urlWithoutContentLength,
          filename: 'match_test.bin',
        );

        final transfer2 = await FileDownloader().transfers.getOrStart(task2);

        // Should return the cached transfer1 rather than starting a new download
        expect(transfer2.taskId, equals(task1.taskId));
        expect(transfer2.status, equals(TaskStatus.complete));

        final file = await transfer2.file;
        expect(file.existsSync(), isTrue);
        await file.delete();
      },
    );

    testWidgets(
      'getOrStart with custom matchBy predicate',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final task = DownloadTask(
          taskId: 'metadata_task_123',
          url: urlWithoutContentLength,
          filename: 'meta_match.bin',
          metaData: 'unique_model_checkpoint_v1',
        );

        final transfer = await FileDownloader().transfers.start(task);
        await transfer.result;

        final queryTask = DownloadTask(
          url: 'http://placeholder.url',
          filename: 'different_filename.bin',
        );

        final matched = await FileDownloader().transfers.getOrStart(
          queryTask,
          matchBy:
              (existing) => existing.metaData == 'unique_model_checkpoint_v1',
        );

        expect(matched.taskId, equals('metadata_task_123'));

        final file = await matched.file;
        if (file.existsSync()) await file.delete();
      },
    );

    testWidgets(
      'Transfer lookups and collections',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final taskA = DownloadTask(
          taskId: 'lookup_a',
          url: urlWithoutContentLength,
          filename: 'lookup_a.bin',
        );
        final taskB = DownloadTask(
          taskId: 'lookup_b',
          url: urlWithoutContentLength,
          filename: 'lookup_b.bin',
        );

        final transferA = await FileDownloader().transfers.start(taskA);
        final transferB = await FileDownloader().transfers.start(taskB);

        expect(FileDownloader().transfers.forId('lookup_a'), equals(transferA));
        expect(FileDownloader().transfers.forId('lookup_b'), equals(transferB));
        expect(FileDownloader().transfers.forTask(taskA), equals(transferA));

        expect(FileDownloader().transfers.all().length, greaterThanOrEqualTo(2));
        expect(
          FileDownloader().transfers.active().length,
          greaterThanOrEqualTo(2),
        );

        await Future.wait([transferA.result, transferB.result]);

        expect(
          FileDownloader().transfers.completed().length,
          greaterThanOrEqualTo(2),
        );

        final fileA = File(await taskA.filePath());
        final fileB = File(await taskB.filePath());
        if (fileA.existsSync()) await fileA.delete();
        if (fileB.existsSync()) await fileB.delete();
      },
    );
  });

  group('Scoping & Isolation (FileDownloader.scoped)', () {
    testWidgets(
      'Scoped FileDownloader instances isolate tasks and transfers',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final downloaderA = FileDownloader.scoped('module_alpha');
        final downloaderB = FileDownloader.scoped('module_beta');

        expect(downloaderA.hasNamespace, isTrue);
        expect(downloaderB.hasNamespace, isTrue);
        expect(downloaderA.namespace, equals('module_alpha'));
        expect(downloaderB.namespace, equals('module_beta'));

        final taskA = DownloadTask(
          url: urlWithoutContentLength,
          filename: 'scoped_a.bin',
          group: 'work',
        );
        final taskB = DownloadTask(
          url: urlWithoutContentLength,
          filename: 'scoped_b.bin',
          group: 'work',
        );

        final transferA = await downloaderA.transfers.start(taskA);
        final transferB = await downloaderB.transfers.start(taskB);

        // Verify task isolation within scopes
        expect(downloaderA.transfers.all().contains(transferA), isTrue);
        expect(downloaderA.transfers.all().contains(transferB), isFalse);

        expect(downloaderB.transfers.all().contains(transferB), isTrue);
        expect(downloaderB.transfers.all().contains(transferA), isFalse);

        // Await results
        await Future.wait([transferA.result, transferB.result]);

        expect(downloaderA.transfers.completed().contains(transferA), isTrue);
        expect(downloaderB.transfers.completed().contains(transferB), isTrue);

        // Reset scope A only
        final resetCount = await downloaderA.reset(group: 'work');
        expect(resetCount, greaterThanOrEqualTo(0));

        // Scope B should not be affected
        expect(downloaderB.transfers.all().contains(transferB), isTrue);

        final fileA = File(await taskA.filePath());
        final fileB = File(await taskB.filePath());
        if (fileA.existsSync()) await fileA.delete();
        if (fileB.existsSync()) await fileB.delete();
      },
    );
  });

  group('Transfer Reactive UI Widgets', () {
    testWidgets(
      'TransferProgressBar renders and updates reactively during live transfer',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final downloadTask = DownloadTask(
          url: urlWithContentLength,
          filename: 'widget_progress_test.bin',
          updates: Updates.statusAndProgress,
        );

        final transfer = await FileDownloader().transfers.start(downloadTask);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TransferProgressBar(
                transfer: transfer,
                showSpeed: true,
                showPercentage: true,
                showStatusText: true,
              ),
            ),
          ),
        );

        // Initially enqueued
        expect(find.byType(TransferProgressBar), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);

        // Wait for completion
        await transfer.result;
        await tester.pumpAndSettle();

        expect(find.text('Complete'), findsOneWidget);

        final file = await transfer.file;
        if (file.existsSync()) await file.delete();
      },
    );

    testWidgets(
      'TransferButton and TransferListTile render controls and title',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final task = DownloadTask(
          url: urlWithoutContentLength,
          filename: 'widget_tile_test.bin',
          displayName: 'Integration Test Asset',
          updates: Updates.statusAndProgress,
        );

        final transfer = await FileDownloader().transfers.start(task);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TransferListTile(
                transfer: transfer,
                showSpeed: true,
                showPercentage: true,
              ),
            ),
          ),
        );

        expect(find.text('Integration Test Asset'), findsOneWidget);
        expect(find.byType(TransferProgressBar), findsOneWidget);
        expect(find.byType(TransferButton), findsOneWidget);

        await transfer.result;
        await tester.pumpAndSettle();

        // Complete state shows check circle icon
        expect(find.byIcon(Icons.check_circle), findsOneWidget);

        final file = await transfer.file;
        if (file.existsSync()) await file.delete();
      },
    );
  });

  group('Smart Task Tuning via TransferHint', () {
    testWidgets(
      'TransferHint.userInitiated tunes priority and allowPause on live download',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final task = DownloadTask(
          url: urlWithContentLength,
          filename: 'hint_user_initiated.bin',
          transferHints: {TransferHint.userInitiated},
          updates: Updates.statusAndProgress,
        );

        expect(task.priority, equals(0));
        expect(task.allowPause, isTrue);

        final transfer = await FileDownloader().transfers.start(task);
        final result = await transfer.result;

        expect(result.status, equals(TaskStatus.complete));

        final file = await transfer.file;
        if (file.existsSync()) await file.delete();
      },
    );

    testWidgets(
      'Task with custom notificationConfig is respected on transfers.start',
      timeout: const Timeout(Duration(minutes: 2)),
      (tester) async {
        final notifConfig = TaskNotificationConfig(
          running: const TaskNotification(
            'Custom Transfer Title',
            'Transferring...',
          ),
          complete: const TaskNotification('Transfer Finished', 'Done!'),
          progressBar: true,
        );

        final task = DownloadTask(
          url: urlWithoutContentLength,
          filename: 'custom_notif_test.bin',
          notificationConfig: notifConfig,
        );

        final transfer = await FileDownloader().transfers.start(task);
        final result = await transfer.result;

        expect(result.status, equals(TaskStatus.complete));

        final file = await transfer.file;
        if (file.existsSync()) await file.delete();
      },
    );
  });
}
