// ignore_for_file: avoid_print, empty_catches

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

const def = 'default';
var downloadStatusCallbackCounter = 0;
var downloadProgressCallbackCounter = 0;

var downloadStatusCallbackCompleter = Completer<void>();
var downloadProgressCallbackCompleter = Completer<void>();
var lastDownloadStatus = DownloadTaskStatus.enqueued;
var lastDownloadProgress = -100.0;

const workingUrl = 'https://google.com';
const failingUrl = 'https://avmaps-dot-bbflightserver-hrd.appspot'
    '.com/public/get_current_app_data';
const urlWithContentLength = 'https://storage.googleapis'
    '.com/approachcharts/test/5MB-test.ZIP';

const defaultFilename = 'google.html';

var task = BackgroundDownloadTask(url: workingUrl, filename: defaultFilename);

var retryTask = BackgroundDownloadTask(
    url: failingUrl, filename: defaultFilename, retries: 3);

void downloadStatusCallback(
    BackgroundDownloadTask task, DownloadTaskStatus status) {
  print('downloadStatusCallback for $task with status $status');
  lastDownloadStatus = status;
  downloadStatusCallbackCounter++;
  if (!downloadStatusCallbackCompleter.isCompleted && status.isFinalState) {
    downloadStatusCallbackCompleter.complete();
  }
}

void downloadProgressCallback(BackgroundDownloadTask task, double progress) {
  print('downloadProgressCallback for $task with progress $progress');
  lastDownloadProgress = progress;
  downloadProgressCallbackCounter++;
  if (!downloadProgressCallbackCompleter.isCompleted &&
      (progress < 0 || progress == 1)) {
    downloadProgressCallbackCompleter.complete();
  }
}

