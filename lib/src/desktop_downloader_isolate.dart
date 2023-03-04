import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

import 'desktop_downloader.dart';
import 'models.dart';

/// Top-level functions that run in an Isolate

var _bytesTotal = 0;
var _startByte = 0;

/// Do the task, sending messages back to the main isolate via [sendPort]
///
/// The first message sent back is a [ReceivePort] that is the command port
/// for the isolate. The first command must be the arguments: task and filePath.
/// Any subsequent commands must be 'cancel' or 'pause'.
Future<void> doTask(SendPort sendPort) async {
  final commandPort = ReceivePort();
  // send the command port back to the main Isolate
  sendPort.send(commandPort.sendPort);
  final messagesToIsolate = StreamQueue<dynamic>(commandPort);
  // get the arguments list and parse each argument
  final args = await messagesToIsolate.next as List<dynamic>;
  final task = args[0];
  final filePath = args[1] as String;
  final tempFilePath = args[2] as String;
  final requiredStartByte = args[3] as int;
  final isResume = args[4] as bool;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    if (kDebugMode) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    }
  });
  processStatusUpdateInIsolate(task, TaskStatus.running, sendPort);
  processProgressUpdateInIsolate(task, 0.0, sendPort);
  if (task.retriesRemaining < 0) {
    logError(task, 'task has negative retries remaining');
    processStatusUpdateInIsolate(task, TaskStatus.failed, sendPort);
  } else {
    if (task is DownloadTask) {
      await doDownloadTask(task, filePath, tempFilePath, requiredStartByte, isResume,
          sendPort, messagesToIsolate);
    } else {
      await doUploadTask(task, filePath, sendPort, messagesToIsolate);
    }
  }
  sendPort.send(null); // signals end
  Isolate.exit();
}

/// Do the POST or GET based download task
///
/// Sends updates via the [sendPort] and can be commanded to cancel via
/// the [messagesToIsolate] queue
Future<void> doDownloadTask(
    Task task,
    String filePath,
    String tempFilePath,
    int requiredStartByte,
    bool isResume,
    SendPort sendPort,
    StreamQueue messagesToIsolate) async {
  isResume = isResume && await determineIfResumeIsPossible(tempFilePath, requiredStartByte);
  final client = DesktopDownloader.httpClient;
  var request = task.post == null
      ? http.Request('GET', Uri.parse(task.url))
      : http.Request('POST', Uri.parse(task.url));
  request.headers.addAll(task.headers);
  if (isResume) {
    request.headers['Range'] = 'bytes=$requiredStartByte-';
  }
  if (task.post is String) {
    request.body = task.post!;
  }
  var resultStatus = TaskStatus.failed;
  try {
    final response = await client.send(request);
    var taskCanResume = false;
    if (task.allowPause) {
      // determine if this task can be paused
      final acceptRangesHeader = response.headers['accept-ranges'];
      taskCanResume = acceptRangesHeader == 'bytes';
      sendPort.send(taskCanResume);
    }
    if (okResponses.contains(response.statusCode)) {
      resultStatus = await processOkDownloadResponse(
        task,
        filePath,
        tempFilePath,
        taskCanResume,
        isResume,
        response,
        sendPort,
        messagesToIsolate,
      );
    } else {
      // not an OK response
      if (response.statusCode == 404) {
        resultStatus = TaskStatus.notFound;
      }
    }
  } catch (e) {
    logError(task, e.toString());
  }
  processStatusUpdateInIsolate(task, resultStatus, sendPort);
}

/// Return true if resume is possible, given temp filepath
Future<bool> determineIfResumeIsPossible(String tempFilePath, int requiredStartByte) async {
  if (File(tempFilePath).existsSync()) {
    if (await File(tempFilePath).length() == requiredStartByte) {
      return true;
    } else {
      _log.fine('Partially downloaded file is corrupted, resume not possible');
    }
  } else {
    _log.fine('Partially downloaded file not available, resume not possible');
  }
  return false;
}



