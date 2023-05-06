import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:background_downloader/src/exceptions.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'desktop_downloader.dart';
import 'models.dart';

/// global variables related to pause/resume and cancel functionality

var _bytesTotal = 0;
var _startByte = 0;
var isPaused = false;
var isCanceled = false;

/// global variables related to error
TaskException? taskException;

/// Do the task, sending messages back to the main isolate via [sendPort]
///
/// The first message sent back is a [ReceivePort] that is the command port
/// for the isolate. The first command must be the arguments: task and filePath.
/// Any subsequent commands can only be 'cancel' or 'pause'.
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
  messagesToIsolate.next.then((message) {
    // pause and cancel messages set global variables
    assert(message == 'cancel' || message == 'pause',
        'Only accept "cancel" and "pause" messages');
    if (message == 'cancel') {
      isCanceled = true;
    }
    if (message == 'pause') {
      isPaused = true;
    }
  });
  processStatusUpdateInIsolate(task, TaskStatus.running, sendPort);
  if (!isResume) {
    processProgressUpdateInIsolate(task, 0.0, sendPort);
  }
  if (task.retriesRemaining < 0) {
    logError(task, 'task has negative retries remaining');
    taskException = TaskException('Task has negative retries remaining');
    processStatusUpdateInIsolate(task, TaskStatus.failed, sendPort);
  } else {
    // allow immediate cancel message to come through
    await Future.delayed(const Duration(milliseconds: 0));
    if (task is DownloadTask) {
      await doDownloadTask(
          task, filePath, tempFilePath, requiredStartByte, isResume, sendPort);
    } else {
      await doUploadTask(task, filePath, sendPort);
    }
  }
  sendPort.send(null); // signals end
  Isolate.exit();
}

/// Execute the download task
///
/// Sends updates via the [sendPort] and can be commanded to cancel/pause via
/// the [messagesToIsolate] queue
Future<void> doDownloadTask(
    DownloadTask task,
    String filePath,
    String tempFilePath,
    int requiredStartByte,
    bool isResume,
    SendPort sendPort) async {
  isResume = isResume &&
      await determineIfResumeIsPossible(tempFilePath, requiredStartByte);
  final client = DesktopDownloader.httpClient;
  var request = http.Request(task.httpRequestMethod, Uri.parse(task.url));
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
    if (!isCanceled) {
      var taskCanResume = false;
      if (task.allowPause) {
        // determine if this task can be paused
        final acceptRangesHeader = response.headers['accept-ranges'];
        taskCanResume =
            acceptRangesHeader == 'bytes' || response.statusCode == 206;
        sendPort.send(taskCanResume);
      }
      isResume =
          isResume && response.statusCode == 206; // confirm resume response
      if (okResponses.contains(response.statusCode)) {
        resultStatus = await processOkDownloadResponse(task, filePath,
            tempFilePath, taskCanResume, isResume, response, sendPort);
      } else {
        // not an OK response
        if (response.statusCode == 404) {
          resultStatus = TaskStatus.notFound;
        } else {
          final content = await responseContent(response);
          taskException = TaskHttpException(
              content?.isNotEmpty == true
                  ? content!
                  : response.reasonPhrase ?? 'Invalid HTTP Request',
              response.statusCode);
        }
      }
    }
  } catch (e) {
    logError(task, e.toString());
    setTaskError(e);
  }
  if (isCanceled) {
    // cancellation overrides other results
    resultStatus = TaskStatus.canceled;
  }
  processStatusUpdateInIsolate(task, resultStatus, sendPort);
}