void main() {
  setUp(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    });
    task = BackgroundDownloadTask(url: workingUrl, filename: defaultFilename);
    downloadStatusCallbackCounter = 0;
    downloadProgressCallbackCounter = 0;
    downloadStatusCallbackCompleter = Completer<void>();
    downloadProgressCallbackCompleter = Completer<void>();
    lastDownloadStatus = DownloadTaskStatus.enqueued;
    FileDownloader.destroy();
    final path =
        join((await getApplicationDocumentsDirectory()).path, task.filename);
    try {
      File(path).deleteSync(recursive: true);
    } on FileSystemException {}
  });

  tearDown(() async {
    FileDownloader.destroy();
  });

  group('Initialization', () {
    test('initialize', () {
      // confirm asserts work
      expect(() => FileDownloader.registerCallbacks(), throwsAssertionError);
      expect(() => FileDownloader.enqueue(task), throwsAssertionError);
      expect(() => FileDownloader.allTaskIds(), throwsAssertionError);
      expect(() => FileDownloader.allTasks(), throwsAssertionError);
      expect(() => FileDownloader.reset(), throwsAssertionError);
      // now initialize
      FileDownloader.initialize();
      expect(FileDownloader.statusCallbacks, isEmpty);
      expect(FileDownloader.progressCallbacks, isEmpty);
      expect(FileDownloader.initialized, isTrue);
    });

    test('registerCallbacks', () {
      FileDownloader.initialize();
      expect(() => FileDownloader.registerCallbacks(), throwsAssertionError);
      FileDownloader.registerCallbacks(
          downloadStatusCallback: downloadStatusCallback);
      expect(
          FileDownloader.statusCallbacks[def], equals(downloadStatusCallback));
      FileDownloader.registerCallbacks(
          group: 'test', downloadProgressCallback: downloadProgressCallback);
      expect(FileDownloader.progressCallbacks['test'],
          equals(downloadProgressCallback));
    });
  });

  group('Enqueuing tasks', () {
    testWidgets('enqueue', (tester) async {
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      await enqueueAndFileExists(path);
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
      // with subdirectory
      task = BackgroundDownloadTask(
          url: workingUrl, directory: 'test', filename: defaultFilename);
      path = join((await getApplicationDocumentsDirectory()).path, 'test',
          task.filename);
      await enqueueAndFileExists(path);
      // cache directory
      task = BackgroundDownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.temporary);
      path = join((await getTemporaryDirectory()).path, task.filename);
      await enqueueAndFileExists(path);
      // cache directory
      task = BackgroundDownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          baseDirectory: BaseDirectory.applicationSupport);
      if (!Platform.isAndroid) {
        path = join((await getLibraryDirectory()).path, task.filename);
        await enqueueAndFileExists(path);
      }
      print('Finished enqueue');
    });

    testWidgets('enqueue with progress', (widgetTester) async {
      FileDownloader.initialize(
          downloadStatusCallback: downloadStatusCallback,
          downloadProgressCallback: downloadProgressCallback);
      expect(await FileDownloader.enqueue(task), isTrue);
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      // because we have not set progressUpdates to something that provides
      // progress updates, we should just get no updates
      expect(downloadProgressCallbackCompleter.isCompleted, isFalse);
      expect(downloadProgressCallbackCounter, equals(0));
      downloadStatusCallbackCounter = 0;
      downloadStatusCallbackCompleter = Completer();
      task = BackgroundDownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          progressUpdates:
              DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
      expect(await FileDownloader.enqueue(task), isTrue);
      await downloadProgressCallbackCompleter.future;
      // because google.com has no content-length, we only expect the 1.0 progress update
      expect(downloadProgressCallbackCounter, equals(1));
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      // now try a file that has content length
      downloadStatusCallbackCounter = 0;
      downloadProgressCallbackCounter = 0;
      downloadStatusCallbackCompleter = Completer<void>();
      downloadProgressCallbackCompleter = Completer<void>();
      task = BackgroundDownloadTask(
          url: urlWithContentLength,
          filename: defaultFilename,
          progressUpdates:
              DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
      expect(await FileDownloader.enqueue(task), isTrue);
      await downloadProgressCallbackCompleter.future;
      expect(downloadProgressCallbackCounter, greaterThan(1));
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      print('Finished enqueue with progress');
    });

    testWidgets('enqueue with non-default group callbacks',
        (widgetTester) async {
      FileDownloader.initialize(
          group: 'test', downloadStatusCallback: downloadStatusCallback);
      // enqueue task with 'default' group, so no status updates should come
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      try {
        File(path).deleteSync(recursive: true);
      } on FileSystemException {}
      expect(await FileDownloader.enqueue(task), isTrue);
      await Future.delayed(const Duration(seconds: 3)); // can't know for sure!
      expect(File(path).existsSync(), isTrue); // file still downloads
      expect(downloadStatusCallbackCompleter.isCompleted, isFalse);
      expect(downloadStatusCallbackCounter, equals(0));
      print('Finished enqueue with non-default group callbacks');
    });

    testWidgets('enqueue with event listener for status updates',
        (widgetTester) async {
      FileDownloader.initialize();
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      try {
        File(path).deleteSync(recursive: true);
      } on FileSystemException {}
      expect(await FileDownloader.enqueue(task), isTrue);
      await Future.delayed(const Duration(seconds: 3)); // can't know for sure!
      expect(File(path).existsSync(), isTrue); // file still downloads
      try {
        File(path).deleteSync(recursive: true);
      } on FileSystemException {}
      print(
          'Check log output -> should have warned that there is no callback or listener');
      // Register listener. For testing convenience, we simply route the event
      // to the completer function we have defined
      final subscription = FileDownloader.updates.listen((event) {
        if (event is BackgroundDownloadStatusEvent) {
          downloadStatusCallback(event.task, event.status);
        }
      });
      expect(await FileDownloader.enqueue(task), isTrue);
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
      expect(File(path).existsSync(), isTrue);
      subscription.cancel();
    });

    testWidgets('enqueue with event listener and callback for status updates',
        (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      // Register listener. Because we also have a callback registered, no
      // events should be received
      bool receivedEvent = false;
      final subscription = FileDownloader.updates.listen((event) {
        receivedEvent = true;
      });
      expect(await FileDownloader.enqueue(task), isTrue);
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
      expect(File(path).existsSync(), isTrue);
      expect(receivedEvent, isFalse);
      subscription.cancel();
    });

    testWidgets('enqueue with event listener for progress updates',
        (widgetTester) async {
      task = BackgroundDownloadTask(
          url:
              'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
          filename: defaultFilename,
          progressUpdates: DownloadTaskProgressUpdates.progressUpdates);
      FileDownloader.initialize();
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      // Register listener. For testing convenience, we simply route the event
      // to the completer function we have defined
      final subscription = FileDownloader.updates.listen((event) {
        expect(event is BackgroundDownloadProgressEvent, isTrue);
        if (event is BackgroundDownloadProgressEvent) {
          downloadProgressCallback(event.task, event.progress);
        }
      });
      expect(await FileDownloader.enqueue(task), isTrue);
      await downloadProgressCallbackCompleter.future;
      expect(downloadProgressCallbackCounter, greaterThan(1));
      expect(File(path).existsSync(), isTrue);
      subscription.cancel();
    });
  });

  group('Queue and task management', () {
    testWidgets('reset', (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(task), isTrue);
      expect(await FileDownloader.reset(group: 'non-default'), equals(0));
      expect(await FileDownloader.reset(), equals(1));
      await downloadStatusCallbackCompleter.future;
      // on iOS, the quick cancellation may not yield a 'running' state
      expect(downloadStatusCallbackCounter, lessThanOrEqualTo(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.canceled));
      print('Finished reset');
    });

    testWidgets('allTaskIds', (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(task), isTrue);
      expect(await FileDownloader.allTaskIds(group: 'non-default'), isEmpty);
      expect((await FileDownloader.allTaskIds()).length, equals(1));
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
      print('Finished alTaskIds');
    });

    testWidgets('allTasks', (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(task), isTrue);
      expect(await FileDownloader.allTasks(group: 'non-default'), isEmpty);
      final tasks = await FileDownloader.allTasks();
      expect(tasks.length, equals(1));
      expect(tasks.first, equals(task));
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
      print('Finished alTasks');
    });

    testWidgets('cancelTasksWithIds', (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(task), isTrue);
      var taskIds = await FileDownloader.allTaskIds();
      expect(taskIds.length, equals(1));
      expect(taskIds.first, equals(task.taskId));
      expect(await FileDownloader.cancelTasksWithIds(taskIds), isTrue);
      await downloadStatusCallbackCompleter.future;
      // on iOS, the quick cancellation may not yield a 'running' state
      expect(downloadStatusCallbackCounter, lessThanOrEqualTo(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.canceled));
      print('Finished cancelTasksWithIds');
    });

    testWidgets('taskForId', (widgetTester) async {
      final complexTask = BackgroundDownloadTask(
          url: workingUrl,
          filename: defaultFilename,
          headers: {'Auth': 'Test'},
          directory: 'directory',
          metaData: 'someMetaData');
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.taskForId('something'), isNull);
      expect(await FileDownloader.enqueue(complexTask), isTrue);
      expect(await FileDownloader.taskForId('something'), isNull);
      expect(await FileDownloader.taskForId(complexTask.taskId),
          equals(complexTask));
      await downloadStatusCallbackCompleter.future;
      expect(downloadStatusCallbackCounter, equals(3));
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
      print('Finished taskForId');
    });

    testWidgets('Task to and from Json', (widgetTester) async {
      final complexTask = BackgroundDownloadTask(
          taskId: 'uniqueId',
          url: workingUrl,
          filename: defaultFilename,
          headers: {'Auth': 'Test'},
          directory: 'directory',
          baseDirectory: BaseDirectory.temporary,
          group: 'someGroup',
          progressUpdates:
              DownloadTaskProgressUpdates.statusChangeAndProgressUpdates,
          requiresWiFi: true,
          retries: 5,
          metaData: 'someMetaData');
      FileDownloader.initialize(
          group: complexTask.group,
          downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.taskForId(complexTask.taskId), isNull);
      expect(await FileDownloader.enqueue(complexTask), isTrue);
      final task = await FileDownloader.taskForId(complexTask.taskId);
      expect(task, equals(complexTask));
      if (task != null) {
        expect(task.taskId, equals(complexTask.taskId));
        expect(task.url, equals(complexTask.url));
        expect(task.filename, equals(complexTask.filename));
        expect(task.headers, equals(complexTask.headers));
        expect(task.directory, equals(complexTask.directory));
        expect(task.baseDirectory, equals(complexTask.baseDirectory));
        expect(task.group, equals(complexTask.group));
        expect(task.progressUpdates, equals(complexTask.progressUpdates));
        expect(task.requiresWiFi, equals(complexTask.requiresWiFi));
        expect(task.retries, equals(complexTask.retries));
        expect(task.retriesRemaining, equals(complexTask.retriesRemaining));
        expect(task.retriesRemaining, equals(task.retries));
        expect(task.metaData, equals(complexTask.metaData));
      }
      await downloadStatusCallbackCompleter.future;
      expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
    });
  });

  group('Convenience downloads', () {
    testWidgets('download with await', (widgetTester) async {
      FileDownloader.initialize();
      var path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      var exists = await File(path).exists();
      if (exists) {
        await File(path).delete();
      }
      final status = await FileDownloader.download(task);
      expect(status, equals(DownloadTaskStatus.complete));
      exists = await File(path).exists();
      expect(exists, isTrue);
      await File(path).delete();
    });

    testWidgets('multiple download with futures', (widgetTester) async {
      FileDownloader.initialize();
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
      // var result = await FileDownloader.download(task);
      final taskFuture = FileDownloader.download(task);
      final secondTaskFuture = FileDownloader.download(secondTask);
      var statuses = await Future.wait([taskFuture, secondTaskFuture]);
      for (var status in statuses) {
        expect(status, equals(DownloadTaskStatus.complete));
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

    testWidgets('Batch download', (widgetTester) async {
      FileDownloader.initialize();
      final tasks = <BackgroundDownloadTask>[];
      final docDir = (await getApplicationDocumentsDirectory()).path;
      for (int n = 0; n < 3; n++) {
        final filename = 'google$n.html';
        final filepath = join(docDir, filename);
        if (File(filepath).existsSync()) {
          File(filepath).deleteSync();
        }
        // only task with n==1 will fail
        tasks.add(n != 1
            ? BackgroundDownloadTask(url: workingUrl, filename: filename)
            : BackgroundDownloadTask(url: failingUrl, filename: filename));
      }
      final result = await FileDownloader.downloadBatch(tasks);
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

    testWidgets('Batch download with callback', (widgetTester) async {
      FileDownloader.initialize();
      final tasks = <BackgroundDownloadTask>[];
      final docDir = (await getApplicationDocumentsDirectory()).path;
      for (int n = 0; n < 3; n++) {
        final filename = 'google$n.html';
        final filepath = join(docDir, filename);
        if (File(filepath).existsSync()) {
          File(filepath).deleteSync();
        }
        // only task with n==1 will fail
        tasks.add(n != 1
            ? BackgroundDownloadTask(url: workingUrl, filename: filename)
            : BackgroundDownloadTask(url: failingUrl, filename: filename));
      }
      var numSucceeded = 0;
      var numFailed = 0;
      var numcalled = 0;
      await FileDownloader.downloadBatch(tasks, (succeeded, failed) {
        print('Succeeded: $succeeded, failed: $failed');
        numcalled++;
        numSucceeded = succeeded;
        numFailed = failed;
      });
      expect(numcalled, equals(4)); // also called with 0, 0 at start
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
  });

  group('Retries', () {
    testWidgets('Basic retry logic', (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(retryTask.retriesRemaining, equals(retryTask.retries));
      expect(await FileDownloader.enqueue(retryTask), isTrue);
      await Future.delayed(const Duration(seconds: 4));
      final retriedTask = await FileDownloader.taskForId(retryTask.taskId);
      expect(retriedTask, equals(retryTask));
      if (retriedTask != null) {
        expect(retriedTask.retriesRemaining, lessThan(retriedTask.retries));
      }
      await downloadStatusCallbackCompleter.future;
      expect(lastDownloadStatus, equals(DownloadTaskStatus.failed));
      // enqueued, running, waitingToRetry/failed for each try
      expect(
          downloadStatusCallbackCounter, equals((retryTask.retries + 1) * 3));
    });

    testWidgets('Basic with progress updates', (widgetTester) async {
      FileDownloader.initialize(
          downloadStatusCallback: downloadStatusCallback,
          downloadProgressCallback: downloadProgressCallback);
      final retryTaskWithProgress = retryTask.copyWith(
          progressUpdates:
              DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
      expect(await FileDownloader.enqueue(retryTaskWithProgress), isTrue);
      await Future.delayed(const Duration(seconds: 4));
      expect(lastDownloadProgress, equals(progressWaitingToRetry));
      // iOS emits a 0.999 progress update for a 403 response with the
      // text of the response, before sharing the response code, triggering
      // the -4.0 progress response.
      // On Android, no progress is emitted other than the -4.0
      expect(
          downloadProgressCallbackCounter, equals(Platform.isAndroid ? 2 : 4));
      await downloadStatusCallbackCompleter.future;
      expect(lastDownloadStatus, equals(DownloadTaskStatus.failed));
      // wait a sec for the last progress update
      await Future.delayed(const Duration(seconds: 1));
      expect(lastDownloadProgress, equals(progressFailed));
    });

    testWidgets('Retry with cancellation', (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(retryTask), isTrue);
      await Future.delayed(const Duration(seconds: 4));
      final retriedTask = await FileDownloader.taskForId(retryTask.taskId);
      expect(retriedTask, equals(retryTask));
      if (retriedTask != null) {
        expect(retriedTask.retriesRemaining, lessThan(retriedTask.retries));
        expect(await FileDownloader.cancelTasksWithIds([retriedTask.taskId]),
            isTrue);
        await downloadStatusCallbackCompleter.future;
        expect(lastDownloadStatus, equals(DownloadTaskStatus.canceled));
        // 3 callbacks for each try, plus one for cancel
        expect(
            downloadStatusCallbackCounter,
            equals(
                (retriedTask.retries - retriedTask.retriesRemaining) * 3 + 1));
      }
      expect(await FileDownloader.taskForId(retryTask.taskId), isNull);
    });

    testWidgets('Retry progress updates with cancellation',
        (widgetTester) async {
      FileDownloader.initialize(
          downloadStatusCallback: downloadStatusCallback,
          downloadProgressCallback: downloadProgressCallback);
      final retryTaskWithProgress = retryTask.copyWith(
          progressUpdates:
              DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
      expect(await FileDownloader.enqueue(retryTaskWithProgress), isTrue);
      expect(downloadProgressCallbackCounter, equals(0));
      await Future.delayed(const Duration(seconds: 4));
      expect(lastDownloadProgress, equals(progressWaitingToRetry));
      // iOS emits a 0.999 progress update for a 403 response with the
      // text of the response, before sharing the response code, triggering
      // the -4.0 progress response.
      // On Android, no progress is emitted other than the -4.0
      expect(
          downloadProgressCallbackCounter, equals(Platform.isAndroid ? 2 : 4));
      final retriedTask = await FileDownloader.taskForId(retryTask.taskId);
      expect(retriedTask, equals(retryTask));
      if (retriedTask != null) {
        expect(retriedTask.retriesRemaining, lessThan(retriedTask.retries));
        expect(await FileDownloader.cancelTasksWithIds([retriedTask.taskId]),
            isTrue);
        await downloadStatusCallbackCompleter.future;
        expect(lastDownloadStatus, equals(DownloadTaskStatus.canceled));
        expect(lastDownloadProgress, equals(progressCanceled));
        expect(await FileDownloader.taskForId(retryTask.taskId), isNull);
      }
    });

    testWidgets('Queue management: allTasks with retries',
        (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(retryTask), isTrue);
      expect(await FileDownloader.enqueue(task), isTrue);
      final allTasks = await FileDownloader.allTasks();
      expect(allTasks.length, equals(2));
      expect(allTasks.contains(retryTask), isTrue);
      expect(allTasks.contains(task), isTrue);
      final nonRetryTasksBeforeWait =
          await FileDownloader.allTasks(includeTasksWaitingToRetry: false);
      expect(nonRetryTasksBeforeWait.length, equals(2));
      expect(nonRetryTasksBeforeWait.contains(retryTask), isTrue);
      expect(nonRetryTasksBeforeWait.contains(task), isTrue);
      await Future.delayed(const Duration(seconds: 4));
      // after wait the regular task has disappeared
      final nonRetryTasksAfterWait =
          await FileDownloader.allTasks(includeTasksWaitingToRetry: false);
      expect(nonRetryTasksAfterWait.length, equals(0));
      final allTasksAfterWait = await FileDownloader.allTasks();
      expect(allTasksAfterWait.length, equals(1));
      expect(allTasksAfterWait.contains(retryTask), isTrue);
      await FileDownloader.cancelTasksWithIds([retryTask.taskId]);
    });

    testWidgets('Queue management: taskForId with retries',
        (widgetTester) async {
      FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
      expect(await FileDownloader.enqueue(retryTask), isTrue);
      expect(await FileDownloader.enqueue(task), isTrue); // regular task
      expect(
          await FileDownloader.taskForId(retryTask.taskId), equals(retryTask));
      expect(await FileDownloader.taskForId(task.taskId), equals(task));
      await Future.delayed(const Duration(seconds: 4));
      // after wait the regular task has disappeared
      expect(
          await FileDownloader.taskForId(retryTask.taskId), equals(retryTask));
      expect(await FileDownloader.taskForId(task.taskId), isNull);
      await FileDownloader.cancelTasksWithIds([retryTask.taskId]);
    });
  });
}

/// Helper: make sure [task] is set as desired, and this will enqueue, wait for
/// complete, and return true if file is at the desired [path]
Future<void> enqueueAndFileExists(String path) async {
  print('enqueueAndFileExists with path $path');
  downloadStatusCallbackCounter = 0;
  downloadStatusCallbackCompleter = Completer();
  FileDownloader.destroy();
  FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
  try {
    File(path).deleteSync(recursive: true);
  } on FileSystemException {}
  expect(await FileDownloader.enqueue(task), isTrue);
  await downloadStatusCallbackCompleter.future;
  expect(File(path).existsSync(), isTrue);
  print('Found file at $path');
  try {
    File(path).deleteSync(recursive: true);
  } on FileSystemException {}
  // Expect 3 status callbacks: enqueued + running + complete
  expect(downloadStatusCallbackCounter, equals(3));
}