Future<TaskStatus> processOkDownloadResponse(
    Task task,
    String filePath,
    String tempFilePath,
    bool taskCanResume,
    bool isResume,
    http.StreamedResponse response,
    SendPort sendPort,
    StreamQueue<dynamic> messagesToIsolate) async {
  final contentLength = response.contentLength ?? -1;
  isResume = isResume && response.statusCode == 206;
  if (isResume && !await prepareResume(response, tempFilePath)) {
    deleteTempFile(tempFilePath);
    return TaskStatus.failed;
  }
  var resultStatus = TaskStatus.failed;
  IOSink? outStream;
  try {
    // do the actual download
    outStream = File(tempFilePath).openWrite(mode: isResume ? FileMode.append : FileMode.write);
    final transferBytesResult = await transferBytes(response.stream, outStream,
        contentLength, task, sendPort, messagesToIsolate);
    switch (transferBytesResult) {
      case TaskStatus.complete:
        // copy file to destination, creating dirs if needed
        await outStream.flush();
        final dirPath = path.dirname(filePath);
        Directory(dirPath).createSync(recursive: true);
        File(tempFilePath).copySync(filePath);
        resultStatus = TaskStatus.complete;
        break;

      case TaskStatus.canceled:
        deleteTempFile(tempFilePath);
        resultStatus = TaskStatus.canceled;
        break;

      case TaskStatus.paused:
        if (taskCanResume) {
          sendPort.send(['resumeData', tempFilePath, _bytesTotal]);
          resultStatus = TaskStatus.paused;
        } else {
          resultStatus = TaskStatus.failed;
        }
        break;

      default:
        throw ArgumentError('Cannot process $transferBytesResult');
    }
  } catch (e) {
    logError(task, e.toString());
  } finally {
    try {
      await outStream?.close();
      if (resultStatus != TaskStatus.paused) {
        File(tempFilePath).deleteSync();
      }
    } catch (e) {
      logError(task, 'Could not delete temp file $tempFilePath');
    }
  }
  return resultStatus;
}

/// Prepare for resume if possible
///
/// Returns true if task can continue, false if task failed.
/// Extracts and parses Range headers, and truncates temp file
Future<bool> prepareResume(http.StreamedResponse response, String tempFilePath) async {
  final range = response.headers['content-range'];
  if (range == null) {
    _log.fine('Could not process partial response Content-Range');
    return false;
  }
  final contentRangeRegEx = RegExp(r"(\d+)-(\d+)/(\d+)");
  final matchResult = contentRangeRegEx.firstMatch(range);
  if (matchResult == null) {
    _log.fine('Could not process partial response Content-Range $range');
    return false;
  }
  final start = int.parse(matchResult.group(1) ?? '0');
  final end = int.parse(matchResult.group(2) ?? '0');
  final total = int.parse(matchResult.group(3) ?? '0');
  final tempFile = File(tempFilePath);
  final tempFileLength = await tempFile.length();
  if (total != end + 1 || start > tempFileLength) {
    _log.fine('Offered range not feasible: $range');
    return false;
  }
  _startByte = start;
  try {
    final file = await tempFile.open(mode: FileMode.writeOnlyAppend);
    await file.truncate(start);
    file.close();
  } on FileSystemException {
    _log.fine('Could not truncate temp file');
    return false;
  }
  return true;
}

/// Delete the temporary file
void deleteTempFile(String tempFilePath) async {
  try {
    File(tempFilePath).deleteSync();
  } on FileSystemException {
    _log.fine('Could not delete temp file $tempFilePath');
  }
}

/// Do the binary or multi-part upload task
///
/// Sends updates via the [sendPort] and can be commanded to cancel via
/// the [messagesToIsolate] queue
Future<void> doUploadTask(Task task, String filePath, SendPort sendPort,
    StreamQueue messagesToIsolate) async {
  final inFile = File(filePath);
  if (!inFile.existsSync()) {
    logError(task, 'file to upload does not exist: $filePath');
    processStatusUpdateInIsolate(task, TaskStatus.failed, sendPort);
    return;
  }
  final isBinaryUpload = task.post == 'binary';
  final fileSize = inFile.lengthSync();
  final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
  const boundary = '-----background_downloader-akjhfw281onqciyhnIk';
  const lineFeed = '\r\n';
  final contentDispositionString =
      'Content-Disposition: form-data; name="file"; filename="${task.filename}"';
  final contentTypeString = 'Content-Type: $mimeType';
  // determine the content length of the multi-part data
  final contentLength = isBinaryUpload
      ? fileSize
      : 2 * boundary.length +
          6 * lineFeed.length +
          contentDispositionString.length +
          contentTypeString.length +
          3 * "--".length +
          fileSize;
  try {
    final client = DesktopDownloader.httpClient;
    final request = http.StreamedRequest('POST', Uri.parse(task.url));
    request.headers.addAll(task.headers);
    request.contentLength = contentLength;
    if (isBinaryUpload) {
      request.headers['Content-Type'] = mimeType;
    } else {
      // multi-part upload
      request.headers.addAll({
        'Content-Type': 'multipart/form-data; boundary=$boundary',
        'Accept-Charset': 'UTF-8',
        'Connection': 'Keep-Alive',
        'Cache-Control': 'no-cache'
      });
      // write pre-amble
      request.sink.add(utf8.encode(
          '--$boundary$lineFeed$contentDispositionString$lineFeed$contentTypeString$lineFeed$lineFeed'));
    }
    // initiate the request and handle completion async
    final requestCompleter = Completer();
    var resultStatus = TaskStatus.failed;
    var transferBytesResult = TaskStatus.failed;
    client.send(request).then((response) {
      // request completed, so send status update and finish
      resultStatus = transferBytesResult == TaskStatus.complete &&
              !okResponses.contains(response.statusCode)
          ? TaskStatus.failed
          : transferBytesResult;
      if (response.statusCode == 404) {
        resultStatus = TaskStatus.notFound;
      }
      requestCompleter.complete();
    });
    // send the bytes to the request sink
    final inStream = inFile.openRead();
    transferBytesResult = await transferBytes(inStream, request.sink,
        contentLength, task, sendPort, messagesToIsolate);
    if (!isBinaryUpload && transferBytesResult == TaskStatus.complete) {
      // write epilogue
      request.sink.add(utf8.encode('$lineFeed--$boundary--$lineFeed'));
    }
    request.sink.close(); // triggers request completion, handled above
    await requestCompleter.future; // wait for request to complete
    processStatusUpdateInIsolate(task, resultStatus, sendPort);
  } catch (e) {
    processStatusUpdateInIsolate(task, TaskStatus.failed, sendPort);
  }
}

