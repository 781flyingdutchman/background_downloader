import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'downloader.dart';
import 'models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// Implementation of the core download functionality for desktop platforms
///
/// On desktop (MacOS, Linux, Windows) the download and upload are implemented
/// in Dart, as there is no native platform equivalent of URLSession or
/// WorkManager as there is on iOS and Android
class DesktopDownloader {
  final log = Logger('FileDownloader');

  final maxConcurrent = 5;
  static final DesktopDownloader _singleton = DesktopDownloader._internal();
  final _queue = Queue<Task>();
  final _running = Queue<Task>(); // subset that is running

  var _updatesStreamController = StreamController();

  factory DesktopDownloader() {
    return _singleton;
  }

  /// Private constructor for singleton
  DesktopDownloader._internal();

  Stream get updates => _updatesStreamController.stream;

  /// Initialize the [DesktopDownloader]
  ///
  /// Call before listening to the updates stream
  void initialize() => _updatesStreamController = StreamController();

  Future<bool> enqueue(Task task) {
    _queue.add(task);
    emitUpdate(task, TaskStatus.enqueued);
    _advanceQueue();
    return Future.value(true);
  }

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
    // spawn an isolate to do the task
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    errorPort.listen((message) {
      final error = (message as List).first as String;
      log.info('Error for taskId ${task.taskId}: $error');
      emitUpdate(task, TaskStatus.failed);
      receivePort.close(); // also ends listener at then end
    });
    final isolate = await Isolate.spawn(doTask, receivePort.sendPort,
        onError: errorPort.sendPort);

    // Convert the ReceivePort into a StreamQueue to receive messages from the
    // spawned isolate using a pull-based interface. Events are stored in this
    // queue until they are accessed by `events.next`.
    final messagesFromIsolate = StreamQueue<dynamic>(receivePort);
    // The first message from the spawned isolate is a SendPort. This port is
    // used to communicate with the spawned isolate.
    final sendPort = await messagesFromIsolate.next;

    // send three arguments: true if task is download, the task, the filePath
    sendPort.send([task, filePath]);
    // listen for events sent back from the isolate
    while (await messagesFromIsolate.hasNext) {
      final message = await messagesFromIsolate.next;
      if (message == null) {
        // sent when final state has been sent
        receivePort.close();
      } else {
        // Pass message on to FileDownloader via [updates]
        emitUpdate(task, message);
      }
    }
    errorPort.close();
    print("end of events");
  }

  void emitUpdate(Task task, dynamic message) =>
      _updatesStreamController.add([task, message]);

  /// True if this platform is supported by the DesktopDownloader
  bool get supportsThisPlatform =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}

Future<void> doTask(SendPort sendPort) async {
  final commandPort = ReceivePort();
  // send the command port back to the main Isolate
  sendPort.send(commandPort.sendPort);
  // get the arguments list and parse
  final args = await commandPort.first as List<dynamic>;
  commandPort.close();
  final task = args.first;
  final filePath = args.last as String;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    if (kDebugMode) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    }
  });
  FileDownloader.httpClient ??= http.Client();
  processStatusUpdate(task, TaskStatus.running, sendPort);
  if (task is DownloadTask) {
    await doDownloadTask(task, filePath, sendPort);
  } else {
    await doUploadTask(task, filePath, sendPort);
  }
  sendPort.send(null); // signals end
  Isolate.exit();
}

Future<void> doDownloadTask(
    Task task, String filePath, SendPort sendPort) async {
  final log = Logger('FileDownloader');
  if (task.retriesRemaining < 0) {
    log.warning(
        'Task with taskId ${task.taskId} has negative retries remaining');
    return;
  }
  final tempFileName = Random().nextInt(1 << 32).toString();
  final client = FileDownloader.httpClient!;
  var request = task.post == null
      ? http.Request('GET', Uri.parse(task.url))
      : http.Request('POST', Uri.parse(task.url));
  request.headers.addAll(task.headers);
  while (task.retriesRemaining >= 0) {
    try {
      final response = await client.send(request);
      final contentLength = response.contentLength ?? -1;
      if ([200, 201, 202, 203, 204, 205, 206, 404]
          .contains(response.statusCode)) {
        try {
          // do the actual download
          final outStream = File(tempFileName).openWrite();
          final streamSuccess = Completer<bool>();
          var bytesTotal = 0;
          var lastProgressUpdate = 0.0;
          var nextProgressUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
          final subscription = response.stream.listen(
              (bytes) {
                outStream.add(bytes);
                bytesTotal += bytes.length;
                final progress =
                    min(bytesTotal.toDouble() / contentLength, 0.999);
                final now = DateTime.now();
                if (contentLength > 0 &&
                    (bytesTotal < 10000 ||
                        (progress - lastProgressUpdate > 0.02 &&
                            now.isAfter(nextProgressUpdateTime)))) {
                  processProgressUpdate(task, progress, sendPort);
                  lastProgressUpdate = progress;
                  nextProgressUpdateTime =
                      now.add(const Duration(milliseconds: 500));
                }
              },
              onDone: () => streamSuccess.complete(true),
              onError: (e) {
                log.warning('Error downloading taskId ${task.taskId}: $e');
                streamSuccess.complete(false);
              });
          final success = await streamSuccess.future;
          subscription.cancel();
          outStream.close();
          if (success) {
            // copy file to destination, creating dirs if needed
            final dirPath = path.dirname(filePath);
            Directory(dirPath).createSync(recursive: true);
            File(tempFileName).copySync(filePath);
            File(tempFileName).deleteSync();
            processStatusUpdate(task, TaskStatus.complete, sendPort);
            return;
          }
        } on FileSystemException catch (e) {
          log.warning(e);
        }
      }
    } catch (e) {
      log.warning(e);
    } finally {
      try {
        File(tempFileName).deleteSync();
      } catch (e) {}
    }
    // error: retry if allowed, otherwise the task failed
    task.decreaseRetriesRemaining();
    if (task.retriesRemaining < 0) {
      processStatusUpdate(task, TaskStatus.failed, sendPort);
      return;
    }
    final waitTime = Duration(
        seconds: pow(2, (task.retries - task.retriesRemaining)).toInt());
    await Future.delayed(waitTime);
  }
}

Future<void> doUploadTask(Task task, String filePath, SendPort sendPort) async {
  throw UnimplementedError("DoDownloadTask has not been implemented");
}

/// Processes a change in status for the [task]
///
/// Sends status update via the [sendPort], if requested
/// If the task is finished, processes a final progressUpdate update
void processStatusUpdate(Task task, TaskStatus status, SendPort sendPort) {
  final retryNeeded = status == TaskStatus.failed && task.retriesRemaining > 0;
  // if task is in final state, process a final progressUpdate
  // A 'failed' progress update is only provided if
  // a retry is not needed: if it is needed, a `waitingToRetry` progress update
  // will be generated in the FileDownloader
  if (status.isFinalState) {
    switch (status) {
      case TaskStatus.complete:
        {
          processProgressUpdate(task, progressComplete, sendPort);
          break;
        }
      case TaskStatus.failed:
        {
          if (!retryNeeded) {
            processProgressUpdate(task, progressFailed, sendPort);
          }
          break;
        }
      case TaskStatus.canceled:
        {
          processProgressUpdate(task, progressCanceled, sendPort);
          break;
        }
      case TaskStatus.notFound:
        {
          processProgressUpdate(task, progressNotFound, sendPort);
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
void processProgressUpdate(Task task, double progress, SendPort sendPort) {
  if (task.providesProgressUpdates) {
    sendPort.send(progress);
  }
}
