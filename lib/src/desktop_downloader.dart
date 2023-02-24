import 'dart:async';
import 'dart:collection';
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
import 'package:path_provider/path_provider.dart';

import 'base_downloader.dart';
import 'downloader.dart';
import 'models.dart';

const okResponses = [200, 201, 202, 203, 204, 205, 206];

/// Implementation of download functionality for desktop platforms
///
/// On desktop (MacOS, Linux, Windows) the download and upload are implemented
/// in Dart, as there is no native platform equivalent of URLSession or
/// WorkManager as there is on iOS and Android
class DesktopDownloader extends BaseDownloader {
  final maxConcurrent = 5;
  static final DesktopDownloader _singleton = DesktopDownloader._internal();
  final _queue = Queue<Task>();
  final _running = Queue<Task>(); // subset that is running
  final _isolateSendPorts =
      <Task, SendPort?>{}; // isolate SendPort for running task
  static final httpClient = http.Client();

  factory DesktopDownloader() => _singleton;

  DesktopDownloader._internal();

  @override
  Future<bool> enqueue(Task task) async {
    _queue.add(task);
    processStatusUpdate(task, TaskStatus.enqueued);
    _advanceQueue();
    return true;
  }

  /// Advance the queue if it's not empty and there is room in the run queue
  void _advanceQueue() {
    while (_running.length < maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _running.add(task);
      _executeTask(task).then((_) {
        _running.remove(task);
        _advanceQueue();
      });
    }
  }

  /// Execute this task
  ///
  /// The task runs on an Isolate, which is sent the task information and
  /// which will emit status and progress updates.  These updates will be
  /// 'forwarded' to the [backgroundChannel] and processed by the
  /// [FileDownloader]
  Future<void> _executeTask(Task task) async {
    final Directory baseDir;
    switch (task.baseDirectory) {
      case BaseDirectory.applicationDocuments:
        baseDir = await getApplicationDocumentsDirectory();
        break;
      case BaseDirectory.temporary:
        baseDir = await getTemporaryDirectory();
        break;
      case BaseDirectory.applicationSupport:
        baseDir = await getApplicationSupportDirectory();
        break;
    }
    final filePath = path.join(baseDir.path, task.directory, task.filename);
    final tempFilePath = path.join((await getTemporaryDirectory()).path,
        Random().nextInt(1 << 32).toString());
    // spawn an isolate to do the task
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    errorPort.listen((message) {
      final error = (message as List).first as String;
      logError(task, error);
      processStatusUpdate(task, TaskStatus.failed);
      receivePort.close(); // also ends listener at then end
    });
    await Isolate.spawn(doTask, receivePort.sendPort,
        onError: errorPort.sendPort);
    final messagesFromIsolate = StreamQueue<dynamic>(receivePort);
    final sendPort = await messagesFromIsolate.next;
    sendPort.send([task, filePath, tempFilePath]);
    if (_isolateSendPorts.keys.contains(task)) {
      // if already registered with null value, cancel immediately
      sendPort.send('cancel');
    }
    _isolateSendPorts[task] = sendPort; // allows future cancellation
    // listen for events sent back from the isolate
    while (await messagesFromIsolate.hasNext) {
      final message = await messagesFromIsolate.next;
      if (message == null) {
        // sent when final state has been sent
        receivePort.close();
      } else {
        // Process the status or progress update
        if (message is TaskStatus) {
          processStatusUpdate(task, message);
        } else if (message is double) {
          processProgressUpdate(task, message);
        } else {
          _log.warning('Received message with unknown type '
              '${message.runtimeType} from Isolate');
        }
      }
    }
    errorPort.close();
    _isolateSendPorts.remove(task);
  }

  @override
  Future<int> reset(String group) async {
    final retriesTaskCount = await super.reset(group);
    final inQueueIds =
        _queue.where((task) => task.group == group).map((task) => task.taskId);
    final runningIds = _running
        .where((task) => task.group == group)
        .map((task) => task.taskId);
    final taskIds = [...inQueueIds, ...runningIds];
    if (taskIds.isNotEmpty) {
      cancelTasksWithIds(taskIds);
    }
    return retriesTaskCount + taskIds.length;
  }

