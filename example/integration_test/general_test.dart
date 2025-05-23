// ignore_for_file: avoid_print, empty_catches

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

import 'test_utils.dart';

void main() {
  setUp(defaultSetup);

  tearDown(defaultTearDown);

  group('Initialization', () {
    test('registerCallbacks', () {
      expect(() => FileDownloader().registerCallbacks(), throwsAssertionError);
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      FileDownloader().registerCallbacks(
          group: 'test', taskProgressCallback: progressCallback);
    });

    test('unregisterCallbacks', () {
      FileDownloader().registerCallbacks(
          group: 'test',
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback,
          taskNotificationTapCallback: (task, notificationType) {});
      expect(FileDownloader().downloaderForTesting.groupStatusCallbacks['test'],
          isNotNull);
      expect(
          FileDownloader().downloaderForTesting.groupProgressCallbacks['test'],
          isNotNull);
      expect(
          FileDownloader()
              .downloaderForTesting
              .groupNotificationTapCallbacks['test'],
          isNotNull);
      // remove with different group, should not remove
      FileDownloader().unregisterCallbacks(callback: statusCallback);
      FileDownloader().unregisterCallbacks(callback: progressCallback);
      expect(FileDownloader().downloaderForTesting.groupStatusCallbacks['test'],
          isNotNull);
      expect(
          FileDownloader().downloaderForTesting.groupProgressCallbacks['test'],
          isNotNull);
      expect(
          FileDownloader()
              .downloaderForTesting
              .groupNotificationTapCallbacks['test'],
          isNotNull);
      // remove for the right group, except the groupNotificationTapCallback
      FileDownloader()
          .unregisterCallbacks(group: 'test', callback: statusCallback);
      FileDownloader()
          .unregisterCallbacks(group: 'test', callback: progressCallback);
      expect(FileDownloader().downloaderForTesting.groupStatusCallbacks['test'],
          isNull);
      expect(
          FileDownloader().downloaderForTesting.groupProgressCallbacks['test'],
          isNull);
      expect(
          FileDownloader()
              .downloaderForTesting
              .groupNotificationTapCallbacks['test'],
          isNotNull);
      // remove all callbacks for the test group
      FileDownloader().unregisterCallbacks(group: 'test');
      expect(FileDownloader().downloaderForTesting.groupStatusCallbacks['test'],
          isNull);
      expect(
          FileDownloader().downloaderForTesting.groupProgressCallbacks['test'],
          isNull);
      expect(
          FileDownloader()
              .downloaderForTesting
              .groupNotificationTapCallbacks['test'],
          isNull);
    });

    test('uploadTask', () {
      var task = UploadTask(url: uploadTestUrl, filename: uploadFilename);
      expect(task.fileField, equals('file'));
      expect(task.mimeType, equals('text/plain'));
      task = UploadTask(
          url: uploadTestUrl,
          filename: uploadFilename,
          fileField: 'fileField',
          mimeType: 'someThing');
      expect(task.fileField, equals('fileField'));
      expect(task.mimeType, equals('someThing'));
    });

    test('task with httpRequestMethod', () {
      expect(() => DownloadTask(url: workingUrl, httpRequestMethod: 'ILLEGAL'),
          throwsArgumentError);
    });
  });

  group('Enqueuing tasks', () {
    testWidgets('enqueue', (tester) async {
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      await enqueueAndFileExists(path);
      expect(lastStatus, equals(TaskStatus.complete));
      // with subdirectory
      task = DownloadTask(
          url: workingUrl, directory: 'test', filename: defaultFilename);
      path = join((await getApplicationDocumentsDirectory()).path, 'test',
          task.filename);
      await enqueueAndFileExists(path);
      // cache directory
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.temporary);
      path = join((await getTemporaryDirectory()).path, task.filename);
      await enqueueAndFileExists(path);
      // applicationSupport directory
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.applicationSupport);
      path = join((await getApplicationSupportDirectory()).path, task.filename);
      await enqueueAndFileExists(path);
      // applicationLibrary directory
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.applicationLibrary);
      path = await task.filePath();
      await enqueueAndFileExists(path);
      // root directory: same destination as applicationLibrary, using
      // the 'directory' field
      final dir = dirname(path); // no need to remove leading '/'
      final oldPath = path;
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.root,
          directory: dir);
      path = await task.filePath();
      expect(path, equals(oldPath));
      await enqueueAndFileExists(path);

      // test url with encoded parameter
      task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true', 'test': 'with%20space'},
          filename: defaultFilename);
      path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var result = jsonDecode(await File(path).readAsString());
      expect(result['args']['json'], equals('true'));
      expect(result['args']['test'], equals('with space'));
      await File(path).delete();

      // test url with PATCH httpRequestMethod
      task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true', 'test': 'with%20space'},
          httpRequestMethod: 'PATCH',
          filename: defaultFilename);
      path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      result = jsonDecode(await File(path).readAsString());
      expect(result['isPatch'], isTrue);
      await File(path).delete();
      print('Finished enqueue');
    });

    testWidgets('enqueue with progress', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      // because we have not set progressUpdates to something that provides
      // progress updates, we should just get no updates
      expect(progressCallbackCompleter.isCompleted, isFalse);
      expect(progressCallbackCounter, equals(0));
      statusCallbackCounter = 0;
      statusCallbackCompleter = Completer();
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await progressCallbackCompleter.future;
      // because google.com has no content-length, we only expect the 0.0 and
      // 1.0 progress update
      expect(progressCallbackCounter, equals(2));
      expect(lastValidExpectedFileSize, equals(-1));
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      // now try a file that has content length
      statusCallbackCounter = 0;
      progressCallbackCounter = 0;
      statusCallbackCompleter = Completer<void>();
      progressCallbackCompleter = Completer<void>();
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await progressCallbackCompleter.future;
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastValidExpectedFileSize, equals(urlWithContentLengthFileSize));
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      print('Finished enqueue with progress');
    });

    testWidgets('enqueue with download speed and time remaining',
        (widgetTester) async {
      task = DownloadTask(
          url: urlWithLongContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      await significantProgressCompleter.future;
      final networkSpeed = lastValidNetworkSpeed;
      final timeRemaining = lastValidTimeRemaining;
      expect(networkSpeed, greaterThan(0));
      expect(timeRemaining.isNegative, isFalse);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      final networkSpeed2 = lastValidNetworkSpeed;
      final timeRemaining2 = lastValidTimeRemaining;
      expect(networkSpeed2, greaterThan(0));
      expect(timeRemaining2.isNegative, isFalse);
      expect(networkSpeed, isNot(equals(networkSpeed2)));
      expect(timeRemaining, isNot(equals(timeRemaining2)));
    });

    testWidgets('enqueue with non-default group callbacks',
        (widgetTester) async {
      FileDownloader()
          .registerCallbacks(group: 'test', taskStatusCallback: statusCallback);
      // enqueue task with 'default' group, so no status updates should come
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      try {
        File(path).deleteSync();
      } on FileSystemException {}
      expect(await FileDownloader().enqueue(task), isTrue);
      await Future.delayed(const Duration(seconds: 3)); // can't know for sure!
      expect(File(path).existsSync(), isTrue); // file still downloads
      expect(statusCallbackCompleter.isCompleted, isFalse);
      expect(statusCallbackCounter, equals(0));
      await FileDownloader().cancelTaskWithId(task.taskId);
      print('Finished enqueue with non-default group callbacks');
    });

    testWidgets('enqueue with event listener for status updates',
        (widgetTester) async {
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      try {
        File(path).deleteSync();
      } on FileSystemException {}
      expect(await FileDownloader().enqueue(task), isTrue);
      await Future.delayed(const Duration(seconds: 3)); // can't know for sure!
      expect(File(path).existsSync(), isTrue); // file still downloads
      try {
        File(path).deleteSync();
      } on FileSystemException {}
      print(
          'Check log output -> should have warned that there is no callback or listener');
      // Register listener. For testing convenience, we simply route the event
      // to the completer function we have defined
      final subscription = FileDownloader().updates.listen((update) {
        if (update is TaskStatusUpdate) {
          if (update.status != TaskStatus.failed) {
            expect(update.exception, isNull);
          } else {
            // expect 403 Forbidden exception, coming up in second test
            print(update.status);
            expect(update.exception, isNotNull);
            expect(update.exception is TaskHttpException, isTrue);
            expect(update.exception?.description, equals('Not authorized'));
            expect((update.exception as TaskHttpException).httpResponseCode,
                equals(403));
          }
          statusCallback(update);
        }
      });
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      expect(File(path).existsSync(), isTrue);
      // test with a failing url and check the exception
      statusCallbackCompleter = Completer();
      task = DownloadTask(url: failingUrl, filename: 'test');
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.failed));
      final exception = lastException!;
      expect(exception is TaskHttpException, isTrue);
      expect(exception.description, equals('Not authorized'));
      expect((exception as TaskHttpException).httpResponseCode, equals(403));
      subscription.cancel();
    });

    testWidgets('enqueue with event listener and callback for status updates',
        (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      // Register listener. Because we also have a callback registered, no
      // events should be received
      bool receivedEvent = false;
      final subscription = FileDownloader().updates.listen((event) {
        receivedEvent = true;
      });
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      expect(File(path).existsSync(), isTrue);
      expect(receivedEvent, isFalse);
      subscription.cancel();
    });

    testWidgets('enqueue with event listener for progress updates',
        (widgetTester) async {
      task = DownloadTask(
          url:
              'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
          filename: defaultFilename,
          updates: Updates.progress);
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      // Register listener. For testing convenience, we simply route the event
      // to the completer function we have defined
      final subscription = FileDownloader().updates.listen((update) {
        expect(update is TaskProgressUpdate, isTrue);
        if (update is TaskProgressUpdate) {
          print("ProgressUpdate ${update.progress} at ${DateTime.now()}");
          progressCallback(update);
        }
      });
      expect(await FileDownloader().enqueue(task), isTrue);
      await progressCallbackCompleter.future;
      expect(progressCallbackCounter, greaterThan(1));
      expect(File(path).existsSync(), isTrue);
      await subscription.cancel();
    });

    testWidgets('enqueue with event listener, then reset and listen again',
        (widgetTester) async {
      // Register listener. For testing convenience, we simply route the event
      // to the completer function we have defined
      var subscription = FileDownloader().updates.listen((update) {
        if (update is TaskStatusUpdate) {
          statusCallback(update);
        }
      });
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      subscription.cancel();
      // reset and listen again
      statusCallbackCompleter = Completer();
      statusCallbackCounter = 0;
      await FileDownloader().resetUpdates();
      subscription = FileDownloader().updates.listen((update) {
        if (update is TaskStatusUpdate) {
          statusCallback(update);
        }
      });
      expect(await FileDownloader().enqueue(task.copyWith(taskId: 'task2')),
          isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      subscription.cancel();
    });

    testWidgets('enqueue with redirect', (widgetTester) async {
      task = DownloadTask(url: getRedirectTestUrl, filename: defaultFilename);
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      final contents = await File(path).readAsString();
      print(contents);
      expect(contents.startsWith("{'args': {'redirected': 'true'}"), isTrue);
      File(path).deleteSync();
    });

    testWidgets('enqueue and test file equality', (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      task = DownloadTask(url: urlWithContentLength, filename: defaultFilename);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, TaskStatus.complete);
      expect(
          await fileEqualsLargeTestFile(File(await task.filePath())), isTrue);
    });

    testWidgets('enqueue long Android task that times out',
        (widgetTester) async {
      // This is an Android implementation detail. Android tasks timeout
      // after 10 minutes, so to prevent a long download from failing
      // we pause the task and resume after a brief pause
      // NOTE: to test this, set the taskTimeoutMillis to a low value to
      // force an early timeout.
      if (Platform.isAndroid) {
        final timeOut =
            await FileDownloader().downloaderForTesting.getTaskTimeout();
        if (timeOut < const Duration(minutes: 1)) {
          FileDownloader().registerCallbacks(
              taskStatusCallback: statusCallback,
              taskProgressCallback: progressCallback);
          task = DownloadTask(
              url: urlWithContentLength,
              filename: defaultFilename,
              updates: Updates.statusAndProgress);
          expect(await FileDownloader().enqueue(task), isTrue);
          await statusCallbackCompleter.future;
          expect(lastStatus, equals(TaskStatus.failed)); // timed out
          expect(statusCallbackCounter, equals(3));
          task = task.copyWith(taskId: 'autoResume', allowPause: true);
          statusCallbackCompleter = Completer();
          statusCallbackCounter = 0;
          expect(await FileDownloader().enqueue(task), isTrue);
          await statusCallbackCompleter.future;
          expect(lastStatus, equals(TaskStatus.complete)); // now success
          expect(statusCallbackCounter, greaterThanOrEqualTo(6)); // min 1 pause
          expect(await fileEqualsLargeTestFile(File(await task.filePath())),
              isTrue);
        } else {
          print('Skipping test because taskTimeoutMillis is too high');
        }
      }
    });

    testWidgets('enqueue with invalid (malformed) url', (widgetTester) async {
      var task = DownloadTask(url: 'invalid%url.com', filename: 'test.html');
      expect(await FileDownloader().enqueue(task), isFalse);
      task = DownloadTask(
          url: 'http://google.com?query=5&some%other=true',
          filename: 'test.html');
      expect(await FileDownloader().enqueue(task), isFalse);
      task = DownloadTask(
          url: 'http://google.com?query=5&some%20other=true',
          filename: 'test.html');
      expect(await FileDownloader().enqueue(task), isTrue);
      await FileDownloader().cancelTaskWithId(task.taskId);
      // localhost
      task = DownloadTask(
          url: 'http://localhost:8085/something.html', filename: 'test.html');
      expect(await FileDownloader().enqueue(task), isTrue);
      await FileDownloader().cancelTaskWithId(task.taskId);
      await Future.delayed(const Duration(seconds: 2));
    });

    testWidgets('iOS exclude from Cloud backup', (widgetTester) async {
      // Check the logs for evidence of the bit being set
      final configResult = await FileDownloader()
          .configure(globalConfig: (Config.excludeFromCloudBackup, true));
      if (!Platform.isIOS) {
        expect(configResult.first,
            equals((Config.excludeFromCloudBackup, 'not implemented')));
        return;
      }
      expect(configResult.first, equals((Config.excludeFromCloudBackup, '')));
      expect(
          () => FileDownloader().configure(
              globalConfig: (Config.excludeFromCloudBackup, "invalid")),
          throwsAssertionError);
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      // Cache directory will not set bit, but cannot see that in logs
      task = task.copyWith(baseDirectory: BaseDirectory.temporary);
      await FileDownloader().download(task);
      var configResult2 = await FileDownloader()
          .configure(iOSConfig: (Config.excludeFromCloudBackup, Config.never));
      expect(configResult2.first.$1, equals(Config.excludeFromCloudBackup));
    });
  });

  group('Queue and task management', () {
    testWidgets('reset', (widgetTester) async {
      print('Starting reset');
      await Future.delayed(const Duration(seconds: 2)); // clear cancellations
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      expect(await FileDownloader().reset(group: 'non-default'), equals(0));
      expect(await FileDownloader().reset(), equals(1));
      await Future.delayed(const Duration(seconds: 1));
      // on iOS, the quick cancellation may not yield a 'running' state
      expect(statusCallbackCounter, lessThanOrEqualTo(3));
      expect(lastStatus, equals(TaskStatus.canceled));
      print('Finished reset');
    });

    testWidgets('allTaskIds', (widgetTester) async {
      print('Starting allTaskIds');
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      expect(await FileDownloader().allTaskIds(group: 'non-default'), isEmpty);
      expect((await FileDownloader().allTaskIds()).length, equals(1));
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      print('Finished allTaskIds');
    });

    testWidgets('allTasks', (widgetTester) async {
      print('Starting allTasks');
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      expect(await FileDownloader().allTasks(group: 'non-default'), isEmpty);
      final tasks = await FileDownloader().allTasks();
      expect(tasks.length, equals(1));
      expect(tasks.first, equals(task));
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      print('Finished allTasks');
    });

    testWidgets('allTasks and allTaskIds with allGroups set to true',
        (widgetTester) async {
      print('Starting allTasks with allGroups set to true');
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final task2 = task.copyWith(group: 'group2');
      expect(await FileDownloader().enqueue(task), isTrue);
      expect(await FileDownloader().enqueue(task2), isTrue);
      expect(await FileDownloader().allTasks(group: 'non-default'), isEmpty);
      expect(() => FileDownloader().allTasks(group: 'some', allGroups: true),
          throwsAssertionError);
      expect(
          () => FileDownloader()
              .allTasks(includeTasksWaitingToRetry: false, allGroups: true),
          throwsAssertionError);
      final tasks = await FileDownloader().allTasks(allGroups: true);
      expect(tasks.length, equals(2));
      expect(tasks.contains(task), isTrue);
      expect(tasks.contains(task2), isTrue);
      final taskIds = await FileDownloader().allTaskIds(allGroups: true);
      expect(taskIds.length, equals(2));
      expect(taskIds.contains(task.taskId), isTrue);
      expect(taskIds.contains(task2.taskId), isTrue);
      await Future.delayed(const Duration(seconds: 3));
      print('Finished allTasks with allGroups set to true');
    });

    testWidgets('tasksFinished', (widgetTester) async {
      print('Starting tasksFinished');
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      expect(await FileDownloader().tasksFinished(), isFalse);
      expect(
          await FileDownloader().tasksFinished(group: 'non-default'), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(await FileDownloader().tasksFinished(), isTrue);
      // now start a task and intentionally ignore it
      statusCallbackCompleter = Completer();
      expect(await FileDownloader().enqueue(task), isTrue);
      expect(await FileDownloader().tasksFinished(), isFalse);
      expect(await FileDownloader().tasksFinished(ignoreTaskId: task.taskId),
          isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(await FileDownloader().tasksFinished(), isTrue);
      print('Finished tasksFinished');
    });

    testWidgets('cancelTasksWithIds', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(await FileDownloader().enqueue(task), isTrue);
      var taskIds = await FileDownloader().allTaskIds();
      expect(taskIds.length, equals(1));
      expect(taskIds.first, equals(task.taskId));
      expect(await FileDownloader().cancelTasksWithIds(taskIds), isTrue);
      await statusCallbackCompleter.future;
      // on iOS, the quick cancellation may not yield a 'running' state
      expect(statusCallbackCounter, lessThanOrEqualTo(3));
      expect(lastStatus, equals(TaskStatus.canceled));
      // now do the same for a longer running task, cancel after some progress
      statusCallbackCounter = 0;
      statusCallbackCompleter = Completer();
      someProgressCompleter = Completer();
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      taskIds = await FileDownloader().allTaskIds();
      expect(taskIds.length, equals(1));
      expect(taskIds.first, equals(task.taskId));
      expect(await FileDownloader().cancelTasksWithIds(taskIds), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.canceled));
      print('Finished cancelTasksWithIds');
    });

    testWidgets('taskForId', (widgetTester) async {
      print('Starting taskForId');
      final complexTask = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          headers: {'Auth': 'Test'},
          directory: 'directory',
          metaData: 'someMetaData');
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().taskForId('something'), isNull);
      expect(await FileDownloader().enqueue(complexTask), isTrue);
      expect(await FileDownloader().taskForId('something'), isNull);
      expect(await FileDownloader().taskForId(complexTask.taskId),
          equals(complexTask));
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      print('Finished taskForId');
    });

    testWidgets('DownloadTask to and from Json', (widgetTester) async {
      final complexTask = DownloadTask(
          url: postTestUrl,
          filename: defaultFilename,
          headers: {'Auth': 'Test'},
          httpRequestMethod: 'post',
          post: 'TestPost',
          directory: 'directory',
          baseDirectory: BaseDirectory.temporary,
          group: 'someGroup',
          updates: Updates.statusAndProgress,
          requiresWiFi: false,
          retries: 5,
          allowPause: false,
          // cannot be true if post != null
          metaData: 'someMetaData',
          displayName: 'displayName');
      final now = DateTime.now();
      expect(now.difference(complexTask.creationTime).inMilliseconds,
          lessThan(100));
      FileDownloader().registerCallbacks(
          group: complexTask.group, taskStatusCallback: statusCallback);
      expect(await FileDownloader().taskForId(complexTask.taskId), isNull);
      expect(await FileDownloader().enqueue(complexTask), isTrue);
      final task = await FileDownloader().taskForId(complexTask.taskId);
      expect(task is DownloadTask, isTrue);
      expect(task, equals(complexTask));
      if (task != null) {
        expect(task.taskId, equals(complexTask.taskId));
        expect(task.url, equals(complexTask.url));
        expect(task.filename, equals(complexTask.filename));
        expect(task.headers, equals(complexTask.headers));
        expect(task.httpRequestMethod, equals(complexTask.httpRequestMethod));
        expect(task.post, equals(complexTask.post));
        expect(task.directory, equals(complexTask.directory));
        expect(task.baseDirectory, equals(complexTask.baseDirectory));
        expect(task.group, equals(complexTask.group));
        expect(task.updates, equals(complexTask.updates));
        expect(task.requiresWiFi, equals(complexTask.requiresWiFi));
        expect(task.allowPause, equals(complexTask.allowPause));
        expect(task.retries, equals(complexTask.retries));
        expect(task.retriesRemaining, equals(complexTask.retriesRemaining));
        expect(task.retriesRemaining, equals(task.retries));
        expect(task.metaData, equals(complexTask.metaData));
        expect(task.displayName, equals(complexTask.displayName));
        expect(
            task.creationTime
                .difference(complexTask.creationTime)
                .inMilliseconds
                .abs(),
            lessThan(100));
      }
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
    });

    testWidgets('UploadTask to and from Json', (widgetTester) async {
      final complexTask = UploadTask(
          url: uploadTestUrl,
          filename: uploadFilename,
          headers: {'Auth': 'Test'},
          httpRequestMethod: 'post',
          post: null,
          fileField: 'fileField',
          mimeType: 'text/html',
          fields: {'name': 'value'},
          group: 'someGroup',
          updates: Updates.statusAndProgress,
          requiresWiFi: false,
          retries: 1,
          metaData: 'someMetaData');
      expect(complexTask.httpRequestMethod, equals('POST'));
      final now = DateTime.now();
      expect(now.difference(complexTask.creationTime).inMilliseconds,
          lessThan(100));
      FileDownloader().registerCallbacks(
          group: complexTask.group, taskStatusCallback: statusCallback);
      expect(await FileDownloader().taskForId(complexTask.taskId), isNull);
      expect(await FileDownloader().enqueue(complexTask), isTrue);
      final task = await FileDownloader().taskForId(complexTask.taskId);
      expect(task is UploadTask, isTrue);
      expect(task, equals(complexTask));
      if (task != null && task is UploadTask) {
        expect(task.taskId, equals(complexTask.taskId));
        expect(task.url, equals(complexTask.url));
        expect(task.filename, equals(complexTask.filename));
        expect(task.headers, equals(complexTask.headers));
        expect(task.httpRequestMethod, equals(complexTask.httpRequestMethod));
        expect(task.post, equals(complexTask.post));
        expect(task.fileField, equals(complexTask.fileField));
        expect(task.mimeType, equals(complexTask.mimeType));
        expect(task.fields, equals(complexTask.fields));
        expect(task.directory, equals(complexTask.directory));
        expect(task.baseDirectory, equals(complexTask.baseDirectory));
        expect(task.group, equals(complexTask.group));
        expect(task.updates, equals(complexTask.updates));
        expect(task.requiresWiFi, equals(complexTask.requiresWiFi));
        expect(task.allowPause, equals(complexTask.allowPause));
        expect(task.retries, equals(complexTask.retries));
        expect(task.retriesRemaining, equals(complexTask.retriesRemaining));
        expect(task.retriesRemaining, equals(task.retries));
        expect(task.metaData, equals(complexTask.metaData));
        expect(
            task.creationTime
                .difference(complexTask.creationTime)
                .inMilliseconds
                .abs(),
            lessThan(100));
      }
      await statusCallbackCompleter.future;

      /// Should trigger 'notFound' because the fileField is not set to 'file
      /// which is what the server expects
      expect(lastStatus, equals(TaskStatus.notFound));
    });

    testWidgets('requireWiFi setting', (widgetTester) async {
      if (Platform.isAndroid || Platform.isIOS) {
        await FileDownloader().requireWiFi(RequireWiFi.asSetByTask);
        expect(await FileDownloader().getRequireWiFiSetting(),
            equals(RequireWiFi.asSetByTask));
        await FileDownloader().requireWiFi(RequireWiFi.forAllTasks);
        await Future.delayed(const Duration(seconds: 2));
        expect(await FileDownloader().getRequireWiFiSetting(),
            equals(RequireWiFi.forAllTasks));
        await FileDownloader().requireWiFi(RequireWiFi.forNoTasks);
        await Future.delayed(const Duration(seconds: 2));
        expect(await FileDownloader().getRequireWiFiSetting(),
            equals(RequireWiFi.forNoTasks));
        await FileDownloader().requireWiFi(RequireWiFi.asSetByTask);
        await Future.delayed(const Duration(seconds: 2));
        expect(await FileDownloader().getRequireWiFiSetting(),
            equals(RequireWiFi.asSetByTask));
      }
    });
  });

  group('Convenience downloads', () {
    testWidgets('download with await', (widgetTester) async {
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      var exists = await File(path).exists();
      if (exists) {
        await File(path).delete();
      }
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.exception, isNull);
      expect(result.responseBody, isNull);
      expect(result.responseHeaders?['server'], equals('gws'));
      expect(result.responseStatusCode, equals(200));
      exists = await File(path).exists();
      expect(exists, isTrue);
      await File(path).delete();
    });

    testWidgets('multiple download with futures', (widgetTester) async {
      final secondTask =
          task.copyWith(taskId: 'secondTask', filename: 'second.html');
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      var exists = await File(path).exists();
      if (exists) {
        await File(path).delete();
      }
      path = join(
          (await getApplicationDocumentsDirectory()).path, secondTask.filename);
      exists = await File(path).exists();
      if (exists) {
        await File(path).delete();
      }
      // note that using a Future (without await) is unusual and is done here
      // just for testing.  Normal use would be
      // var result = await FileDownloader().download(task);
      final taskFuture = FileDownloader().download(task);
      final secondTaskFuture = FileDownloader().download(secondTask);
      var results = await Future.wait([taskFuture, secondTaskFuture]);
      for (var result in results) {
        expect(result.status, equals(TaskStatus.complete));
      }
      exists = await File(path).exists();
      expect(exists, isTrue);
      await File(path).delete();
      path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      exists = await File(path).exists();
      expect(exists, isTrue);
      await File(path).delete();
    });

    testWidgets('batch download', (widgetTester) async {
      final tasks = <DownloadTask>[];
      final docDir = (await getApplicationDocumentsDirectory()).path;
      for (int n = 0; n < 3; n++) {
        final filename = 'google$n.html';
        final filepath = join(docDir, filename);
        if (File(filepath).existsSync()) {
          File(filepath).deleteSync();
        }
        // only task with n==1 will fail
        tasks.add(n != 1
            ? DownloadTask(url: workingUrl, filename: filename)
            : DownloadTask(url: failingUrl, filename: filename));
      }
      final result = await FileDownloader().downloadBatch(tasks);
      // confirm results contain two successes and one failure
      expect(result.numSucceeded, equals(2));
      expect(result.numFailed, equals(1));
      final succeeded = result.succeeded;
      expect(succeeded.length, equals(2));
      final succeededFilenames = succeeded.map((e) => e.filename);
      expect(succeededFilenames.contains('google0.html'), isTrue);
      expect(succeededFilenames.contains('google1.html'), isFalse);
      expect(succeededFilenames.contains('google2.html'), isTrue);
      final failed = result.failed;
      expect(failed.length, equals(1));
      final failedFilenames = failed.map((e) => e.filename);
      expect(failedFilenames.contains('google0.html'), isFalse);
      expect(failedFilenames.contains('google1.html'), isTrue);
      expect(failedFilenames.contains('google2.html'), isFalse);
      // confirm files exist
      expect(File(join(docDir, 'google0.html')).existsSync(), isTrue);
      expect(File(join(docDir, 'google1.html')).existsSync(), isFalse);
      expect(File(join(docDir, 'google2.html')).existsSync(), isTrue);
      // cleanup
      for (int n = 0; n < 3; n++) {
        final filename = 'google$n.html';
        final filepath = join(docDir, filename);
        if (File(filepath).existsSync()) {
          File(filepath).deleteSync();
        }
      }
      print('Finished batch download');
    });

    testWidgets('batch download with batch callback', (widgetTester) async {
      final tasks = <DownloadTask>[];
      final docDir = (await getApplicationDocumentsDirectory()).path;
      for (int n = 0; n < 3; n++) {
        final filename = 'google$n.html';
        final filepath = join(docDir, filename);
        if (File(filepath).existsSync()) {
          File(filepath).deleteSync();
        }
        // only task with n==1 will fail
        tasks.add(n != 1
            ? DownloadTask(url: workingUrl, filename: filename)
            : DownloadTask(url: failingUrl, filename: filename));
      }
      var numSucceeded = 0;
      var numFailed = 0;
      var numCalled = 0;
      await FileDownloader().downloadBatch(tasks,
          batchProgressCallback: (succeeded, failed) {
        print('Succeeded: $succeeded, failed: $failed');
        numCalled++;
        numSucceeded = succeeded;
        numFailed = failed;
      });
      expect(numCalled, equals(4)); // also called with 0, 0 at start
      expect(numSucceeded, equals(2));
      expect(numFailed, equals(1));

      // cleanup
      for (int n = 0; n < 3; n++) {
        final filename = 'google$n.html';
        final filepath = join(docDir, filename);
        if (File(filepath).existsSync()) {
          File(filepath).deleteSync();
        }
      }
      print('Finished batch download with callback');
    });

    testWidgets('batch download with task callback', (widgetTester) async {
      final failTask =
          DownloadTask(url: failingUrl, filename: defaultFilename, retries: 2);
      final task3 = task.copyWith(taskId: 'task3');
      final result = await FileDownloader().downloadBatch(
          [task, failTask, task3],
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(result.numSucceeded, equals(2));
      expect(result.numFailed, equals(1));
      expect(result.failed.first.taskId, equals(failTask.taskId));
      expect(statusCallbackCounter,
          equals(15)); // 3 attempts + 2 retry attempts, each 3
      expect(progressCallbackCounter, greaterThanOrEqualTo(10));
    });

    testWidgets('batch download with onElapsedTime', (widgetTester) async {
      final tasks = <DownloadTask>[
        DownloadTask(url: urlWithContentLength),
        DownloadTask(url: urlWithContentLength),
        DownloadTask(url: urlWithContentLength)
      ];
      var ticks = 0;
      final result = await FileDownloader().downloadBatch(tasks,
          onElapsedTime: (elapsed) => ticks++,
          elapsedTimeInterval: const Duration(milliseconds: 200));
      expect(result.numSucceeded, equals(3));
      expect(ticks, greaterThan(0));
      await Future.delayed(const Duration(seconds: 10));
    });

    testWidgets('convenience download with callbacks', (widgetTester) async {
      var result = await FileDownloader().download(task,
          onStatus: (status) => statusCallback(TaskStatusUpdate(task, status)));
      expect(result.task, equals(task));
      expect(result.status, equals(TaskStatus.complete));
      expect(statusCallbackCounter, equals(3));
      expect(progressCallbackCompleter.isCompleted, isFalse);
      expect(progressCallbackCounter, equals(0));
      // reset for round two with progress callback
      statusCallbackCounter = 0;
      progressCallbackCounter = 0;
      statusCallbackCompleter = Completer<void>();
      progressCallbackCompleter = Completer<void>();
      task = DownloadTask(url: urlWithContentLength, filename: defaultFilename);
      result = await FileDownloader().download(task,
          onStatus: (status) => statusCallback(TaskStatusUpdate(task, status)),
          onProgress: (progress) =>
              progressCallback(TaskProgressUpdate(task, progress)));
      expect(result.status, equals(TaskStatus.complete));
      expect(statusCallbackCounter, equals(3));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(1.0));
      print('Finished convenience download with callbacks');
    });

    testWidgets('parallel convenience downloads with callbacks',
        (widgetTester) async {
      var a = 0, b = 0, c = 0;
      var p1 = 0.0, p2 = 0.0, p3 = 0.0;
      final failTask =
          DownloadTask(url: failingUrl, filename: defaultFilename, retries: 2);
      var failingResult = FileDownloader().download(failTask,
          onStatus: (status) => a++, onProgress: (progress) => p1 += progress);
      var successResult = FileDownloader().download(task,
          onStatus: (status) => b++, onProgress: (progress) => p2 += progress);
      var successResult2 = FileDownloader().download(
          task.copyWith(taskId: 'second'),
          onStatus: (status) => c++,
          onProgress: (progress) => p3 += progress);
      await Future.wait([failingResult, successResult, successResult2]);
      expect(a, equals(9));
      expect(b, equals(3));
      expect(c, equals(3)); // number of calls to the closure status update
      if (Platform.isAndroid) {
        // sum of calls to the closure progress update
        expect(p1, equals(-9.0)); // retry [-4] retry [-4] failed [-1]
        expect(p2, equals(1.0)); // complete [1]
        expect(p3, equals(1.0)); // complete [1]
      }
      if (Platform.isIOS) {
        // sum of calls to the closure progress update
        expect(p1, closeTo(-4 - 4 - 1 + 3 * 0.999, 0.1)); // retry [-4] retry
        // [-4] failed [-1]
        // + 3 * 0.999
        expect(p2, closeTo(1.0, 0.1)); // complete [1]
        expect(p3, closeTo(1.0, 0.1)); // complete [1]
      }
      successResult
          .then((value) => expect(value.status, equals(TaskStatus.complete)));
      successResult2
          .then((value) => expect(value.status, equals(TaskStatus.complete)));
      failingResult
          .then((value) => expect(value.status, equals(TaskStatus.failed)));
      print('Finished parallel convenience downloads with callbacks');
    });

    testWidgets('simple parallel convenience downloads with callbacks',
        (widgetTester) async {
      final failTask =
          DownloadTask(url: failingUrl, filename: defaultFilename, retries: 2);
      var failingResult = FileDownloader().download(failTask,
          onStatus: (status) =>
              statusCallback(TaskStatusUpdate(failTask, status)));
      var successResult = FileDownloader().download(task,
          onStatus: (status) => statusCallback(TaskStatusUpdate(task, status)));
      await Future.wait([successResult, failingResult]);
      successResult
          .then((value) => expect(value.status, equals(TaskStatus.complete)));
      failingResult
          .then((value) => expect(value.status, equals(TaskStatus.failed)));
      expect(statusCallbackCounter, equals(12));
      print('Finished simple parallel convenience downloads with callbacks');
    });

    testWidgets('onElapsedTime', (widgetTester) async {
      task = DownloadTask(url: urlWithLongContentLength);
      var ticks = 0;
      final result =
          await FileDownloader().download(task, onElapsedTime: (elapsed) {
        print('Elapsed time: $elapsed');
        ticks++;
      }, elapsedTimeInterval: const Duration(milliseconds: 200));
      expect(result.status, equals(TaskStatus.complete));
      expect(ticks, greaterThan(0));
    });

    testWidgets('not found', (widgetTester) async {
      task = DownloadTask(
          url: 'https://avmaps-dot-bbflightserver-hrd.appspot.com/something');
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.notFound));
      expect(
          result.responseBody,
          equals('<!doctype html>\n'
              '<html lang=en>\n'
              '<title>404 Not Found</title>\n'
              '<h1>Not Found</h1>\n'
              '<p>The requested URL was not found on the server. If you entered the URL manually '
              'please check your spelling and try again.</p>\n'));
      expect(result.responseStatusCode, equals(404));
    });
  });

  group('Retries', () {
    testWidgets('basic retry logic', (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(retryTask.retriesRemaining, equals(retryTask.retries));
      expect(await FileDownloader().enqueue(retryTask), isTrue);
      await Future.delayed(const Duration(seconds: 4));
      final retriedTask = await FileDownloader().taskForId(retryTask.taskId);
      expect(retriedTask, equals(retryTask));
      if (retriedTask != null) {
        expect(retriedTask.retriesRemaining, lessThan(retriedTask.retries));
      }
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.failed));
      // enqueued, running, waitingToRetry/failed for each try
      expect(statusCallbackCounter, equals((retryTask.retries + 1) * 3));
    });

    testWidgets('basic with progress updates', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final retryTaskWithProgress =
          retryTask.copyWith(updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(retryTaskWithProgress), isTrue);
      await Future.delayed(const Duration(seconds: 6));
      expect(lastProgress, equals(progressWaitingToRetry));
      // iOS emits 0.0 & 0.999 progress updates for a 403 response with the
      // text of the response, before sharing the response code, triggering
      // the -4.0 progress response.
      // On other platforms, only 0.0 & -4.0 is emitted
      expect(progressCallbackCounter, equals(Platform.isIOS ? 6 : 4));
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.failed));
      // wait a sec for the last progress update
      await Future.delayed(const Duration(seconds: 1));
      expect(lastProgress, equals(progressFailed));
    });

    testWidgets('retry with cancellation', (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(retryTask), isTrue);
      await Future.delayed(const Duration(seconds: 6));
      final retriedTask = await FileDownloader().taskForId(retryTask.taskId);
      expect(retriedTask, equals(retryTask));
      if (retriedTask != null) {
        expect(retriedTask.retriesRemaining, lessThan(retriedTask.retries));
        expect(await FileDownloader().cancelTasksWithIds([retriedTask.taskId]),
            isTrue);
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.canceled));
        // 3 callbacks for each try, plus one for cancel
        expect(
            statusCallbackCounter,
            equals(
                (retriedTask.retries - retriedTask.retriesRemaining) * 3 + 1));
      }
      expect(await FileDownloader().taskForId(retryTask.taskId), isNull);
    });

    testWidgets('retry progress updates with cancellation',
        (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final retryTaskWithProgress =
          retryTask.copyWith(updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(retryTaskWithProgress), isTrue);
      expect(progressCallbackCounter, equals(0));
      await Future.delayed(const Duration(seconds: 6));
      expect(lastProgress, equals(progressWaitingToRetry));
      // iOS emits 0.0 & 0.999 progress updates for a 403 response with the
      // text of the response, before sharing the response code, triggering
      // the -4.0 progress response.
      // On other platforms, only 0.0 & -4.0 is emitted
      expect(progressCallbackCounter, equals(Platform.isIOS ? 6 : 4));
      final retriedTask = await FileDownloader().taskForId(retryTask.taskId);
      expect(retriedTask, equals(retryTask));
      if (retriedTask != null) {
        expect(retriedTask.retriesRemaining, lessThan(retriedTask.retries));
        expect(await FileDownloader().cancelTasksWithIds([retriedTask.taskId]),
            isTrue);
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.canceled));
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastProgress, equals(progressCanceled));
        expect(await FileDownloader().taskForId(retryTask.taskId), isNull);
      }
    });

    testWidgets('queue management: allTasks with retries',
        (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(retryTask), isTrue);
      expect(await FileDownloader().enqueue(task), isTrue);
      final allTasks = await FileDownloader().allTasks();
      expect(allTasks.length, equals(2));
      expect(allTasks.contains(retryTask), isTrue);
      expect(allTasks.contains(task), isTrue);
      final nonRetryTasksBeforeWait =
          await FileDownloader().allTasks(includeTasksWaitingToRetry: false);
      expect(nonRetryTasksBeforeWait.length, equals(2));
      expect(nonRetryTasksBeforeWait.contains(retryTask), isTrue);
      expect(nonRetryTasksBeforeWait.contains(task), isTrue);
      await Future.delayed(const Duration(seconds: 4));
      // after wait the regular task has disappeared
      final nonRetryTasksAfterWait =
          await FileDownloader().allTasks(includeTasksWaitingToRetry: false);
      expect(nonRetryTasksAfterWait.length, equals(0));
      final allTasksAfterWait = await FileDownloader().allTasks();
      expect(allTasksAfterWait.length, equals(1));
      expect(allTasksAfterWait.contains(retryTask), isTrue);
      await FileDownloader().cancelTasksWithIds([retryTask.taskId]);
    });

    testWidgets('queue management: taskForId with retries',
        (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(retryTask), isTrue);
      expect(await FileDownloader().enqueue(task), isTrue); // regular task
      expect(await FileDownloader().taskForId(retryTask.taskId),
          equals(retryTask));
      expect(await FileDownloader().taskForId(task.taskId), equals(task));
      await Future.delayed(const Duration(seconds: 4));
      // after wait the regular task has disappeared
      expect(await FileDownloader().taskForId(retryTask.taskId),
          equals(retryTask));
      expect(await FileDownloader().taskForId(task.taskId), isNull);
      await FileDownloader().cancelTasksWithIds([retryTask.taskId]);
    });

    testWidgets('[*] resume on failure', (widgetTester) async {
      // this test requires manual failure while the task is downloading
      // and therefore does NOT fail if the task completes normally
      //print(await FileDownloader().configure(iOSConfig: ('resourceTimeout', const Duration(seconds: 15))));
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithLongContentLength, updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      expect(await FileDownloader().taskCanResume(task),
          isFalse); // allowPause not set
      print('FAIL TASK NOW!');
      await statusCallbackCompleter.future;
      if (lastStatus == TaskStatus.failed) {
        // manual fail succeeded, we should have resume data
        expect(
            await FileDownloader()
                .downloaderForTesting
                .getResumeData(task.taskId),
            isNotNull);
        expect(await FileDownloader().taskCanResume(task), isTrue);
        // reset and resume the task
        statusCallbackCompleter = Completer();
        someProgressCompleter = Completer();
        expect(await FileDownloader().resume(task), isTrue);
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.complete));
      } else {
        print(
            'Test skipped because task was not failed manually. Task status = $lastStatus');
      }
    });

    testWidgets('[*] resume on retry', (widgetTester) async {
      // this test requires manual failure while the task is downloading
      // and therefore does NOT fail if the task completes normally
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithLongContentLength,
          updates: Updates.statusAndProgress,
          retries: 2);
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      expect(await FileDownloader().taskCanResume(task),
          isFalse); // allowPause not set
      print('FAIL TASK NOW!');
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
    });
  });

  group('DownloadTask with POST request', () {
    testWidgets('post DownloadTask with post is empty body',
        (widgetTester) async {
      final task = DownloadTask(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-empty'},
          filename: postFilename,
          headers: {'Header1': 'headerValue1'},
          post: '');
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      final result = jsonDecode(await File(path).readAsString());
      print(result);
      expect(result['args']['request-type'], equals('post-empty'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect((result['data'] as String).isEmpty, isTrue);
      expect(result['json'], isNull);
    });

    testWidgets('post DownloadTask with post is String', (widgetTester) async {
      final task = DownloadTask(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-String'},
          filename: postFilename,
          headers: {'content-type': 'text/plain'},
          post: 'testPost');
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      final result = jsonDecode(await File(path).readAsString());
      print(result);
      expect(result['args']['request-type'], equals('post-String'));
      // note: Content-Type may include charset= on some platforms
      expect(result['headers']['Content-Type'], contains('text/plain'));
      expect(result['data'], equals('testPost'));
      expect(result['json'], isNull);
    });

    testWidgets('post DownloadTask with post is Uint8List',
        (widgetTester) async {
      final task = DownloadTask(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-Uint8List'},
          filename: postFilename,
          headers: {'Content-Type': 'application/octet-stream'},
          post: Uint8List.fromList('testPost'.codeUnits));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      final result = jsonDecode(await File(path).readAsString());
      print(result);
      expect(result['args']['request-type'], equals('post-Uint8List'));
      // note: Content-Type may include charset= on some platforms
      expect(result['headers']['Content-Type'],
          contains('application/octet-stream'));
      expect(result['data'], equals('testPost'));
      expect(result['json'], isNull);
    });

    testWidgets('post DownloadTask with post is JsonString',
        (widgetTester) async {
      final task = DownloadTask(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-json'},
          filename: postFilename,
          headers: {
            'Header1': 'headerValue1',
            'content-type': 'application/json'
          },
          post: '{"field1":1}');
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      final result = jsonDecode(await File(path).readAsString());
      print(result);
      expect(result['args']['request-type'], equals('post-json'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('{"field1":1}'));
      // confirm the server side interpreted this as JSON
      expect(result['json'], equals({'field1': 1}));
    });

    testWidgets('post DownloadTask with post is Map', (widgetTester) async {
      final task = DownloadTask(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-json'},
          filename: postFilename,
          headers: {
            'Header1': 'headerValue1',
            'content-type': 'application/json'
          },
          post: {"field1": 1});
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      final result = jsonDecode(await File(path).readAsString());
      print(result);
      expect(result['args']['request-type'], equals('post-json'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('{"field1":1}'));
      // confirm the server side interpreted this as JSON
      expect(result['json'], equals({'field1': 1}));
    });

    testWidgets('post DownloadTask with post is List', (widgetTester) async {
      final task = DownloadTask(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-json'},
          filename: postFilename,
          headers: {
            'Header1': 'headerValue1',
            'content-type': 'application/json'
          },
          post: ['apple', 'orange']);
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      final result = jsonDecode(await File(path).readAsString());
      print(result);
      expect(result['args']['request-type'], equals('post-json'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('["apple","orange"]'));
      // confirm the server side interpreted this as JSON
      expect(result['json'], equals(['apple', 'orange']));
    });

    testWidgets('post DownloadTask with post is invalid type',
        (widgetTester) async {
      expect(
          () => DownloadTask(
              url: postTestUrl,
              urlQueryParameters: {'request-type': 'invalid'},
              filename: postFilename,
              headers: {'Header1': 'headerValue1'},
              post: 2),
          throwsA(isA<TypeError>()));
    });
  });

  group('Request', () {
    testWidgets('get request', (widgetTester) async {
      final request = Request(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true', 'request-type': 'get%20it'},
          headers: {'Header1': 'headerValue1'});
      // note: json=true required to get results as JSON string
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['json'], equals('true'));
      expect(result['args']['request-type'], equals('get it'));
      expect(result['headers']['Header1'], equals('headerValue1'));
    });

    testWidgets('post request with post is empty body', (widgetTester) async {
      final request = Request(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-empty'},
          headers: {'Header1': 'headerValue1'},
          post: '');
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['request-type'], equals('post-empty'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect((result['data'] as String).isEmpty, isTrue);
      expect(result['json'], isNull);
    });

    testWidgets('post request with post is String', (widgetTester) async {
      final request = Request(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-String'},
          headers: {'Header1': 'headerValue1'},
          post: 'testPost');
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['request-type'], equals('post-String'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('testPost'));
      expect(result['json'], isNull);
    });

    testWidgets('post request with post is Uint8List', (widgetTester) async {
      final request = Request(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-Uint8List'},
          headers: {'Header1': 'headerValue1'},
          post: Uint8List.fromList('testPost'.codeUnits));
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['request-type'], equals('post-Uint8List'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('testPost'));
      expect(result['json'], isNull);
    });

    testWidgets('post request with post is JsonString', (widgetTester) async {
      final request = Request(
          url: postTestUrl,
          urlQueryParameters: {'request-type': 'post-json'},
          headers: {
            'Header1': 'headerValue1',
            'content-type': 'application/json'
          },
          post: '{"field1": 1}');
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['request-type'], equals('post-json'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('{"field1": 1}'));
      // confirm the server side interpreted this as JSON
      expect(result['json'], equals({'field1': 1}));
    });

    testWidgets('post request with post is Map', (widgetTester) async {
      final request = Request(url: postTestUrl, urlQueryParameters: {
        'request-type': 'post-json'
      }, headers: {
        'Header1': 'headerValue1',
        'content-type': 'application/json'
      }, post: {
        'field': 1
      });
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['request-type'], equals('post-json'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('{"field":1}'));
      // confirm the server side interpreted this as JSON
      expect(result['json'], equals({'field': 1}));
    });

    testWidgets('post request with post is List', (widgetTester) async {
      final request = Request(url: postTestUrl, urlQueryParameters: {
        'request-type': 'post-json'
      }, headers: {
        'Header1': 'headerValue1',
        'content-type': 'application/json'
      }, post: [
        'apple',
        'orange'
      ]);
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(200));
      final result = jsonDecode(response.body);
      expect(result['args']['request-type'], equals('post-json'));
      expect(result['headers']['Header1'], equals('headerValue1'));
      expect(result['data'], equals('["apple","orange"]'));
      // confirm the server side interpreted this as JSON
      expect(result['json'], equals(['apple', 'orange']));
    });

    testWidgets('post request with post is invalid type', (widgetTester) async {
      expect(
          () => Request(
              url: postTestUrl,
              urlQueryParameters: {'request-type': 'invalid'},
              headers: {'Header1': 'headerValue1'},
              post: 2),
          throwsA(isA<TypeError>()));
    });

    testWidgets('get request with server error, no retries',
        (widgetTester) async {
      final request = Request(url: failingUrl);
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(403));
      expect(response.reasonPhrase, equals('Forbidden'));
    });

    testWidgets('get request with server error, with retries',
        (widgetTester) async {
      // There is no easy way to confirm the retries are happening, because the
      // Request object is modified within the Isolate and not passed back to
      // the main isolate. We therefore observe the three retries by
      // examining the server logs
      final request = Request(url: failingUrl, retries: 3);
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(403));
      expect(response.reasonPhrase, equals('Forbidden'));
    });

    testWidgets('get request with malformed url error, no retries',
        (widgetTester) async {
      final request = Request(url: 'somethingRandom');
      final response = await FileDownloader().request(request);
      expect(response.statusCode, equals(499));
      expect(
          response.reasonPhrase,
          equals(
              'Invalid argument(s): No host specified in URI somethingRandom'));
    });

    testWidgets('get request with redirect', (widgetTester) async {
      final request = Request(url: getRedirectTestUrl);
      final response = await FileDownloader().request(request);
      print('code = ${response.statusCode} and body is ${response.body}');
      expect(response.statusCode, equals(200));
      expect(
          response.body.startsWith("{'args': {'redirected': 'true'}"), isTrue);
    });
  });

  group('Basic upload', () {
    testWidgets('enqueue multipart file', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(
          await FileDownloader()
              .enqueue(uploadTask.copyWith(updates: Updates.statusAndProgress)),
          isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(progressComplete));
      print('Finished enqueue multipart file');
    });

    testWidgets('enqueue w/o file', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      // try the binary upload to a multipart endpoint
      final failingUploadTask = uploadTask.copyWith(
          post: 'binary', updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(failingUploadTask), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.notFound));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(progressNotFound));
      print('Finished enqueue w/o file');
    });

    testWidgets('enqueue binary file', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final task = uploadTask.copyWith(
          url: uploadBinaryTestUrl,
          post: 'binary',
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(progressComplete));
      print('Finished enqueue binary file');
    });

    testWidgets('upload binary file partially bytes=2-4', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final task = uploadTask.copyWith(
          url: uploadBinaryTestUrl,
          headers: {'Range': 'bytes=2-4'},
          post: 'binary');
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.responseBody, equals('fil'));
    });

    testWidgets('upload binary file partially bytes=2-', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final task = uploadTask.copyWith(
          url: uploadBinaryTestUrl,
          headers: {'Range': 'bytes=2-'},
          post: 'binary');
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.responseBody, equals('file.'));
    });

    testWidgets('upload binary file partially invalid headers',
        (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final task = uploadTask.copyWith(
          url: uploadBinaryTestUrl, headers: {'Range': 'z'}, post: 'binary');
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.failed));
    });

    testWidgets('enqueue multipart with fields', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final fields = {
        'field1': 'value1',
        'field2': 'check\u2713',
        'field3': '{"a":"b"}',
        'field4': '["1", "2"]'
      };
      final result =
          await FileDownloader().upload(uploadTask.copyWith(fields: fields));
      expect(result.status, equals(TaskStatus.complete));
      final jsonString = result.responseBody!.replaceAll(r'\r\n', '');
      expect(jsonDecode(jsonString), equals(fields));
    });

    testWidgets('enqueue multipart with fields that have multiple values',
        (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final fields = {'field1': 'value1', 'field2': '"value2", "value3"'};
      final result =
          await FileDownloader().upload(uploadTask.copyWith(fields: fields));
      expect(result.status, equals(TaskStatus.complete));
      expect(jsonDecode(result.responseBody!),
          equals({'field1': 'value1', 'field2': 'value2'}));
    });

    testWidgets('enqueue binary file, then cancel', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final task = uploadTask.copyWith(
          filename: largeFilename,
          url: uploadBinaryTestUrl,
          post: 'binary',
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      expect(await FileDownloader().cancelTaskWithId(task.taskId), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.canceled));
      print('Finished enqueue binary file, then cancel');
    });

    testWidgets('upload task creation with errors', (widgetTester) async {
      expect(
          () => UploadTask(
              url: uploadTestUrl,
              filename: defaultFilename,
              fields: {'name': 'value'},
              post: 'binary'),
          throwsAssertionError);
    });

    testWidgets('Create UploadTask from File', (widgetTester) async {
      final pathToFile = await uploadTask.filePath();
      final file = File(pathToFile);
      final taskFromFile = UploadTask.fromFile(file: file, url: uploadTask.url);
      expect(await taskFromFile.filePath(), equals(pathToFile));
      final result = await FileDownloader().upload(taskFromFile);
      expect(result.status, equals(TaskStatus.complete));
    });
  });

  group('Convenience uploads', () {
    testWidgets('multipart upload with await', (widgetTester) async {
      final result = await FileDownloader().upload(uploadTask);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.responseBody, equals('{}'));
      expect(result.responseHeaders?['server'], equals('Google Frontend'));
      expect(result.responseStatusCode, equals(200));
    });

    testWidgets('binary upload with await', (widgetTester) async {
      final result = await FileDownloader().upload(
          uploadTask.copyWith(url: uploadBinaryTestUrl, post: 'binary'));
      expect(result.status, equals(TaskStatus.complete));
      expect(result.responseBody, equals('A file.'));
      expect(result.responseHeaders?['server'], equals('Google Frontend'));
      expect(result.responseStatusCode, equals(200));
    });

    testWidgets('multiple upload with futures', (widgetTester) async {
      final secondTask = uploadTask.copyWith(taskId: 'secondTask');
      // note that using a Future (without await) is unusual and is done here
      // just for testing.  Normal use would be
      // var result = await FileDownloader().upload(task);
      final taskFuture = FileDownloader().upload(uploadTask);
      final secondTaskFuture = FileDownloader().upload(secondTask);
      var results = await Future.wait([taskFuture, secondTaskFuture]);
      for (var result in results) {
        expect(result.status, equals(TaskStatus.complete));
        expect(result.responseBody, equals('{}'));
        expect(result.responseHeaders?['server'], equals('Google Frontend'));
        expect(result.responseStatusCode, equals(200));
      }
    });

    testWidgets('batch upload', (widgetTester) async {
      final failingUploadTask =
          uploadTask.copyWith(taskId: 'fails', post: 'binary');
      final tasks = <UploadTask>[
        uploadTask,
        failingUploadTask,
        uploadTask.copyWith(taskId: 'third')
      ];
      final result = await FileDownloader().uploadBatch(tasks);
      // confirm results contain two successes and one failure
      expect(result.numSucceeded, equals(2));
      expect(result.numFailed, equals(1));
      final succeeded = result.succeeded;
      expect(succeeded.length, equals(2));
      final succeededTaskIds = succeeded.map((e) => e.taskId);
      expect(succeededTaskIds.contains(tasks[0].taskId), isTrue);
      expect(succeededTaskIds.contains(tasks[1].taskId), isFalse);
      expect(succeededTaskIds.contains(tasks[2].taskId), isTrue);
      final failed = result.failed;
      expect(failed.length, equals(1));
      final failedTaskIds = failed.map((e) => e.taskId);
      expect(failedTaskIds.contains(tasks[0].taskId), isFalse);
      expect(failedTaskIds.contains(tasks[1].taskId), isTrue);
      expect(failedTaskIds.contains(tasks[2].taskId), isFalse);
      print('Finished batch upload');
    });

    testWidgets('batch upload with callback', (widgetTester) async {
      final failingUploadTask =
          uploadTask.copyWith(taskId: 'fails', post: 'binary');
      final tasks = <UploadTask>[
        uploadTask,
        failingUploadTask,
        uploadTask.copyWith(taskId: 'third')
      ];
      var numSucceeded = 0;
      var numFailed = 0;
      var numCalled = 0;
      await FileDownloader().uploadBatch(tasks,
          batchProgressCallback: (succeeded, failed) {
        print('Succeeded: $succeeded, failed: $failed');
        numCalled++;
        numSucceeded = succeeded;
        numFailed = failed;
      });
      expect(numCalled, equals(4)); // also called with 0, 0 at start
      expect(numSucceeded, equals(2));
      expect(numFailed, equals(1));
      print('Finished batch upload with callback');
    });

    testWidgets('batch upload with onElapsedTime', (widgetTester) async {
      final tasks = <UploadTask>[
        uploadTask,
        uploadTask.copyWith(taskId: 'task2'),
        uploadTask.copyWith(taskId: 'task3')
      ];
      var ticks = 0;
      final result = await FileDownloader().uploadBatch(tasks,
          onElapsedTime: (elapsed) => ticks++,
          elapsedTimeInterval: const Duration(milliseconds: 20));
      expect(result.numSucceeded, equals(3));
      expect(ticks, greaterThan(0));
      await Future.delayed(const Duration(seconds: 10));
    });

    testWidgets('convenience upload with callbacks', (widgetTester) async {
      var result = await FileDownloader().upload(uploadTask,
          onStatus: (status) =>
              statusCallback(TaskStatusUpdate(uploadTask, status)));
      expect(result.status, equals(TaskStatus.complete));
      expect(statusCallbackCounter, equals(3));
      expect(progressCallbackCompleter.isCompleted, isFalse);
      expect(progressCallbackCounter, equals(0));
      // reset for round two with progress callback
      statusCallbackCounter = 0;
      progressCallbackCounter = 0;
      statusCallbackCompleter = Completer<void>();
      progressCallbackCompleter = Completer<void>();
      final task2 = uploadTask.copyWith(taskId: 'second');
      result = await FileDownloader().upload(task2,
          onStatus: (status) => statusCallback(TaskStatusUpdate(task2, status)),
          onProgress: (progress) =>
              progressCallback(TaskProgressUpdate(task2, progress)));
      expect(result.status, equals(TaskStatus.complete));
      expect(statusCallbackCounter, equals(3));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(1.0));
      print('Finished convenience upload with callbacks');
    });

    testWidgets('onElapsedTime', (widgetTester) async {
      var ticks = 0;
      final result =
          await FileDownloader().upload(uploadTask, onElapsedTime: (elapsed) {
        print('Elapsed time: $elapsed');
        ticks++;
      }, elapsedTimeInterval: const Duration(milliseconds: 20));
      expect(result.status, equals(TaskStatus.complete));
      expect(ticks, greaterThan(0));
    });
  });

  group('MultiUpload', () {
    testWidgets('upload 2 files using enqueue', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final multiTask = MultiUploadTask(
          url: uploadMultiTestUrl,
          files: [('f1', uploadFilename), ('f2', uploadFilename2)],
          fields: {'key': 'value'},
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(multiTask), isTrue);
      await someProgressCompleter.future;
      expect(lastProgress, greaterThan(0));
      expect(lastProgress, lessThan(1));
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
    });

    testWidgets('upload 2 files using upload', (widgetTester) async {
      final fields = {'key': 'value'};
      final multiTask = MultiUploadTask(
          url: uploadMultiTestUrl,
          files: [('f1', uploadFilename), ('f2', uploadFilename2)],
          fields: fields);
      final result = await FileDownloader().upload(multiTask);
      expect(result.status, equals(TaskStatus.complete));
      expect(jsonDecode(result.responseBody!), equals(fields));
      expect(result.responseHeaders?['server'], equals('Google Frontend'));
      expect(result.responseStatusCode, equals(200));
    });

    testWidgets('upload 2 files with full file path', (widgetTester) async {
      final docsDir = await getApplicationDocumentsDirectory();
      final fullPath = join(docsDir.path, uploadFilename);
      final fields = {'key': 'value'};
      final multiTask = MultiUploadTask(
          url: uploadMultiTestUrl,
          files: [('f1', fullPath), ('f2', uploadFilename2)],
          fields: fields);
      final result = await FileDownloader().upload(multiTask);
      expect(result.status, equals(TaskStatus.complete));
      expect(jsonDecode(result.responseBody!), equals(fields));
      expect(result.responseHeaders?['server'], equals('Google Frontend'));
      expect(result.responseStatusCode, equals(200));
    });
  });

  group('Cancellation', () {
    testWidgets('cancel enqueued tasks', (widgetTester) async {
      var cancelCounter = 0;
      var completeCounter = 0;
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        if (update.status == TaskStatus.canceled) {
          cancelCounter++;
        }
        if (update.status == TaskStatus.complete) {
          completeCounter++;
        }
      });
      final tasks = <DownloadTask>[];
      for (var n = 1; n < 20; n++) {
        tasks.add(DownloadTask(url: urlWithContentLength));
      }
      for (var task in tasks) {
        expect(await FileDownloader().enqueue(task), equals(true));
        if (task == tasks.first) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      await Future.delayed(const Duration(seconds: 1));
      expect(
          await FileDownloader()
              .cancelTasksWithIds(await FileDownloader().allTaskIds()),
          equals(true));
      await Future.delayed(const Duration(seconds: 2));
      print('Completed: $completeCounter, cancelled: $cancelCounter');
      expect(cancelCounter + completeCounter, equals(tasks.length));
      final docsDir = await getApplicationDocumentsDirectory();
      for (var task in tasks) {
        final file = File(join(docsDir.path, task.filename));
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
    });

    testWidgets('cancel after some progress', (widgetTester) async {
      final task = DownloadTask(
          url: urlWithContentLength, updates: Updates.statusAndProgress);
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      expect(await FileDownloader().cancelTaskWithId(task.taskId), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.canceled));
      await Future.delayed(const Duration(seconds: 1));
      expect(lastStatus, equals(TaskStatus.canceled));
    });

    /// If a task fails immediately, eg due to a malformed url, it
    /// must still be cancellable. This test cancels a failing task
    /// immediately after enqueueing it, and should succeed in doing so
    testWidgets('immediately cancel a task that fails immediately',
        (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final task = DownloadTask(url: 'file://doesNotExist', filename: 'test');
      expect(await FileDownloader().enqueue(task), equals(true));
      expect(
          await FileDownloader().cancelTaskWithId(task.taskId), equals(true));
      await statusCallbackCompleter.future;
      if (Platform.isIOS) {
        // cannot avoid fail on iOS
        expect(lastStatus, equals(TaskStatus.failed));
      } else {
        expect(lastStatus, equals(TaskStatus.canceled));
      }
    });
  });

  group('Tracking', () {
    testWidgets('activate tracking', (widgetTester) async {
      await FileDownloader().database.deleteAllRecords();
      await FileDownloader()
          .registerCallbacks(
              taskStatusCallback: statusCallback,
              taskProgressCallback: progressCallback)
          .trackTasks(markDownloadedComplete: false);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      await Future.delayed(const Duration(milliseconds: 10)); // allow db write
      // after some progress, expect status running and some progress in database
      final record = await FileDownloader().database.recordForId(task.taskId);
      expect(record, isNotNull);
      expect(record?.taskId, equals(task.taskId));
      expect(record?.status, equals(TaskStatus.running));
      expect(record?.progress, greaterThan(0));
      expect(record?.progress, equals(lastProgress));
      expect(record?.exception, isNull);
      await statusCallbackCompleter.future;
      // completed
      final record2 = await FileDownloader().database.recordForId(task.taskId);
      expect(record2, isNotNull);
      expect(record2?.taskId, equals(task.taskId));
      expect(record2?.status, equals(TaskStatus.complete));
      expect(record2?.progress, equals(progressComplete));
      expect(record2?.exception, isNull);
      final records = await FileDownloader().database.allRecords();
      expect(records.length, equals(1));
      expect(records.first, equals(record2));
    });

    testWidgets('activate tracking for group', (widgetTester) async {
      await FileDownloader().database.deleteAllRecords();
      await FileDownloader()
          .registerCallbacks(
              group: 'testGroup',
              taskStatusCallback: statusCallback,
              taskProgressCallback: progressCallback)
          .trackTasksInGroup('someGroup', markDownloadedComplete: false);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          group: 'testGroup',
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      await Future.delayed(
          const Duration(milliseconds: 10)); // allow db writeThe next one is 17
      // after some progress, expect nothing in database
      var record = await FileDownloader().database.recordForId(task.taskId);
      expect(record, isNull);
      await statusCallbackCompleter.future;
      await FileDownloader().trackTasks(); // now track all tasks
      statusCallbackCompleter = Completer();
      someProgressCompleter = Completer();
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          group: 'testGroup',
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      await Future.delayed(const Duration(milliseconds: 10)); // allow db write
      // now expect progress and status in the database
      record = await FileDownloader().database.recordForId(task.taskId);
      expect(record, isNotNull);
      expect(record?.taskId, equals(task.taskId));
      expect(record?.status, equals(TaskStatus.running));
      expect(record?.progress, greaterThan(0));
      expect(record?.progress, equals(lastProgress));
      expect(record?.exception, isNull);
      await statusCallbackCompleter.future;
    });

    testWidgets('set, get and delete record', (widgetTester) async {
      await FileDownloader().database.deleteAllRecords();
      await FileDownloader()
          .registerCallbacks(taskStatusCallback: statusCallback)
          .trackTasks();
      task = DownloadTask(url: workingUrl, filename: defaultFilename);
      expect(await FileDownloader().enqueue(task), equals(true));
      await statusCallbackCompleter.future;
      final record = await FileDownloader().database.recordForId(task.taskId);
      expect(record?.task.taskId, equals(task.taskId));
      final firsTaskId = task.taskId;
      // task with url as id
      statusCallbackCompleter = Completer();
      task = DownloadTask(
          taskId: workingUrl, url: workingUrl, filename: defaultFilename);
      expect(await FileDownloader().enqueue(task), equals(true));
      await statusCallbackCompleter.future;
      final record2 = await FileDownloader().database.recordForId(task.taskId);
      expect(record2?.task.taskId, equals(task.taskId));
      final records = await FileDownloader().database.allRecords();
      expect(records.length, equals(2));
      await FileDownloader().database.deleteRecordWithId(task.taskId);
      final records2 = await FileDownloader().database.allRecords();
      expect(records2.length, equals(1));
      expect(records2.first.taskId, equals(firsTaskId));
    });

    testWidgets('allRecords', (widgetTester) async {
      await FileDownloader().database.deleteAllRecords();
      await FileDownloader()
          .registerCallbacks(taskStatusCallback: statusCallback)
          .trackTasks();
      task = DownloadTask(
          taskId: workingUrl, // contains illegal characters
          url: workingUrl,
          filename: defaultFilename);
      expect(await FileDownloader().enqueue(task), equals(true));
      await statusCallbackCompleter.future;
      final records = await FileDownloader().database.allRecords();
      expect(records.length, equals(1));
      expect(records.first.taskId, equals(task.taskId));
      expect(records.first.status, equals(TaskStatus.complete));
      expect(records.first.progress, equals(progressComplete));
    });

    testWidgets('markDownloadedComplete', (widgetTester) async {
      await FileDownloader().database.deleteAllRecords();
      await FileDownloader()
          .registerCallbacks(
              taskStatusCallback: statusCallback,
              taskProgressCallback: progressCallback)
          .trackTasks(markDownloadedComplete: false);
      final filePath = await task.filePath();
      if (File(filePath).existsSync()) {
        File(filePath).deleteSync();
      }
      // start a download, then cancel
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      await FileDownloader().cancelTasksWithIds([task.taskId]);
      await Future.delayed(const Duration(milliseconds: 500));
      final record = await FileDownloader().database.recordForId(task.taskId);
      expect(record?.status, equals(TaskStatus.canceled));
      expect(File(filePath).existsSync(), isFalse);
      // reactivate tracking, this time with markDownloadedComplete = true
      await FileDownloader().trackTasks();
      // because no file, status does not change
      final record2 = await FileDownloader().database.recordForId(task.taskId);
      expect(record2?.status, equals(TaskStatus.canceled));
      expect(record2?.progress, equals(record?.progress));
      // create a 'downloaded' file (even though the task was canceled)
      await File(filePath).writeAsString('test');
      // reactivate tracking, again with markDownloadedComplete = true
      await FileDownloader().trackTasks();
      // status and progress should now reflect 'complete'
      final record3 = await FileDownloader().database.recordForId(task.taskId);
      expect(record3?.status, equals(TaskStatus.complete));
      expect(record3?.progress, equals(progressComplete));
      print('Finished markDownloadedComplete');
    });

    testWidgets('track with exception', (widgetTester) async {
      await FileDownloader().database.deleteAllRecords();
      await FileDownloader()
          .registerCallbacks(
              taskStatusCallback: statusCallback,
              taskProgressCallback: progressCallback)
          .trackTasks(markDownloadedComplete: false);
      task = DownloadTask(
          url: failingUrl,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), equals(true));
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.failed));
      // failed
      final record = await FileDownloader().database.recordForId(task.taskId);
      expect(record, isNotNull);
      expect(record?.taskId, equals(task.taskId));
      expect(record?.status, equals(TaskStatus.failed));
      expect(record?.progress, equals(progressFailed));
      expect(record?.exception, isNotNull);
      final exception = (record?.exception)!;
      expect(exception is TaskHttpException, isTrue);
      expect(exception.description, equals('Not authorized'));
      expect((exception as TaskHttpException).httpResponseCode, equals(403));
      final records = await FileDownloader().database.allRecords();
      expect(records.length, equals(1));
    });
  });

  group('Pause and resume', () {
    testWidgets('taskCanResume', (tester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress,
          allowPause: true);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      final canResume = await FileDownloader().taskCanResume(task);
      expect(canResume, isTrue);
      expect(await FileDownloader().cancelTasksWithIds([task.taskId]), isTrue);
      // now don't set 'allowPause'
      statusCallbackCompleter = Completer();
      someProgressCompleter = Completer();
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      final canResume2 = await FileDownloader().taskCanResume(task);
      expect(canResume2, isFalse); // task allowPause not set
      expect(await FileDownloader().cancelTasksWithIds([task.taskId]), isTrue);
      await Future.delayed(const Duration(seconds: 1));
    });

    testWidgets('pause and resume task', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress,
          allowPause: true);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      expect(await FileDownloader().pause(task), isTrue);
      await Future.delayed(const Duration(milliseconds: 500));
      expect(lastStatus, equals(TaskStatus.paused));
      print("paused");
      // resume
      expect(await FileDownloader().resume(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(
          await fileEqualsLargeTestFile(File(await task.filePath())), isTrue);
    });

    testWidgets('pause and resume task with ? as filename',
        (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: DownloadTask.suggestedFilename,
          updates: Updates.statusAndProgress,
          allowPause: true);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      expect(await FileDownloader().pause(task), isTrue);
      await Future.delayed(const Duration(milliseconds: 500));
      expect(lastStatus, equals(TaskStatus.paused));
      print("paused");
      await Future.delayed(const Duration(seconds: 2));
      // resume
      expect(await FileDownloader().resume(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastTaskWithStatus, isNotNull);
      var file = File(await lastTaskWithStatus!.filePath());
      expect(await fileEqualsLargeTestFile(file), isTrue);
      await file.delete();
    });

    testWidgets('pause and resume with invalid ETag', (widgetTester) async {
      // iOS manages resume for us, so we cannot test this
      if (!Platform.isIOS) {
        FileDownloader().registerCallbacks(
            taskStatusCallback: statusCallback,
            taskProgressCallback: progressCallback);
        task = DownloadTask(
            url: urlWithContentLength,
            filename: defaultFilename,
            updates: Updates.statusAndProgress,
            allowPause: true);
        expect(await FileDownloader().enqueue(task), equals(true));
        await someProgressCompleter.future;
        expect(await FileDownloader().pause(task), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));
        // mess with the ResumeData
        final resumeData = await FileDownloader()
            .database
            .storage
            .retrieveResumeData(task.taskId);
        final newResumeData = ResumeData(task, resumeData!.data,
            resumeData.requiredStartByte, 'differentTag');
        await FileDownloader().database.storage.storeResumeData(newResumeData);
        // resume
        expect(await FileDownloader().resume(task), isTrue);
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.failed));
        expect(lastException?.description,
            equals('Cannot resume: ETag is not identical, or is weak'));
      }
    });

    testWidgets('pause task that cannot be paused', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress,
          allowPause: false);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      final canResume = await FileDownloader().taskCanResume(task);
      expect(canResume, isFalse);
      expect(await FileDownloader().pause(task), isFalse);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
    });

    testWidgets('cancel a paused task', (widgetTester) async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress,
          allowPause: true);
      expect(await FileDownloader().enqueue(task), equals(true));
      await someProgressCompleter.future;
      expect(await FileDownloader().pause(task), isTrue);
      await Future.delayed(const Duration(milliseconds: 500));
      expect(lastStatus, equals(TaskStatus.paused));
      final downloader = FileDownloader().downloaderForTesting;
      expect(downloader.getResumeData(task.taskId), isNotNull);
      final resumeData = await downloader.getResumeData(task.taskId);
      final tempFilePath = resumeData!.data;
      if (!Platform.isIOS) {
        // on iOS we don't have access to the temp file directly
        expect(File(tempFilePath).existsSync(), isTrue);
        expect(File(tempFilePath).lengthSync(),
            equals(resumeData.requiredStartByte));
      }
      expect(await FileDownloader().cancelTasksWithIds([task.taskId]), isTrue);
      await Future.delayed(const Duration(milliseconds: 200));
      expect(lastStatus, equals(TaskStatus.canceled));
      expect(File(tempFilePath).existsSync(), isFalse);
    });

    // testWidgets('multiple pause and resume', (widgetTester) async {
    //   // Note: this test is flaky as it depends on internet connection
    //   // speed. If the test fails, it is likely because the task completed
    //   // before the initial pause command, or did not have time for two
    //   // pause/resume cycles -> shorten interval
    //   var interval = Platform.isAndroid || Platform.isIOS
    //       ? const Duration(milliseconds: 1500)
    //       : const Duration(milliseconds: 2000);
    //   FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
    //   task = DownloadTask(
    //       url: urlWithLongContentLength,
    //       filename: defaultFilename,
    //       allowPause: true);
    //   expect(await FileDownloader().enqueue(task), equals(true));
    //   var result = TaskStatus.enqueued;
    //   while (result != TaskStatus.complete) {
    //     await Future.delayed(interval);
    //     result = lastStatus;
    //     if (result != TaskStatus.complete) {
    //       expect(await FileDownloader().pause(task), isTrue);
    //       while (lastStatus != TaskStatus.paused) {
    //         await Future.delayed(const Duration(milliseconds: 250));
    //       }
    //       expect(await FileDownloader().resume(task), isTrue);
    //     }
    //   }
    //   expect(await (File(await task.filePath())).length(), equals(59673498));
    //   expect(statusCallbackCounter, greaterThanOrEqualTo(9)); // min 2 pause
    // });