/// Transfer all bytes from [inStream] to [outStream], expecting [contentLength]
/// total bytes
///
/// Sends updates via the [sendPort] and can be commanded to cancel/pause via
/// the [messagesToIsolate] queue
///
/// Returns a [TaskStatus] and will throw any exception generated within
///
/// Note: does not flush or close any streams
Future<TaskStatus> transferBytes(
    Stream<List<int>> inStream,
    EventSink<List<int>> outStream,
    int contentLength,
    Task task,
    SendPort sendPort,
    StreamQueue messagesToIsolate) async {
  if (contentLength == 0) {
    contentLength = -1;
  }
  var isCanceled = false;
  var isPaused = false;
  messagesToIsolate.next.then((message) {
    assert(message == 'cancel' || message == 'pause',
        'Only accept "cancel" and "pause" messages');
    if (message == 'cancel') {
      isCanceled = true;
    }
    if (message == 'pause') {
      isPaused = true;
    }
  });
  final streamResultStatus = Completer<TaskStatus>();
  var lastProgressUpdate = 0.0;
  var nextProgressUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
  late StreamSubscription<List<int>> subscription;
  subscription = inStream.listen(
      (bytes) async {
        if (isCanceled) {
          streamResultStatus.complete(TaskStatus.canceled);
          return;
        }
        if (isPaused) {
          streamResultStatus.complete(TaskStatus.paused);
          return;
        }
        outStream.add(bytes);
        _bytesTotal += bytes.length;
        final progress = min((_bytesTotal + _startByte).toDouble() / (contentLength + _startByte), 0.999);
        final now = DateTime.now();
        if (contentLength > 0 &&
            (_bytesTotal < 10000 ||
                (progress - lastProgressUpdate > 0.02 &&
                    now.isAfter(nextProgressUpdateTime)))) {
          processProgressUpdateInIsolate(task, progress, sendPort);
          lastProgressUpdate = progress;
          nextProgressUpdateTime = now.add(const Duration(milliseconds: 500));
        }
      },
      onDone: () => streamResultStatus.complete(TaskStatus.complete),
      onError: (e) {
        logError(task, e);
        streamResultStatus.complete(TaskStatus.failed);
      });
  final resultStatus = await streamResultStatus.future;
  await subscription.cancel();
  return resultStatus;
}

/// Processes a change in status for the [task]
///
/// Sends status update via the [sendPort], if requested
/// If the task is finished, processes a final progressUpdate update
void processStatusUpdateInIsolate(
    Task task, TaskStatus status, SendPort sendPort) {
  final retryNeeded = status == TaskStatus.failed && task.retriesRemaining > 0;
// if task is in final state, process a final progressUpdate
// A 'failed' progress update is only provided if
// a retry is not needed: if it is needed, a `waitingToRetry` progress update
// will be generated in the FileDownloader
  if (status.isFinalState) {
    switch (status) {
      case TaskStatus.complete:
        {
          processProgressUpdateInIsolate(task, progressComplete, sendPort);
          break;
        }
      case TaskStatus.failed:
        {
          if (!retryNeeded) {
            processProgressUpdateInIsolate(task, progressFailed, sendPort);
          }
          break;
        }
      case TaskStatus.canceled:
        {
          processProgressUpdateInIsolate(task, progressCanceled, sendPort);
          break;
        }
      case TaskStatus.notFound:
        {
          processProgressUpdateInIsolate(task, progressNotFound, sendPort);
          break;
        }
      default:
        {}
    }
  }
// Post update if task expects one, or if failed and retry is needed
  if (task.providesStatusUpdates || retryNeeded) {
    sendPort.send(status);
  }
}

/// Processes a progress update for the [task]
///
/// Sends progress update via the [sendPort], if requested
void processProgressUpdateInIsolate(
    Task task, double progress, SendPort sendPort) {
  if (task.providesProgressUpdates) {
    sendPort.send(progress);
  }
}

final _log = Logger('FileDownloader');

/// Log an error for this task
void logError(Task task, String error) {
  _log.fine('Error for taskId ${task.taskId}: $error');
}