  @override
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final retryTasks = await super.allTasks(group, includeTasksWaitingToRetry);
    final inQueue = _queue.where((task) => task.group == group);
    final running = _running.where((task) => task.group == group);
    return [...retryTasks, ...inQueue, ...running];
  }

  /// Cancels ongoing platform tasks whose taskId is in the list provided
  ///
  /// Returns true if all cancellations were successful
  @override
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds) async {
    final inQueue = _queue
        .where((task) => taskIds.contains(task.taskId))
        .toList(growable: false);
    for (final task in inQueue) {
      processStatusUpdate(task, TaskStatus.canceled);
      _remove(task);
    }
    final running = _running.where((task) => taskIds.contains(task.taskId));
    for (final task in running) {
      final sendPort = _isolateSendPorts[task];
      if (sendPort != null) {
        sendPort.send('cancel');
        _isolateSendPorts.remove(task);
      } else {
        // register task for cancellation even if sendPort does not yet exist:
        // this will lead to immediate cancellation when the Isolate starts
        _isolateSendPorts[task] = null;
      }
    }
    return true;
  }

  @override
  Future<Task?> taskForId(String taskId) async {
    var task = await super.taskForId(taskId);
    if (task != null) {
      return task;
    }
    try {
      return _running.where((task) => task.taskId == taskId).first;
    } on StateError {
      try {
        return _queue.where((task) => task.taskId == taskId).first;
      } on StateError {
        return null;
      }
    }
  }

  @override
  void destroy() {
    super.destroy();
    _queue.clear();
    _running.clear();
    _isolateSendPorts.clear();
  }

  /// Remove all references to [task]
  void _remove(Task task) {
    _queue.remove(task);
    _running.remove(task);
    _isolateSendPorts.remove(task);
  }
}

/** Top-level functions that run in an Isolate */

/// Do the task, sending messages back to the main isolate via [sendPort]
///
/// The first message sent back is a [ReceivePort] that is the command port
/// for the isolate. The first command must be the arguments: task and filePath.
/// Any subsequent commands must be 'cancel', a cancellation request.
Future<void> doTask(SendPort sendPort) async {
  final commandPort = ReceivePort();
  // send the command port back to the main Isolate
  sendPort.send(commandPort.sendPort);
  final messagesToIsolate = StreamQueue<dynamic>(commandPort);
  // get the arguments list and parse each argument
  final args = await messagesToIsolate.next as List<dynamic>;
  final task = args.first;
  final filePath = args[1];
  final tempFilePath = args.last;
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
      await doDownloadTask(
          task, filePath, tempFilePath, sendPort, messagesToIsolate);
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
Future<void> doDownloadTask(Task task, String filePath, String tempFilePath,
    SendPort sendPort, StreamQueue messagesToIsolate) async {
  final client = DesktopDownloader.httpClient;
  var request = task.post == null
      ? http.Request('GET', Uri.parse(task.url))
      : http.Request('POST', Uri.parse(task.url));
  request.headers.addAll(task.headers);
  if (task.post is String) {
    request.body = task.post!;
  }
  var resultStatus = TaskStatus.failed;
  try {
    final response = await client.send(request);
    final contentLength = response.contentLength ?? -1;
    if (okResponses.contains(response.statusCode)) {
      IOSink? outStream;
      try {
        // do the actual download
        outStream = File(tempFilePath).openWrite();
        final transferBytesResult = await transferBytes(response.stream,
            outStream, contentLength, task, sendPort, messagesToIsolate);
        if (transferBytesResult == TaskStatus.complete) {
          // copy file to destination, creating dirs if needed
          await outStream.flush();
          final dirPath = path.dirname(filePath);
          Directory(dirPath).createSync(recursive: true);
          File(tempFilePath).copySync(filePath);
        }
        if ([TaskStatus.complete, TaskStatus.canceled]
            .contains(transferBytesResult)) {
          resultStatus = transferBytesResult;
        }
      } catch (e) {
        logError(task, e.toString());
      } finally {
        try {
          await outStream?.close();
          File(tempFilePath).deleteSync();
        } catch (e) {
          logError(task, 'Could not delete temp file $tempFilePath');
        }
      }
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
/// Sends updates via the [sendPort] and can be commanded to cancel via
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
  messagesToIsolate.next.then((message) {
    assert(message == 'cancel', 'Only accept "cancel" messages');
    isCanceled = true;
  });
  final streamResultStatus = Completer<TaskStatus>();
  var bytesTotal = 0;
  var lastProgressUpdate = 0.0;
  var nextProgressUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
  late StreamSubscription<List<int>> subscription;
  subscription = inStream.listen(
      (bytes) async {
        if (isCanceled) {
          streamResultStatus.complete(TaskStatus.canceled);
          return;
        }
        outStream.add(bytes);
        bytesTotal += bytes.length;
        final progress = min(bytesTotal.toDouble() / contentLength, 0.999);
        final now = DateTime.now();
        if (contentLength > 0 &&
            (bytesTotal < 10000 ||
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