//TODO put back multi pause and resume
    testWidgets('Pause and resume a convenience download',
        (widgetTester) async {
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          allowPause: true);
      // kick off convenience download but do not wait for the result
      unawaited(FileDownloader().download(task,
          onStatus: (status) => statusCallback(TaskStatusUpdate(task, status)),
          onProgress: (progress) =>
              progressCallback(TaskProgressUpdate(task, progress))));
      await someProgressCompleter.future;
      expect(await FileDownloader().pause(task), equals(true));
      await Future.delayed(const Duration(milliseconds: 500));
      expect(lastStatus, equals(TaskStatus.paused));
      expect(await FileDownloader().resume(task), equals(true));
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastProgress, equals(progressComplete));
    });

    testWidgets('Pause and resume a task with a Range header',
        (widgetTester) async {
      const rangeStart = 10;
      const rangeEnd = 10000000; // 10MB
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = task.copyWith(
          url: urlWithLongContentLength,
          headers: {'Range': 'bytes=$rangeStart-$rangeEnd'},
          updates: Updates.statusAndProgress,
          allowPause: true);
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      expect(await FileDownloader().pause(task), isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(await FileDownloader().resume(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastValidExpectedFileSize, equals(rangeEnd - rangeStart + 1));
      var file = File(await task.filePath());
      expect(file.lengthSync(), equals(lastValidExpectedFileSize));
      await file.delete();
    });
  });

  group('Fail background channel', () {
    testWidgets(
        'Local storage for resumeData, statusUpdates and progressUpdates',
        (widgetTester) async {
      if (Platform.isAndroid || Platform.isIOS) {
        final downloader = FileDownloader().downloaderForTesting;
        // force fail triggers local storage, but does not prevent
        // messages to be posted, so we can see the real value as well
        await downloader.setForceFailPostOnBackgroundChannel(true);
        FileDownloader().registerCallbacks(
            taskStatusCallback: statusCallback,
            taskProgressCallback: progressCallback);
        task = DownloadTask(
            url: urlWithContentLength,
            filename: defaultFilename,
            updates: Updates.statusAndProgress,
            allowPause: true);
        expect(await FileDownloader().enqueue(task), equals(true));
        await someProgressCompleter.future;
        final canResume = await FileDownloader().taskCanResume(task);
        expect(canResume, isTrue);
        expect(await FileDownloader().pause(task), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        // clear the stored data
        await downloader.removeResumeData(task.taskId);
        await downloader.removePausedTask(task.taskId);
        await Future.delayed(const Duration(milliseconds: 200));
        expect((await downloader.getResumeData(task.taskId)), isNull);
        expect((await downloader.getPausedTask(task.taskId)), isNull);
        // reset last status and progress, then retrieve 'missing' data
        lastStatus = TaskStatus.enqueued; // must change to paused
        final oldLastProgress = lastProgress;
        lastProgress = -1; // must change to a real value
        await downloader.retrieveLocallyStoredData(); // triggers updates
        downloader.retrievedLocallyStoredData = false; // reset for testing
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));
        expect(lastProgress, equals(oldLastProgress));
        expect((await downloader.getResumeData(task.taskId))?.taskId,
            equals(task.taskId));
        expect((await downloader.getPausedTask(task.taskId)), equals(task));
        // confirm all popped data is gone
        final resumeDataMap =
            await downloader.popUndeliveredData(Undelivered.resumeData);
        expect(resumeDataMap.length, equals(0));
        final statusUpdateMap =
            await downloader.popUndeliveredData(Undelivered.statusUpdates);
        expect(statusUpdateMap.length, equals(0));
        final progressUpdateMap =
            await downloader.popUndeliveredData(Undelivered.progressUpdates);
        expect(progressUpdateMap.length, equals(0));
        expect(await FileDownloader().cancelTaskWithId(task.taskId), isTrue);
      }
    });

    testWidgets('Local storage for taskStatusUpdate - ok download',
        (widgetTester) async {
      if (Platform.isAndroid || Platform.isIOS) {
        final downloader = FileDownloader().downloaderForTesting;
        // force fail triggers local storage, but does not prevent
        // messages to be posted, so we can see the real value as well
        await downloader.setForceFailPostOnBackgroundChannel(true);
        FileDownloader().registerCallbacks(
            taskStatusCallback: statusCallback,
            taskProgressCallback: progressCallback);
        task = DownloadTask(
            url: urlWithContentLength,
            filename: defaultFilename,
            allowPause: true);
        var taskStatusUpdate = await FileDownloader().download(task);
        expect(taskStatusUpdate.status, equals(TaskStatus.complete));
        expect(taskStatusUpdate.exception, isNull);
        expect(taskStatusUpdate.mimeType, equals('application/zip'));
        expect(taskStatusUpdate.charSet, isNull);
        expect(taskStatusUpdate.responseBody, isNull);
        expect(taskStatusUpdate.responseHeaders?.containsKey('content-length'),
            isTrue);
        expect(taskStatusUpdate.responseStatusCode, equals(200));
        // now get the locally stored taskStatus and check again
        taskStatusUpdate = TaskStatusUpdate(task, TaskStatus.failed); // reset
        FileDownloader().registerCallbacks(
            taskStatusCallback: (update) => taskStatusUpdate = update);
        await Future.delayed(const Duration(milliseconds: 500));
        await downloader.retrieveLocallyStoredData(); // triggers status update
        downloader.retrievedLocallyStoredData = false; // reset for testing
        await Future.delayed(const Duration(milliseconds: 500));
        expect(taskStatusUpdate.status, equals(TaskStatus.complete));
        expect(taskStatusUpdate.exception, isNull);
        expect(taskStatusUpdate.mimeType, equals('application/zip'));
        expect(taskStatusUpdate.charSet, isNull);
        expect(taskStatusUpdate.responseBody, isNull);
        expect(taskStatusUpdate.responseHeaders?.containsKey('content-length'),
            isTrue);
        expect(taskStatusUpdate.responseStatusCode, equals(200));
      }
    });

    testWidgets('Local storage for taskStatusUpdate - failed download',
        (widgetTester) async {
      if (Platform.isAndroid || Platform.isIOS) {
        final downloader = FileDownloader().downloaderForTesting;
        // force fail triggers local storage, but does not prevent
        // messages to be posted, so we can see the real value as well
        await downloader.setForceFailPostOnBackgroundChannel(true);
        task = DownloadTask(url: failingUrl, filename: defaultFilename);
        var taskStatusUpdate = await FileDownloader().download(task);
        expect(taskStatusUpdate.status, equals(TaskStatus.failed));
        var exception = taskStatusUpdate.exception as TaskHttpException;
        expect(exception.description, equals('Not authorized'));
        expect(exception.httpResponseCode, equals(403));
        expect(taskStatusUpdate.mimeType, isNull);
        expect(taskStatusUpdate.charSet, isNull);
        expect(taskStatusUpdate.responseBody, isNull);
        expect(taskStatusUpdate.responseHeaders, isNull);
        expect(taskStatusUpdate.responseStatusCode, isNull);
        // now get the locally stored taskStatus and check again
        taskStatusUpdate = TaskStatusUpdate(task, TaskStatus.canceled); // reset
        FileDownloader().registerCallbacks(
            taskStatusCallback: (update) => taskStatusUpdate = update);
        await Future.delayed(const Duration(milliseconds: 500));
        await downloader.retrieveLocallyStoredData(); // triggers status update
        downloader.retrievedLocallyStoredData = false; // reset for testing
        await Future.delayed(const Duration(milliseconds: 500));
        expect(taskStatusUpdate.status, equals(TaskStatus.failed));
        exception = taskStatusUpdate.exception as TaskHttpException;
        expect(exception.description, equals('Not authorized'));
        expect(exception.httpResponseCode, equals(403));
        expect(taskStatusUpdate.mimeType, isNull);
        expect(taskStatusUpdate.charSet, isNull);
        expect(taskStatusUpdate.responseBody, isNull);
        expect(taskStatusUpdate.responseHeaders, isNull);
        expect(taskStatusUpdate.responseStatusCode, isNull);
      }
    });
  });

  group('Notifications', () {
    // NOTE: notifications are difficult to test in an integration test, so
    // passing tests in this group is not sufficient evidence that they
    // are working properly
    testWidgets('NotificationConfig', (widgetTester) async {
      FileDownloader().configureNotification(
          running: const TaskNotification('Title', 'Body'));
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      task = DownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          updates: Updates.statusAndProgress,
          allowPause: true);
      expect(await FileDownloader().enqueue(task), equals(true));
      await statusCallbackCompleter.future;
    });

    testWidgets('openFile', (widgetTester) async {
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      var success = await FileDownloader().openFile(task: task);
      await Future.delayed(const Duration(seconds: 1));
      if (!Platform.isAndroid) {
        expect(success, isTrue);
        // change to a .txt file
        final filePath = await task.filePath();
        await File(filePath).rename(join(
            dirname(filePath), '${basenameWithoutExtension(filePath)}.txt'));
        task = task.copyWith(filename: 'google.txt');
        success = await FileDownloader().openFile(task: task);
        expect(success, isTrue);
        success =
            await FileDownloader().openFile(filePath: await task.filePath());
        expect(success, isTrue);
        // change to a non-existent file
        task = task.copyWith(filename: 'nonexistentFile.html');
        success = await FileDownloader().openFile(task: task);
        expect(success, isFalse);
        // change to a file without extension
        task = task.copyWith(filename: 'fileWithoutExtension with space');
        success = await FileDownloader().openFile(task: task);
        expect(success, isFalse);
      } else {
        expect(success, isFalse); // on Android cannot access docs dir
        // change to a .txt file
        final filePath = await task.filePath();
        await File(filePath).rename(join(
            dirname(filePath), '${basenameWithoutExtension(filePath)}.txt'));
        task = task.copyWith(filename: 'google.txt');
        final newFilename = await FileDownloader()
            .moveToSharedStorage(task, SharedStorage.external);
        print(newFilename);
        success = await FileDownloader().openFile(filePath: newFilename);
        expect(success, isTrue);
      }
    });
  });

  group('Directories', () {
    test('Print directory names', () async {
      print(
          'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
      task = task.copyWith(baseDirectory: BaseDirectory.applicationSupport);
      print(
          'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
      task = task.copyWith(baseDirectory: BaseDirectory.applicationLibrary);
      print(
          'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
      task = task.copyWith(baseDirectory: BaseDirectory.temporary);
      print(
          'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
      if (Platform.isAndroid) {
        print('Switching to Android external');
        Task.useExternalStorage = true;
        task = task.copyWith(baseDirectory: BaseDirectory.applicationDocuments);
        print(
            'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
        task = task.copyWith(baseDirectory: BaseDirectory.applicationSupport);
        print(
            'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
        task = task.copyWith(baseDirectory: BaseDirectory.applicationLibrary);
        print(
            'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
        task = task.copyWith(baseDirectory: BaseDirectory.temporary);
        print(
            'task.baseDirectory is ${task.baseDirectory} and path is ${await task.filePath()}');
        Task.useExternalStorage = false;
      }
    });

    testWidgets('Android external storage', (widgetTester) async {
      // configure use of external storage
      print(await FileDownloader().configure(
          androidConfig: (Config.useExternalStorage, Config.always)));
      var path = await task.filePath();
      await enqueueAndFileExists(path);
      expect(lastStatus, equals(TaskStatus.complete));
      // with subdirectory
      task = DownloadTask(
          url: workingUrl, directory: 'test', filename: defaultFilename);
      path = await task.filePath();
      await enqueueAndFileExists(path);
      // cache directory
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.temporary);
      path = await task.filePath();
      await enqueueAndFileExists(path);
      // applicationSupport directory
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.applicationSupport);
      path = await task.filePath();
      await enqueueAndFileExists(path);
      // applicationLibrary directory
      task = DownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.applicationLibrary);
      path = await task.filePath();
      await enqueueAndFileExists(path);
      // reset use of external storage
      print(await FileDownloader()
          .configure(androidConfig: (Config.useExternalStorage, Config.never)));
    });
  });

  group('Shared storage', () {
    test('move task to shared storage', () async {
      var filePath = await task.filePath();
      await FileDownloader().download(task);
      final path = await FileDownloader()
          .moveToSharedStorage(task, SharedStorage.downloads);
      print('Path in downloads is $path');
      expect(path, isNotNull);
      expect(File(filePath).existsSync(), isFalse);
      expect(File(path!).existsSync(), isTrue);
      File(path).deleteSync();
    });

    test('move task to shared storage with directory', () async {
      var filePath = await task.filePath();
      await FileDownloader().download(task);
      final path = await FileDownloader().moveToSharedStorage(
          task, SharedStorage.downloads,
          directory: 'subdirectory');
      print('Path in downloads is $path');
      expect(path, isNotNull);
      expect(File(filePath).existsSync(), isFalse);
      expect(File(path!).existsSync(), isTrue);
      File(path).deleteSync();
      expect(dirname(path).endsWith('subdirectory'), isTrue);
      Directory(dirname(path)).deleteSync();
    });

    test('[*] try to move text file to images -> error', () async {
      // Note: this test will fail on Android API below 30, as that API
      // does not have a problem storing a text file in images
      if (Platform.isAndroid) {
        var filePath = await task.filePath();
        await FileDownloader().download(task);
        final path = await FileDownloader()
            .moveToSharedStorage(task, SharedStorage.images);
        expect(path, isNull);
        expect(File(filePath).existsSync(), isTrue);
      }
    });

    test('move while overriding mime type', () async {
      if (Platform.isAndroid) {
        var filePath = await task.filePath();
        await FileDownloader().download(task);
        final path = await FileDownloader().moveToSharedStorage(
            task, SharedStorage.images,
            mimeType: 'image/jpeg');
        print('Path in downloads is $path');
        expect(path, isNotNull);
        expect(File(filePath).existsSync(), isFalse);
        expect(File(path!).existsSync(), isTrue);
        File(path).deleteSync();
      }
    });

    test('move file to shared storage - all types', () async {
      // test skips .images and .video for iOS as that blocks on permission
      final valuesToTest = Platform.isIOS
          ? SharedStorage.values.where((element) =>
              element != SharedStorage.video && element != SharedStorage.images)
          : SharedStorage.values;
      for (var destination in valuesToTest) {
        await FileDownloader().download(task);
        var filePath = await task.filePath();
        expect(File(filePath).existsSync(), isTrue);
        // rename the file extension to accommodate requirement for shared
        // storage (e.g. an .html file cannot be stored in 'images')
        switch (destination) {
          case SharedStorage.images:
            final newFilePath = filePath.replaceFirst('.html', '.jpg');
            await File(filePath).rename(newFilePath);
            filePath = newFilePath;
            break;
          case SharedStorage.video:
            final newFilePath = filePath.replaceFirst('.html', '.mp4');
            await File(filePath).rename(newFilePath);
            filePath = newFilePath;
            break;
          case SharedStorage.audio:
            final newFilePath = filePath.replaceFirst('.html', '.mp3');
            await File(filePath).rename(newFilePath);
            filePath = newFilePath;
            break;
          default:
            break;
        }
        final path = await FileDownloader()
            .moveFileToSharedStorage(filePath, destination);
        print('Path in shared storage for $destination is $path');
        if (Platform.isAndroid ||
            destination == SharedStorage.downloads ||
            (Platform.isIOS && destination == SharedStorage.audio)) {
          expect(path, isNotNull);
          expect(File(filePath).existsSync(), isFalse);
          expect(File(path!).existsSync(), isTrue);
          File(path).deleteSync();
        } else {
          // otherwise expect null
          expect(path, isNull);
          File(filePath).deleteSync();
        }
      }
    });

    testWidgets('path in shared storage', (widgetTester) async {
      await FileDownloader().download(task);
      final path = await FileDownloader()
          .moveToSharedStorage(task, SharedStorage.downloads);
      print('Path in downloads is $path');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      final filePath = await FileDownloader()
          .pathInSharedStorage(path, SharedStorage.downloads);
      expect(filePath, equals(path));
      File(path).deleteSync();
    });
  });

  group('Exception details', () {
    testWidgets('httpResponse: 403 downloadTask', (widgetTester) async {
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      task = DownloadTask(url: failingUrl, filename: 'test');
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      final exception = lastException!;
      expect(exception is TaskHttpException, isTrue);
      expect(exception.description, equals('Not authorized'));
      expect((exception as TaskHttpException).httpResponseCode, equals(403));
    });

    testWidgets('convenience download for httpResponse 403',
        (widgetTester) async {
      task = DownloadTask(url: failingUrl, filename: 'test');
      final result = await FileDownloader().download(task);
      final exception = result.exception!;
      expect(exception is TaskHttpException, isTrue);
      expect(exception.description, equals('Not authorized'));
      expect((exception as TaskHttpException).httpResponseCode, equals(403));
      expect(result.responseStatusCode, isNull);
    });

    testWidgets('fileSystem: File to upload does not exist',
        (widgetTester) async {
      if (!Platform.isIOS) {
        FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
        uploadTask = uploadTask.copyWith(filename: 'doesNotExist');
        expect(await FileDownloader().enqueue(uploadTask), isTrue);
        await statusCallbackCompleter.future;
        final exception = lastException!;
        expect(exception is TaskFileSystemException, isTrue);
        expect(
            exception.description.startsWith('File to upload does not exist'),
            isTrue);
      }
    });
  });

  group('Content-disposition', () {
    testWidgets('Various content-dispositions', (widgetTester) async {
      await deleteOld5MbDownloads();
      final downloader = FileDownloader().downloaderForTesting;
      final entries = {
        '': task.filename, // no last path segment in www.google.com
        'Attachment; filename=example.html': 'example.html',
        'INLINE; FILENAME= "an example.html"': 'an example.html',
        "attachment;filename*= UTF-8''%e2%82%ac%20rates": '\u20AC rates',
        "attachment;filename*= utf-8''%e2%82%ac%20rates": '\u20AC rates',
        'attachment;filename="EURO rates";filename*=utf-8\'\'%e2%82%ac%20rates':
            '\u20AC rates'
      };
      for (final s in entries.keys) {
        final r = await downloader.testSuggestedFilename(task, s);
        print('$s -> $r');
        expect(r, equals(entries[s]));
      }
      task =
          DownloadTask(url: urlWithContentLength); // has url last path segment
      expect(await downloader.testSuggestedFilename(task, ''),
          equals('5MB-test.ZIP'));
    });

    testWidgets('DownloadTask withSuggestedFilename', (widgetTester) async {
      await deleteOld5MbDownloads();
      task = DownloadTask(url: urlWithContentLength);
      final startingFileName = task.filename;
      final task2 = await task.withSuggestedFilename();
      expect(task2.filename, isNot(equals(startingFileName)));
      expect(task2.filename, equals('5MB-test.ZIP'));
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      expect(await FileDownloader().enqueue(task2), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      // again, should yield same filename
      final task3 = await task.withSuggestedFilename();
      expect(task3.filename, equals('5MB-test.ZIP'));
      // again with 'unique' should yield (1) filename
      final task4 = await task.withSuggestedFilename(unique: true);
      expect(task4.filename, equals('5MB-test (1).ZIP'));
      statusCallbackCompleter = Completer(); // reset
      expect(await FileDownloader().enqueue(task4), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      // again with 'unique' should yield (2) filename
      final task5 = await task.withSuggestedFilename(unique: true);
      expect(task5.filename, equals('5MB-test (2).ZIP'));
    });

    testWidgets('downloadTask with ? for filename', (widgetTester) async {
      await deleteOld5MbDownloads();
      task = DownloadTask(
          url: urlWithContentLength, filename: DownloadTask.suggestedFilename);
      final result = await FileDownloader().download(task);
      expect(result.task.filename, equals('5MB-test.ZIP'));
      final file = File(await result.task.filePath());
      expect(await file.exists(), isTrue);
      expect(await file.length(), equals(urlWithContentLengthFileSize));
      await file.delete();
    });

    testWidgets('parallelDownloadTask with ? for filename',
        (widgetTester) async {
      await deleteOld5MbDownloads();
      task = ParallelDownloadTask(
          url: urlWithContentLength, filename: DownloadTask.suggestedFilename);
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.task.filename, equals('5MB-test.ZIP'));
      expect(result.responseStatusCode, equals(200));
      final file = File(await result.task.filePath());
      expect(await file.exists(), isTrue);
      expect(await file.length(), equals(urlWithContentLengthFileSize));
      await file.delete();
    });

    test('uploads with different content-disposition headers', () async {
      final uploadTask = UploadTask(
          url: 'https://httpbin.org/post',
          filename: uploadFilename,
          post: 'binary');
      final cdMap = {
        // task.header presence/value and expected header sent
        null: 'attachment; filename="$uploadFilename"', // omitted (default)
        '': null, // explicitly set to no header
        'inline': 'inline' // specific header, copied
      };
      for (final entry in cdMap.entries) {
        final UploadTask myTask;
        if (entry.key != null) {
          myTask =
              uploadTask.copyWith(headers: {'Content-Disposition': entry.key!});
        } else {
          myTask = uploadTask;
        }
        final result = await FileDownloader().upload(myTask);
        expect(result.status, equals(TaskStatus.complete));
        expect(result.responseStatusCode, equals(200));
        final response = jsonDecode(result.responseBody!);
        final contentDisposition = response['headers']['Content-Disposition'];
        expect(contentDisposition, equals(entry.value));
      }
    });
  });

  group('Content-Type, mimeType and charSet', () {
    testWidgets('mimeType', (widgetTester) async {
      task = DownloadTask(url: urlWithContentLength);
      var result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.mimeType, equals('application/zip'));
      expect(result.charSet, isNull);
      task = ParallelDownloadTask(url: urlWithContentLength, chunks: 2);
      result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.mimeType, equals('application/zip'));
      expect(result.charSet, isNull);
    });

    testWidgets('mimeType and charSet', (widgetTester) async {
      task = DownloadTask(url: workingUrl);
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      expect(result.mimeType, equals('text/html'));
      expect(result.charSet, equals('ISO-8859-1'));
    });
  });

  group('Range and Content-Length headers', () {
    testWidgets('parseRange', (widgetTester) async {
      // tested on the native side for Android and iOS
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        expect(parseRange('bytes=10-20'), equals((10, 20)));
        expect(parseRange('bytes=-20'), equals((0, 20)));
        expect(parseRange('bytes=10-'), equals((10, null)));
        expect(parseRange(''), equals((0, null)));
      }
    });

    testWidgets('getContentLength', (widgetTester) async {
      // tested on the native side for Android and iOS
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        expect(getContentLength({}, task), equals(-1));
        expect(getContentLength({'Content-Length': '123'}, task), equals(123));
        expect(getContentLength({'content-length': '123'}, task), equals(123));
        task = task.copyWith(headers: {'Range': 'bytes=0-20'});
        expect(getContentLength({}, task), equals(21));
        task = task.copyWith(headers: {'Known-Content-Length': '456'});
        expect(getContentLength({}, task), equals(456));
        task = task.copyWith(
            headers: {'Range': 'bytes=0-20', 'Known-Content-Length': '456'});
        expect(getContentLength({}, task), equals(21));
        expect(getContentLength({'content-length': '123'}, task), equals(123));
      }
    });

    testWidgets('Range header in download request', (widgetTester) async {
      const rangeStart = 10;
      const rangeEnd = 1000000;
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      // full range
      task = task.copyWith(
          url: urlWithContentLength,
          headers: {'Range': 'bytes=$rangeStart-$rangeEnd'},
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastValidExpectedFileSize, equals(rangeEnd - rangeStart + 1));
      var file = File(await task.filePath());
      expect(file.lengthSync(), equals(lastValidExpectedFileSize));
      await file.delete();
      // reset and range without end
      statusCallbackCompleter = Completer();
      lastValidExpectedFileSize = -1;
      task = task.copyWith(headers: {'Range': 'bytes=$rangeStart-'});
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastValidExpectedFileSize,
          equals(urlWithContentLengthFileSize - rangeStart));
      file = File(await task.filePath());
      expect(file.lengthSync(), equals(lastValidExpectedFileSize));
      await file.delete();
      // reset and range without start
      statusCallbackCompleter = Completer();
      lastValidExpectedFileSize = -1;
      task = task.copyWith(headers: {'Range': 'bytes=-$rangeEnd'});
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastStatus, equals(TaskStatus.complete));
      expect(lastValidExpectedFileSize, equals(rangeEnd));
      file = File(await task.filePath());
      expect(file.lengthSync(), equals(lastValidExpectedFileSize));
      await file.delete();
    });

    testWidgets('DownloadTask expectedFileSize', (widgetTester) async {
      expect(await task.expectedFileSize(), equals(-1));
      task = task.copyWith(headers: {'Range': 'bytes=0-10'});
      expect(await task.expectedFileSize(), equals(11));
      task = task.copyWith(headers: {'Known-Content-Length': '100'});
      expect(await task.expectedFileSize(), equals(100));
      task = DownloadTask(url: urlWithContentLength);
      expect(
          await task.expectedFileSize(), equals(urlWithContentLengthFileSize));
    });

    testWidgets('[*] Range or Known-Content-Length in task header',
        (widgetTester) async {
      // Haven't found a url that does not provide content-length, so
      // can only be tested by modifying the source code to ignore the
      // Content-Length response header and use this one instead
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      // try with Range header
      task = task.copyWith(
          url: urlWithContentLength,
          headers: {'Range': 'bytes=0-${urlWithContentLengthFileSize - 1}'},
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastValidExpectedFileSize, equals(urlWithContentLengthFileSize));
      // try with Known-Content-Length header
      statusCallbackCompleter = Completer();
      lastValidExpectedFileSize = -1;
      task = task.copyWith(
          headers: {'Known-Content-Length': '$urlWithContentLengthFileSize'});
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(lastValidExpectedFileSize, equals(urlWithContentLengthFileSize));
    });
  });

  group('Cookies', () {
    testWidgets('cookie from live set-cookie response header',
        (widgetTester) async {
      final response = await FileDownloader().request(task);
      print(response.headers['set-cookie']);
      final cookies = Request.cookieHeader(response, task.url);
      expect(cookies['Cookie']?.startsWith('AEC'), isTrue);
    });
  });

  group('Priority and TaskQueue', () {
    testWidgets('High priority', (widgetTester) async {
      task = task.copyWith(priority: 0);
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
    });

    testWidgets('One high priority task among regular ones',
        (widgetTester) async {
      final tasks = <DownloadTask>[];
      for (var n = 1; n < 40; n++) {
        final downloadTask = DownloadTask(url: urlWithContentLength);
        print('Adding task with id ${downloadTask.taskId}');
        tasks.add(downloadTask);
      }
      final batchFuture = FileDownloader().downloadBatch(tasks);
      print('Wait a second after enqueuing all non-priority tasks');
      await Future.delayed(const Duration(milliseconds: 1000));
      var priorityTask = DownloadTask(url: urlWithContentLength, priority: 0);
      print('PriorityTask taskId = ${priorityTask.taskId}');
      final result = await FileDownloader().download(priorityTask);
      expect(result.status, equals(TaskStatus.complete));
      final endOfHighPriority = DateTime.now();
      print('High priority task finished, waiting for batch to finish');
      await batchFuture;
      print('Batch finished');
      final elapsedTime = DateTime.now().difference(endOfHighPriority);
      print('Elapsed time after high priority download = $elapsedTime');
      expect(elapsedTime.inMilliseconds, greaterThan(20));
    });

    testWidgets('TaskQueue', (widgetTester) async {
      final completer = Completer<bool>();
      final tasks = <Task>{};
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        if (update.status == TaskStatus.complete) {
          tasks.remove(update.task);
          if (tasks.isEmpty) {
            completer.complete(true);
          }
        } else if (update.status.isFinalState) {
          completer.complete(false); // error
        }
      });
      final tq = MemoryTaskQueue();
      tq.maxConcurrent = 2;
      FileDownloader().addTaskQueue(tq);
      for (var n = 0; n < 10; n++) {
        var downloadTask = DownloadTask(url: urlWithContentLength);
        tasks.add(downloadTask);
        tq.add(downloadTask);
      }
      expect(await completer.future, isTrue);
    });
  });

  group('HoldingQueue', () {
    testWidgets('multiple maxConcurrent combinations', (widgetTester) async {
      var start = DateTime.now();
      var concurrent = 0;
      var maxActual = 0;
      var finished = 0;

      // same callback used for group 0 and group 1
      void callBack(TaskStatusUpdate update) {
        if (update.status == TaskStatus.running) {
          concurrent++;
          print(
              'Started ${update.task.taskId} in group ${update.task.group}, $concurrent concurrent');
          maxActual = max(concurrent, maxActual);
        }
        if (update.status == TaskStatus.complete) {
          concurrent--;
          finished++;
          print('Finished ${update.task.taskId}, $concurrent concurrent');
        }
      }

      FileDownloader()
          .registerCallbacks(group: 'group 0', taskStatusCallback: callBack);
      FileDownloader()
          .registerCallbacks(group: 'group 1', taskStatusCallback: callBack);

      // test function: enqueues 10 times the same file from the same host, but
      // with alternating group "group 0" and "group 1", watches the concurrency
      // count and then waits for all downloads to complete
      Future<void> runTest() async {
        for (var n = 0; n < 10; n++) {
          var downloadTask = DownloadTask(
              url: urlWithContentLength,
              group: 'group ${n % 2}',
              priority: Random().nextInt(9));
          print(
              'Enqueuing ${downloadTask.taskId} with priority ${downloadTask.priority}');
          FileDownloader().enqueue(downloadTask);
        }
        while (finished < 10) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        print(
            'Completed in ${DateTime.now().difference(start)} and maxActual=$maxActual');
        finished = 0;
      }

      // baseline, unrestricted
      await runTest();
      expect(maxActual, greaterThan(3));
      // configure for maxConcurrent
      maxActual = 0;
      expect(
          (await FileDownloader().configure(
                  globalConfig: (Config.holdingQueue, (3, null, null))))
              .toString(),
          equals('[(holdingQueue, )]'));
      await runTest();
      expect(maxActual, lessThan(4));
      // configure for maxConcurrentByHost
      maxActual = 0;
      expect(
          (await FileDownloader().configure(
                  globalConfig: (Config.holdingQueue, (null, 3, null))))
              .toString(),
          equals('[(holdingQueue, )]'));
      await runTest();
      expect(maxActual, lessThan(4));
      // configure for maxConcurrentByGroup. There are two groups, so now we can
      // get up to 6 maxConcurrent (3 for each group)
      maxActual = 0;
      expect(
          (await FileDownloader().configure(
                  globalConfig: (Config.holdingQueue, (null, null, 3))))
              .toString(),
          equals('[(holdingQueue, )]'));
      await runTest();
      expect(maxActual, greaterThan(3));
      expect(maxActual, lessThan(7));
    });

    test('holdingQueue allTaskIds and allTasks', () async {
      expect(
          (await FileDownloader().configure(
                  globalConfig: (Config.holdingQueue, (1, null, null))))
              .toString(),
          equals('[(holdingQueue, )]'));
      final taskIds = <String>[];
      for (var n = 0; n < 10; n++) {
        var downloadTask = DownloadTask(url: urlWithContentLength);
        taskIds.add(downloadTask.taskId);
        print('Enqueuing ${downloadTask.taskId}');
        FileDownloader().enqueue(downloadTask);
      }
      await Future.delayed(const Duration(milliseconds: 100));
      expect((await FileDownloader().allTaskIds()).length, equals(10));
      expect((await FileDownloader().allTasks()).length, equals(10));
      expect(await FileDownloader().allTaskIds(group: 'non-existent'), isEmpty);
    });

    test('holdingQueue cancel tasks', () async {
      expect(
          (await FileDownloader().configure(
                  globalConfig: (Config.holdingQueue, (1, null, null))))
              .toString(),
          equals('[(holdingQueue, )]'));
      var cancelCount = 0;
      var completeCount = 0;
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        if (update.status == TaskStatus.canceled) cancelCount++;
        if (update.status == TaskStatus.complete) completeCount++;
      });
      final taskIds = <String>[];
      for (var n = 0; n < 10; n++) {
        var downloadTask = DownloadTask(url: urlWithContentLength);
        taskIds.add(downloadTask.taskId);
        print('Enqueuing ${downloadTask.taskId}');
        FileDownloader().enqueue(downloadTask);
      }
      await Future.delayed(const Duration(milliseconds: 200));
      expect(await FileDownloader().cancelTasksWithIds(taskIds), isTrue);
      await Future.delayed(const Duration(milliseconds: 1500));
      expect(await FileDownloader().allTaskIds(), isEmpty);
      expect(cancelCount, greaterThan(2));
      expect(cancelCount + completeCount, equals(10));
    });

    test('holdingQueue enqueue', () async {
      expect(
          (await FileDownloader().configure(
                  globalConfig: (Config.holdingQueue, (1, null, null))))
              .toString(),
          equals('[(holdingQueue, )]'));
      var enqueueCount = 0;
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        if (update.status == TaskStatus.enqueued) enqueueCount++;
      });
      for (var n = 0; n < 10; n++) {
        var downloadTask = DownloadTask(url: urlWithContentLength);
        FileDownloader().enqueue(downloadTask);
      }
      await Future.delayed(const Duration(seconds: 1));
      expect(enqueueCount, equals(10));
    });
  });

  group('Task functions', () {
    test('baseDirectoryPath', () async {
      for (final baseDirectoryEnum in BaseDirectory.values) {
        final subdirName =
            (Platform.isWindows && baseDirectoryEnum == BaseDirectory.root)
                ? 'C:\\'
                : '';
        final task = DownloadTask(
            url: workingUrl,
            baseDirectory: baseDirectoryEnum,
            directory: subdirName);
        final path = await task.filePath();
        final dir = dirname(path);
        print('For $baseDirectoryEnum the dir is $dir');
        if (Platform.isWindows && baseDirectoryEnum == BaseDirectory.root) {
          expect(dir, equals('C:\\'));
        } else {
          expect(await Task.baseDirectoryPath(baseDirectoryEnum), equals(dir));
        }
      }
    });

    test('split with filePath parameter', () async {
      for (final subdirName in ['something', '']) {
        for (final baseDirectoryEnum in BaseDirectory.values) {
          final modifiedSubdirName =
              (Platform.isWindows && baseDirectoryEnum == BaseDirectory.root)
                  ? 'C:\\$subdirName'
                  : subdirName;
          final task = DownloadTask(
              url: workingUrl,
              baseDirectory: baseDirectoryEnum,
              directory: modifiedSubdirName);
          final path = await task.filePath();
          print('Testing path $path');
          final (baseDirectory, directory, filename) =
              await Task.split(filePath: path);
          expect(baseDirectory, equals(baseDirectoryEnum));
          expect(directory, equals(subdirName));
          expect(filename, equals(task.filename));
        }
      }
    });

    test('split with File parameter', () async {
      for (final subdirName in ['something', '']) {
        for (final baseDirectoryEnum in BaseDirectory.values) {
          final modifiedSubdirName =
              (Platform.isWindows && baseDirectoryEnum == BaseDirectory.root)
                  ? 'C:\\$subdirName'
                  : subdirName;
          final task = DownloadTask(
              url: workingUrl,
              baseDirectory: baseDirectoryEnum,
              directory: modifiedSubdirName);
          final path = await task.filePath();
          print('Testing path $path');
          final (baseDirectory, directory, filename) =
              await Task.split(file: File(path));
          expect(baseDirectory, equals(baseDirectoryEnum));
          expect(directory, equals(subdirName));
          expect(filename, equals(task.filename));
        }
      }
    });
  });

  group('FilePath', () {
    late String tempBasePath;

    setUp(() async {
      // Create temporary directories for testing
      final tempDir = await Directory.systemTemp.createTemp('upload_test_');
      tempBasePath = tempDir.path;
    });

    tearDown(() async {
      // Clean up the temporary directory after tests
      Directory(tempBasePath).deleteSync(recursive: true);
    });

    test(
        'returns correct path for single upload task with default filename in applicationDocuments',
        () async {
      final task = DownloadTask(
          url: workingUrl,
          filename: 'test.txt',
          directory: 'uploads',
          baseDirectory: BaseDirectory.applicationDocuments);
      final path = await task.filePath();
      final expectedPath = join(
          await Task.baseDirectoryPath(BaseDirectory.applicationDocuments),
          'uploads',
          'test.txt');
      expect(path, expectedPath);
    });

    test(
        'returns correct path for single upload task with custom filename in temporary',
        () async {
      final task = UploadTask(
          url: workingUrl,
          filename: 'test.txt',
          directory: 'uploads',
          baseDirectory: BaseDirectory.temporary);
      final path = await task.filePath(withFilename: 'custom.txt');
      final expectedPath = join(
          await Task.baseDirectoryPath(BaseDirectory.temporary),
          'uploads',
          'custom.txt');
      expect(path, expectedPath);
    });

    test(
        'returns correct path for single upload task with default filename in applicationSupport',
        () async {
      final task = DownloadTask(
          url: workingUrl,
          filename: 'test.txt',
          baseDirectory: BaseDirectory.applicationSupport);
      final path = await task.filePath();
      final expectedPath = join(
          await Task.baseDirectoryPath(BaseDirectory.applicationSupport),
          'test.txt');
      expect(path, expectedPath);
    });

    test(
        'returns correct path for single upload task with custom filename in applicationLibrary',
        () async {
      final task = DownloadTask(
          url: workingUrl,
          filename: 'test.txt',
          baseDirectory: BaseDirectory.applicationLibrary);
      final path = await task.filePath(withFilename: 'custom.txt');
      final expectedPath = join(
          await Task.baseDirectoryPath(BaseDirectory.applicationLibrary),
          'custom.txt');
      expect(path, expectedPath);
    });

    test(
        'returns empty string for multi upload task without custom filename in temporary',
        () async {
      final task = MultiUploadTask(
          url: workingUrl,
          files: ['a.text'],
          directory: 'uploads',
          baseDirectory: BaseDirectory.temporary);
      final path = await task.filePath();
      expect(path, '');
    });

    test(
        'returns correct path for multi upload task with custom filename in applicationDocuments',
        () async {
      final task = MultiUploadTask(
          url: workingUrl,
          files: ['a.text'],
          directory: 'uploads',
          baseDirectory: BaseDirectory.applicationDocuments);
      final path = await task.filePath(withFilename: 'custom.txt');
      final expectedPath = join(
          await Task.baseDirectoryPath(BaseDirectory.applicationDocuments),
          'uploads',
          'custom.txt');
      expect(path, expectedPath);
    });

    test('returns correct file path for task using file URI', () async {
      final task =
          UriUploadTask(url: workingUrl, fileUri: Uri.file('/my/file/uri.txt'));
      final path = await task.filePath();
      expect(path, '/my/file/uri.txt');
    });

    test('returns correct file path for UriUploadTask with URI and filename',
        () async {
      final uri = Uri.file('/my/file/uri.txt');
      final task = UriUploadTask(
          url: workingUrl, fileUri: uri, filename: uploadFilename);
      final path = await task.filePath();
      expect(path, '/my/file/uri.txt');
      expect(task.filename, equals(uploadFilename));
      expect(task.fileUri, equals(uri));
      expect(task.directoryUri, isNull);
    });

    test('returns correct file path for UriDownloadTask with URI and filename',
        () async {
      final uri = Uri.file('/my/directory');
      final task = UriDownloadTask(
          url: workingUrl, directoryUri: uri, filename: 'testFilename.txt');
      expect(task.directoryUri?.scheme, equals('file'));
      final path = await task.filePath();
      expect(path, '/my/directory/testFilename.txt');
      expect(task.directoryUri, equals(uri));
      expect(task.fileUri!.toFilePath(windows: Platform.isWindows),
          equals('/my/directory/testFilename.txt'));
    });

    test('throws assertion error for task using non-file URI', () async {
      final task = UriUploadTask(
          url: workingUrl, fileUri: Uri.parse('content://example.com'));
      expect(() async => await task.filePath(), throwsA(isA<AssertionError>()));
    });

    test('returns correct path for task using root directory', () async {
      final task = DownloadTask(
          url: workingUrl,
          filename: 'test.txt',
          directory: 'uploads',
          baseDirectory: BaseDirectory.root);
      final path = await task.filePath();
      expect(path, join(separator, 'uploads', 'test.txt'));
    });
  });

  group('DataTask', () {
    test('dataTask get', () async {
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
      });
      final t = DataTask(url: dataTaskGetUrl, headers: dataTaskHeaders);
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(lastUpdate.status, equals(TaskStatus.complete));
      final json = jsonDecode(lastUpdate.responseBody!);
      final args = json['args'] as Map<String, dynamic>;
      expect(args.isEmpty, isTrue);
      expect(json['headers']['Accept'], equals('application/json'));
    });

    test('dataTask post no data', () async {
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
      });
      final t = DataTask(
          url: dataTaskPostUrl,
          headers: dataTaskHeaders); // without 'POST' will fail
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 1));
      expect(lastUpdate.status, equals(TaskStatus.failed));
      final t2 = DataTask(
          url: dataTaskPostUrl,
          headers: dataTaskHeaders,
          httpRequestMethod: 'POST'); // with 'POST' will succeed
      expect(await FileDownloader().enqueue(t2), isTrue);
      await Future.delayed(const Duration(seconds: 1));
      expect(lastUpdate.status, equals(TaskStatus.complete));
      print(lastUpdate.responseBody);
      final json = jsonDecode(lastUpdate.responseBody!);
      final args = json['args'] as Map<String, dynamic>;
      expect(args.isEmpty, isTrue);
      expect(json['headers']['Accept'], equals('application/json'));
      expect((json['data'] as String).isEmpty, isTrue);
    });

    test('dataTask post with data', () async {
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
      });
      final t = DataTask(
          url: dataTaskPostUrl,
          headers: dataTaskHeaders,
          post: 'My data'); // should auto set 'POST' method
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 1));
      print(lastUpdate.responseStatusCode);
      expect(lastUpdate.status, equals(TaskStatus.complete));
      print(lastUpdate.responseBody);
      final json = jsonDecode(lastUpdate.responseBody!);
      final args = json['args'] as Map<String, dynamic>;
      expect(args.isEmpty, isTrue);
      expect(json['headers']['Accept'], equals('application/json'));
      expect((json['data'] as String), equals('My data'));
    });

    test('dataTask post with json data', () async {
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
      });
      var jsonData = {'key': 'value'};
      final t = DataTask(
          url: dataTaskPostUrl, headers: dataTaskHeaders, json: jsonData);
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 1));
      print(lastUpdate.responseStatusCode);
      expect(lastUpdate.status, equals(TaskStatus.complete));
      print(lastUpdate.responseBody);
      final json = jsonDecode(lastUpdate.responseBody!);
      final args = json['args'] as Map<String, dynamic>;
      expect(args.isEmpty, isTrue);
      expect(json['headers']['Accept'], equals('application/json'));
      expect((json['data'] as String), equals("{\"key\":\"value\"}"));
      expect((json['json'] as Map<String, dynamic>), equals(jsonData));
    });

    test('dataTask with error', () async {
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
      });
      final t = DataTask(
          url: 'https://httpbin.org/status/400', // force 400 code
          headers: dataTaskHeaders);
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 2));
      expect(lastUpdate.status, equals(TaskStatus.failed));
      final exception = lastUpdate.exception!;
      print(exception);
      expect(exception is TaskHttpException, isTrue);
      expect(exception.description.toUpperCase(), equals('BAD REQUEST'));
      expect((exception as TaskHttpException).httpResponseCode, equals(400));
    });

    test('dataTask with retries', () async {
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      var retryCount = 0;
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
        if (update.status == TaskStatus.waitingToRetry) {
          retryCount++;
        }
      });
      final t = DataTask(
          url: 'https://httpbin.org/status/400', // force 400 code
          headers: dataTaskHeaders,
          retries: 2);
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 10));
      expect(lastUpdate.status, equals(TaskStatus.failed));
      expect(lastUpdate.task.retries, equals(2));
      expect(lastUpdate.task.retriesRemaining, equals(0));
      expect(retryCount, equals(2));
    });

    test('cancel dataTask', () async {
      /// Cancellation is only relevant when the task is waiting to retry.
      /// Cancellation of a running DataTask has no effect
      var lastUpdate = TaskStatusUpdate(task, TaskStatus.paused);
      FileDownloader().registerCallbacks(taskStatusCallback: (update) {
        lastUpdate = update;
        if (update.status == TaskStatus.waitingToRetry) {
          // cancel with some delay (otherwise the waitingToRetry status has
          // not been registered yet)
          Future.delayed(
              const Duration(milliseconds: 500),
              () => FileDownloader()
                  .cancelTaskWithId(update.task.taskId)
                  .then((success) => expect(success, isTrue)));
        }
      });
      final t = DataTask(
          url: 'https://httpbin.org/status/400', // force 400 code
          headers: dataTaskHeaders,
          retries: 2);
      expect(await FileDownloader().enqueue(t), isTrue);
      await Future.delayed(const Duration(seconds: 3));
      expect(lastUpdate.status, equals(TaskStatus.canceled));
      expect(lastUpdate.task.retriesRemaining, greaterThan(0));
    });

    test('transmit (wait for completion)', () async {
      final t = DataTask(url: dataTaskGetUrl, headers: dataTaskHeaders);
      final result = await FileDownloader().transmit(t);
      expect(result.status, equals(TaskStatus.complete));
      final json = jsonDecode(result.responseBody!);
      final args = json['args'] as Map<String, dynamic>;
      expect(args.isEmpty, isTrue);
      expect(json['headers']['Accept'], equals('application/json'));
    });
  });
}