/// Return true if resume is possible
///
/// Confirms that file at [tempFilePath] exists and its length equals
/// [requiredStartByte]
Future<bool> determineIfResumeIsPossible(
    String tempFilePath, int requiredStartByte) async {
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

/// Process response with valid response code
///
/// Performs the actual bytes transfer from response to a temp file,
/// and handles the result of the transfer:
/// - .complete -> copy temp to final file location
/// - .failed -> delete temp file
/// - .paused -> post resume information
Future<TaskStatus> processOkDownloadResponse(
    Task task,
    String filePath,
    String tempFilePath,
    bool taskCanResume,
    bool isResume,
    http.StreamedResponse response,
    SendPort sendPort) async {
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
    outStream = File(tempFilePath)
        .openWrite(mode: isResume ? FileMode.append : FileMode.write);
    final transferBytesResult = await transferBytes(
        response.stream, outStream, contentLength, task, sendPort);
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
          sendPort.send(['resumeData', tempFilePath, _bytesTotal + _startByte]);
          resultStatus = TaskStatus.paused;
        } else {
          taskException =
              TaskResumeException('Task was paused but cannot resume');
          resultStatus = TaskStatus.failed;
        }
        break;

      default:
        throw ArgumentError('Cannot process $transferBytesResult');
    }
  } catch (e) {
    logError(task, e.toString());
    setTaskError(e);
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
Future<bool> prepareResume(
    http.StreamedResponse response, String tempFilePath) async {
  final range = response.headers['content-range'];
  if (range == null) {
    _log.fine('Could not process partial response Content-Range');
    taskException =
        TaskResumeException('Could not process partial response Content-Range');
    return false;
  }
  final contentRangeRegEx = RegExp(r"(\d+)-(\d+)/(\d+)");
  final matchResult = contentRangeRegEx.firstMatch(range);
  if (matchResult == null) {
    _log.fine('Could not process partial response Content-Range $range');
    taskException = TaskResumeException('Could not process '
        'partial response Content-Range $range');
    return false;
  }
  final start = int.parse(matchResult.group(1) ?? '0');
  final end = int.parse(matchResult.group(2) ?? '0');
  final total = int.parse(matchResult.group(3) ?? '0');
  final tempFile = File(tempFilePath);
  final tempFileLength = await tempFile.length();
  _log.finest(
      'Resume start=$start, end=$end of total=$total bytes, tempFile = $tempFileLength bytes');
  if (total != end + 1 || start > tempFileLength) {
    _log.fine('Offered range not feasible: $range');
    taskException = TaskResumeException('Offered range not feasible: $range');
    return false;
  }
  _startByte = start;
  try {
    final file = await tempFile.open(mode: FileMode.writeOnlyAppend);
    await file.truncate(start);
    file.close();
  } on FileSystemException {
    _log.fine('Could not truncate temp file');
    taskException = TaskResumeException('Could not truncate temp file');
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

const boundary = '-----background_downloader-akjhfw281onqciyhnIk';
const lineFeed = '\r\n';

/// Do the binary or multi-part upload task
///
/// Sends updates via the [sendPort] and can be commanded to cancel via
/// the [messagesToIsolate] queue
Future<void> doUploadTask(
    UploadTask task, String filePath, SendPort sendPort) async {
  final inFile = File(filePath);
  if (!inFile.existsSync()) {
    logError(task, 'file to upload does not exist: $filePath');
    taskException =
        TaskFileSystemException('File to upload does not exist: $filePath');
    processStatusUpdateInIsolate(task, TaskStatus.failed, sendPort);
    return;
  }
  // field portion of the multipart, all in one string
  var fieldsString = '';
  for (var entry in task.fields.entries) {
    fieldsString += fieldEntry(entry.key, entry.value);
  }
  // file portion of the multipart
  final isBinaryUpload = task.post == 'binary';
  final fileSize = inFile.lengthSync();
  final contentDispositionString =
      'Content-Disposition: form-data; name="${_browserEncode(task.fileField)}"; '
      'filename="${_browserEncode(task.filename)}"';
  final contentTypeString = 'Content-Type: ${task.mimeType}';
  // determine the content length of the multi-part data
  final contentLength = isBinaryUpload
      ? fileSize
      : lengthInBytes(fieldsString) +
          2 * boundary.length +
          6 * lineFeed.length +
          lengthInBytes(contentDispositionString) +
          contentTypeString.length +
          3 * "--".length +
          fileSize;
  var resultStatus = TaskStatus.failed;
  try {
    final client = DesktopDownloader.httpClient;
    final request =
        http.StreamedRequest(task.httpRequestMethod, Uri.parse(task.url));
    request.headers.addAll(task.headers);
    request.contentLength = contentLength;
    if (isBinaryUpload) {
      request.headers['Content-Type'] = task.mimeType;
    } else {
      // multi-part upload
      request.headers.addAll({
        'Content-Type': 'multipart/form-data; boundary=$boundary',
        'Accept-Charset': 'UTF-8',
        'Connection': 'Keep-Alive',
        'Cache-Control': 'no-cache'
      });
      // write pre-amble, including all fields multi-parts
      request.sink.add(utf8.encode(
          '$fieldsString--$boundary$lineFeed$contentDispositionString$lineFeed$contentTypeString$lineFeed$lineFeed'));
    }
    // initiate the request and handle completion async
    final requestCompleter = Completer();
    var transferBytesResult = TaskStatus.failed;
    client.send(request).then((response) async {
      // request completed, so send status update and finish
      resultStatus = transferBytesResult == TaskStatus.complete &&
              !okResponses.contains(response.statusCode)
          ? TaskStatus.failed
          : transferBytesResult;
      final content = await responseContent(response);
      taskException ??= TaskHttpException(
          content?.isNotEmpty == true
              ? content!
              : response.reasonPhrase ?? 'Invalid HTP response',
          response.statusCode);
      if (response.statusCode == 404) {
        resultStatus = TaskStatus.notFound;
      }
      requestCompleter.complete();
    });
    // send the bytes to the request sink
    final inStream = inFile.openRead();
    transferBytesResult = await transferBytes(
        inStream, request.sink, contentLength, task, sendPort);
    if (!isBinaryUpload && transferBytesResult == TaskStatus.complete) {
      // write epilogue
      request.sink.add(utf8.encode('$lineFeed--$boundary--$lineFeed'));
    }
    request.sink.close(); // triggers request completion, handled above
    await requestCompleter.future; // wait for request to complete
  } catch (e) {
    resultStatus = TaskStatus.failed;
    setTaskError(e);
  }
  if (isCanceled) {
    // cancellation overrides other results
    resultStatus = TaskStatus.canceled;
  }
  processStatusUpdateInIsolate(task, resultStatus, sendPort);
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
    SendPort sendPort) async {
  if (contentLength == 0) {
    contentLength = -1;
  }
  final streamResultStatus = Completer<TaskStatus>();
  var lastProgressUpdate = 0.0;
  var nextProgressUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
  late StreamSubscription<List<int>> subscription;
  subscription = inStream.listen(
      (bytes) {
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
        final progress = min(
            (_bytesTotal + _startByte).toDouble() /
                (contentLength + _startByte),
            0.999);
        final now = DateTime.now();
        if (contentLength > 0 &&
            (progress - lastProgressUpdate > 0.02 &&
                now.isAfter(nextProgressUpdateTime))) {
          processProgressUpdateInIsolate(task, progress, sendPort);
          lastProgressUpdate = progress;
          nextProgressUpdateTime = now.add(const Duration(milliseconds: 500));
        }
      },
      onDone: () => streamResultStatus.complete(TaskStatus.complete),
      onError: (e) {
        logError(task, e);
        setTaskError(e);
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
    if (status != TaskStatus.failed) {
      sendPort.send(['statusUpdate', status]);
    } else {
      sendPort.send(
          ['statusUpdate', status, taskException ?? TaskException('None')]);
    }
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

// The following functions are related to multipart uploads and are
// by and large copied from the dart:http package. Similar implementations
// in Kotlin and Swift are translations of the same code

/// Returns the multipart entry for one field name/value pair
String fieldEntry(String name, String value) =>
    '--$boundary$lineFeed${headerForField(name, value)}$value$lineFeed';

/// Returns the header string for a field.
///
/// The return value is guaranteed to contain only ASCII characters.
String headerForField(String name, String value) {
  var header = 'content-disposition: form-data; name="${_browserEncode(name)}"';
  if (!isPlainAscii(value)) {
    header = '$header\r\n'
        'content-type: text/plain; charset=utf-8\r\n'
        'content-transfer-encoding: binary';
  }
  return '$header\r\n\r\n';
}

/// A regular expression that matches strings that are composed entirely of
/// ASCII-compatible characters.
final _asciiOnly = RegExp(r'^[\x00-\x7F]+$');

final _newlineRegExp = RegExp(r'\r\n|\r|\n');

/// Returns whether [string] is composed entirely of ASCII-compatible
/// characters.
bool isPlainAscii(String string) => _asciiOnly.hasMatch(string);

/// Encode [value] in the same way browsers do.
String _browserEncode(String value) =>
    // http://tools.ietf.org/html/rfc2388 mandates some complex encodings for
// field names and file names, but in practice user agents seem not to
// follow this at all. Instead, they URL-encode `\r`, `\n`, and `\r\n` as
// `\r\n`; URL-encode `"`; and do nothing else (even for `%` or non-ASCII
// characters). We follow their behavior.
    value.replaceAll(_newlineRegExp, '%0D%0A').replaceAll('"', '%22');

/// Returns the length of the [string] in bytes when utf-8 encoded
int lengthInBytes(String string) => utf8.encode(string).length;

final _log = Logger('FileDownloader');

/// Log an error for this task
void logError(Task task, String error) {
  _log.fine('Error for taskId ${task.taskId}: $error');
}

/// Set the [taskException] variable based on error e
void setTaskError(dynamic e) {
  switch (e.runtimeType) {
    case IOException:
      taskException = TaskFileSystemException(e.toString());
      break;

    case HttpException:
    case TimeoutException:
      taskException = TaskConnectionException(e.toString());
      break;

    default:
      taskException = TaskException(e.toString());
  }
}

/// Return the response's content as a String, or null if unable
Future<String?> responseContent(http.StreamedResponse response) {
  try {
    return response.stream.bytesToString();
  } catch (e) {
    _log.fine(
        'Could not read response content from httpResponseCode ${response.statusCode}: $e');
    return Future.value(null);
  }
}
