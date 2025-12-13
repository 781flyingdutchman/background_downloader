// ignore_for_file: avoid_print, empty_catches

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

const def = 'default';
var statusCallbackCounter = 0;
var progressCallbackCounter = 0;

var statusCallbackCompleter = Completer<void>();
var progressCallbackCompleter = Completer<void>();
var someProgressCompleter = Completer<void>(); // completes when progress > 0
var significantProgressCompleter =
    Completer<void>(); // completes when progress > 0.1
var lastStatus = TaskStatus.enqueued;
var lastProgress = -100.0;
Task? lastTaskWithStatus;
var lastValidExpectedFileSize = -1;
var lastValidNetworkSpeed = -1.0;
var lastValidTimeRemaining = const Duration(seconds: -1);
TaskException? lastException;

final localServerHostPort =
    Platform.isAndroid ? '10.0.2.2:8080' : '127.0.0.1:8080';

final urlWithoutContentLength =
    'http://$localServerHostPort/files/1MB-test.bin?no_content_length=true';
final urlWithFailure = 'http://$localServerHostPort/fail';
final urlWithContentLength = 'http://$localServerHostPort/files/5MB-test.ZIP';
final urlWithLongContentLength =
    'http://$localServerHostPort/files/57MB-test.ZIP';
final getTestUrl = 'http://$localServerHostPort/echo_get';
final getRedirectTestUrl = 'http://$localServerHostPort/redirect';
final postTestUrl = 'http://$localServerHostPort/echo_post';
final uploadTestUrl = 'http://$localServerHostPort/upload_file';
final uploadBinaryTestUrl = 'http://$localServerHostPort/upload_binary';
final uploadMultiTestUrl = 'http://$localServerHostPort/upload_multi';
final refreshTestUrl = 'http://$localServerHostPort/refresh';
final dataTaskGetUrl = 'http://$localServerHostPort/get';
final dataTaskPostUrl = 'http://$localServerHostPort/post';
final dataTaskHeaders = {'accept': 'application/json'};
const serverName = 'Werkzeug';

const urlWithContentLengthFileSize = 6207471;

const defaultFilename = '1MB-test.bin';
const postFilename = 'post.txt';
const uploadFilename = 'a_file.txt';
const uploadFilename2 = 'second_file.txt';
const largeFilename = '5MB-test.ZIP';

var task =
    DownloadTask(url: urlWithoutContentLength, filename: defaultFilename);

var retryTask =
    DownloadTask(url: urlWithFailure, filename: defaultFilename, retries: 3);

var uploadTask = UploadTask(url: uploadTestUrl, filename: uploadFilename);
var uploadTaskBinary = uploadTask.copyWith(post: 'binary');

final allDigitsRegex = RegExp(r'^\d+$');

void statusCallback(TaskStatusUpdate update) {
  final task = update.task;
  lastTaskWithStatus = task;
  final status = update.status;
  print('statusCallback for $task with status $status');
  if (update.exception != null) {
    print('Exception: ${update.exception}');
  }
  lastStatus = status;
  lastException = update.exception;
  statusCallbackCounter++;
  if (!statusCallbackCompleter.isCompleted && status.isFinalState) {
    statusCallbackCompleter.complete();
  }
}

void progressCallback(TaskProgressUpdate update) {
  final task = update.task;
  final progress = update.progress;
  print('progressCallback for $task with $update}');
  lastProgress = progress;
  if (update.hasExpectedFileSize) {
    lastValidExpectedFileSize = update.expectedFileSize;
  }
  if (update.hasNetworkSpeed) {
    lastValidNetworkSpeed = update.networkSpeed;
  }
  if (update.hasTimeRemaining) {
    lastValidTimeRemaining = update.timeRemaining;
  }
  progressCallbackCounter++;
  if (!someProgressCompleter.isCompleted && progress > 0) {
    someProgressCompleter.complete();
  }
  if (!significantProgressCompleter.isCompleted && progress > 0.1) {
    significantProgressCompleter.complete();
  }
  if (!progressCallbackCompleter.isCompleted &&
      (progress < 0 || progress == 1)) {
    progressCallbackCompleter.complete();
  }
}

/// Returns true if the supplied file equals the large test file
Future<bool> fileEqualsLargeTestFile(File file) async {
  ByteData data = await rootBundle.load("assets/$largeFilename");
  final targetData = data.buffer.asUint8List();
  final fileData = file.readAsBytesSync();
  print('target= ${targetData.length} and file= ${fileData.length}');
  return listEquals(targetData, fileData);
}

Future<void> defaultSetup() async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
  });
  await FileDownloader().reset();
  await FileDownloader().reset(group: 'someGroup');
// recreate the tasks
  task = DownloadTask(url: urlWithoutContentLength, filename: defaultFilename);
  retryTask =
      DownloadTask(url: urlWithFailure, filename: defaultFilename, retries: 3);
  uploadTask = UploadTask(url: uploadTestUrl, filename: uploadFilename);
  uploadTaskBinary =
      uploadTask.copyWith(url: uploadBinaryTestUrl, post: 'binary');

// copy the test files to upload from assets to documents directory
  Directory directory = await getApplicationDocumentsDirectory();
  for (final filename in [uploadFilename, uploadFilename2, largeFilename]) {
    var uploadFilePath = join(directory.path, filename);
    ByteData data = await rootBundle.load("assets/$filename");
    final buffer = data.buffer;
    File(uploadFilePath).writeAsBytesSync(
        buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }
// reset counters
  statusCallbackCounter = 0;
  progressCallbackCounter = 0;
  statusCallbackCompleter = Completer<void>();
  progressCallbackCompleter = Completer<void>();
  significantProgressCompleter = Completer<void>();
  someProgressCompleter = Completer<void>();
  lastStatus = TaskStatus.enqueued;
  lastProgress = 0;
  lastTaskWithStatus = null;
  lastValidExpectedFileSize = -1;
  lastValidNetworkSpeed = -1.0;
  lastValidTimeRemaining = const Duration(seconds: -1);
  lastException = null;
  FileDownloader().destroy();
  await FileDownloader().configure(globalConfig: (Config.holdingQueue, false));
  final path =
      join((await getApplicationDocumentsDirectory()).path, task.filename);
  try {
    File(path).deleteSync();
  } on FileSystemException {}
}

Future<void> defaultTearDown() async {
  await FileDownloader().reset();
  await FileDownloader().reset(group: 'someGroup');
  FileDownloader().destroy();
  if (Platform.isAndroid || Platform.isIOS) {
    await FileDownloader()
        .downloaderForTesting
        .setForceFailPostOnBackgroundChannel(false);
  }
  await Future.delayed(const Duration(milliseconds: 250));
}