Future<void> deleteOld5MbDownloads() async {
  var t = DownloadTask(url: urlWithContentLength, filename: '5MB-test.ZIP');
  try {
    File(await t.filePath()).deleteSync();
  } catch (e) {}
  t = DownloadTask(url: urlWithContentLength, filename: '5MB-test (1).ZIP');
  try {
    File(await t.filePath()).deleteSync();
  } catch (e) {}
  t = DownloadTask(url: urlWithContentLength, filename: '5MB-test (2).ZIP');
  try {
    File(await t.filePath()).deleteSync();
  } catch (e) {}
}

/// Helper: make sure [task] is set as desired, and this will enqueue, wait for
/// complete, and return true if file is at the desired [path]
Future<void> enqueueAndFileExists(String path) async {
  print('enqueueAndFileExists with path $path');
  statusCallbackCounter = 0;
  statusCallbackCompleter = Completer();
  FileDownloader().destroy();
  FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
  try {
    File(path).deleteSync();
  } on FileSystemException {}
  expect(await FileDownloader().enqueue(task), isTrue);
  await statusCallbackCompleter.future;
  expect(File(path).existsSync(), isTrue);
  print('Found file at $path');
  try {
    File(path).deleteSync();
  } on FileSystemException {}
  // Expect 3 status callbacks: enqueued + running + complete
  expect(statusCallbackCounter, equals(3));
}
