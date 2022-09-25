import 'dart:async';
import 'dart:io';


import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

const def = 'default';
var downloadStatusCallbackCounter = 0;
var downloadProgressCallbackCounter = 0;

var downloadStatusCallbackCompleter = Completer<void>();
var downloadProgressCallbackCompleter = Completer<void>();
var lastDownloadStatus = DownloadTaskStatus.undefined;

var task =
    BackgroundDownloadTask(url: 'https://google.com', filename: 'google.html');

void downloadStatusCallback(
    BackgroundDownloadTask task, DownloadTaskStatus status) {
  print('downloadStatusCallback for $task with status $status');
  lastDownloadStatus = status;
  downloadStatusCallbackCounter++;
  if (!downloadStatusCallbackCompleter.isCompleted &&
          status == DownloadTaskStatus.complete ||
      status == DownloadTaskStatus.failed ||
      status == DownloadTaskStatus.notFound ||
      status == DownloadTaskStatus.canceled) {
    downloadStatusCallbackCompleter.complete();
  }
}

void downloadProgressCallback(BackgroundDownloadTask task, double progress) {
  print('downloadProgressCallback for $task with progress $progress');
  downloadProgressCallbackCounter++;
  if (!downloadProgressCallbackCompleter.isCompleted &&
      (progress < 0 || progress == 1)) {
    downloadProgressCallbackCompleter.complete();
  }
}

void main() {
  setUp(() {
    task = BackgroundDownloadTask(
        url: 'https://google.com', filename: 'google.html');
    downloadStatusCallbackCounter = 0;
    downloadProgressCallbackCounter = 0;
    downloadStatusCallbackCompleter = Completer<void>();
    downloadProgressCallbackCompleter = Completer<void>();
    lastDownloadStatus = DownloadTaskStatus.undefined;
    FileDownloader.destroy();
  });

  test('initialize', () {
    // confirm asserts work
    expect(() => FileDownloader.registerCallbacks(), throwsAssertionError);
    expect(() => FileDownloader.enqueue(task), throwsAssertionError);
    expect(() => FileDownloader.allTaskIds(), throwsAssertionError);
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
    expect(FileDownloader.statusCallbacks[def], equals(downloadStatusCallback));
    FileDownloader.registerCallbacks(
        group: 'test', downloadProgressCallback: downloadProgressCallback);
    expect(FileDownloader.progressCallbacks['test'],
        equals(downloadProgressCallback));
  });

  testWidgets('enqueue', (tester) async {
    var path =
        join((await getApplicationDocumentsDirectory()).path, task.filename);
    await enqueueAndFileExists(path);
    expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
    // with subdirectory
    task = BackgroundDownloadTask(
        url: 'https://google.com', directory: 'test', filename: 'google.html');
    path = join(
        (await getApplicationDocumentsDirectory()).path, 'test', task.filename);
    await enqueueAndFileExists(path);
    // cache directory
    task = BackgroundDownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
        baseDirectory: BaseDirectory.temporary);
    path = join((await getTemporaryDirectory()).path, task.filename);
    await enqueueAndFileExists(path);
    // cache directory
    task = BackgroundDownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
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
    expect(downloadStatusCallbackCounter, equals(2));
    // because we have not set progresUpdates to something that provides
    // progress updates, we should just get no updates
    expect(downloadProgressCallbackCompleter.isCompleted, isFalse);
    expect(downloadProgressCallbackCounter, equals(0));
    downloadStatusCallbackCounter = 0;
    downloadStatusCallbackCompleter = Completer();
    task = BackgroundDownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
        progressUpdates:
            DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
    expect(await FileDownloader.enqueue(task), isTrue);
    await downloadProgressCallbackCompleter.future;
    // because google.com has no content-length, we only expect the 1.0 progress update
    expect(downloadProgressCallbackCounter, equals(1));
    await downloadStatusCallbackCompleter.future;
    expect(downloadStatusCallbackCounter, equals(2));
    // now try a file that has content length
    downloadStatusCallbackCounter = 0;
    downloadProgressCallbackCounter = 0;
    downloadStatusCallbackCompleter = Completer<void>();
    downloadProgressCallbackCompleter = Completer<void>();
    task = BackgroundDownloadTask(
        url: 'http://ipv4.download.thinkbroadband.com/5MB.zip',
        filename: 'google.html',
        progressUpdates:
            DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
    expect(await FileDownloader.enqueue(task), isTrue);
    await downloadProgressCallbackCompleter.future;
    expect(downloadProgressCallbackCounter, greaterThan(1));
    await downloadStatusCallbackCompleter.future;
    expect(downloadStatusCallbackCounter, equals(2));
    print('Finished enqueue with progress');
  });

  testWidgets('enqueue with non-default group callbacks', (widgetTester) async {
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

  testWidgets('reset', (widgetTester) async {
    FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
    expect(await FileDownloader.enqueue(task), isTrue);
    expect(await FileDownloader.reset(group: 'non-default'), equals(0));
    expect(await FileDownloader.reset(), equals(1));
    await downloadStatusCallbackCompleter.future;
    expect(downloadStatusCallbackCounter, equals(2));
    expect(lastDownloadStatus, equals(DownloadTaskStatus.canceled));
    print('Finished reset');
  });

  testWidgets('allTaskIds', (widgetTester) async {
    FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
    expect(await FileDownloader.enqueue(task), isTrue);
    expect(await FileDownloader.allTaskIds(group: 'non-default'), isEmpty);
    expect((await FileDownloader.allTaskIds()).length, equals(1));
    await downloadStatusCallbackCompleter.future;
    expect(downloadStatusCallbackCounter, equals(2));
    expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
    print('Finished alTaskIds');
  });

  testWidgets('cancelTasksWithIds', (widgetTester) async {
    FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
    expect(await FileDownloader.enqueue(task), isTrue);
    var taskIds = await FileDownloader.allTaskIds();
    expect(taskIds.length, equals(1));
    expect(taskIds.first, equals(task.taskId));
    expect(await FileDownloader.cancelTasksWithIds(taskIds), isTrue);
    await downloadStatusCallbackCompleter.future;
    expect(downloadStatusCallbackCounter, equals(2));
    expect(lastDownloadStatus, equals(DownloadTaskStatus.canceled));
    print('Finished cancelTasksWithIds');
  });

  testWidgets('taskForId', (widgetTester) async {
    FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
    expect(await FileDownloader.taskForId('something'), isNull);
    expect(await FileDownloader.enqueue(task), isTrue);
    expect(await FileDownloader.taskForId('something'), isNull);
    expect(await FileDownloader.taskForId(task.taskId), equals(task));
    await downloadStatusCallbackCompleter.future;
    expect(downloadStatusCallbackCounter, equals(2));
    expect(lastDownloadStatus, equals(DownloadTaskStatus.complete));
    print('Finished taskForId');
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
  expect(downloadStatusCallbackCounter, equals(2)); // running + complete
}
