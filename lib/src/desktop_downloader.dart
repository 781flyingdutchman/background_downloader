import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'base_downloader.dart';
import 'desktop_downloader_isolate.dart';
import 'file_downloader.dart';
import 'models.dart';

const okResponses = [200, 201, 202, 203, 204, 205, 206];

/// Implementation of download functionality for desktop platforms
///
/// On desktop (MacOS, Linux, Windows) the download and upload are implemented
/// in Dart, as there is no native platform equivalent of URLSession or
/// WorkManager as there is on iOS and Android
class DesktopDownloader extends BaseDownloader {
  final _log = Logger('FileDownloader');
  final maxConcurrent = 5;
  static final DesktopDownloader _singleton = DesktopDownloader._internal();
  final _queue = Queue<Task>();
  final _running = Queue<Task>(); // subset that is running
  final _resume = <Task>{};
  final _isolateSendPorts =
      <Task, SendPort?>{}; // isolate SendPort for running task
  static final httpClient = http.Client();

  factory DesktopDownloader() => _singleton;

  DesktopDownloader._internal();

  @override
  Future<bool> enqueue(Task task) async {
    super.enqueue(task);
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
    final isResume = _resume.remove(task) && resumeData[task] != null;
    final filePath = await task.filePath();
    final tempFilePath = isResume
        ? resumeData[task]?.first as String? ?? "" // always non-null
        : path.join((await getTemporaryDirectory()).path,
            'com.bbflight.background_downloader${Random().nextInt(1 << 32).toString()}');
    final requiredStartByte =
        resumeData[task]?.last as int? ?? 0; // start for resume
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
    sendPort.send([task, filePath, tempFilePath, requiredStartByte, isResume]);
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
        // Process the status or progress update, or canResume flag
        if (message is TaskStatus) {
          // status
          processStatusUpdate(task, message);
        } else if (message is double) {
          // progress
          processProgressUpdate(task, message);
        } else if (message is bool) {
          // canResume flag
          setCanResume(task, message);
        } else if (message is List) {
          // resume data
          assert(message[0] as String == 'resumeData',
              'Only recognize resume data');
          setResumeData(task, message[1] as String, message[2] as int);
        } else if (message is String) {
          // log message
          _log.finest(message);
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
    final retryAndPausedTaskCount = await super.reset(group);
    final inQueueIds =
        _queue.where((task) => task.group == group).map((task) => task.taskId);
    final runningIds = _running
        .where((task) => task.group == group)
        .map((task) => task.taskId);
    final taskIds = [...inQueueIds, ...runningIds];
    if (taskIds.isNotEmpty) {
      cancelTasksWithIds(taskIds);
    }
    return retryAndPausedTaskCount + taskIds.length;
  }

  @override
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final retryAndPausedTasks =
        await super.allTasks(group, includeTasksWaitingToRetry);
    final inQueue = _queue.where((task) => task.group == group);
    final running = _running.where((task) => task.group == group);
    return [...retryAndPausedTasks, ...inQueue, ...running];
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
  Future<bool> pause(Task task) async {
    final sendPort = _isolateSendPorts[task];
    if (sendPort != null) {
      sendPort.send('pause');
      return true;
    }
    return false;
  }

  @override
  Future<bool> resume(Task task) async {
    if (await super.resume(task)) {
      _resume.add(task);
      return enqueue(task);
    }
    return false;
  }

  @override
  Future<Duration> getTaskTimeout() => Future.value(const Duration(days: 1));

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
