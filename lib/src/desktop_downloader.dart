import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'base_downloader.dart';
import 'desktop_downloader_isolate.dart';
import 'exceptions.dart';
import 'file_downloader.dart';
import 'models.dart';

const okResponses = [200, 201, 202, 203, 204, 205, 206];

/// Implementation of download functionality for desktop platforms
///
/// On desktop (MacOS, Linux, Windows) the download and upload are implemented
/// in Dart, as there is no native platform equivalent of URLSession or
/// WorkManager as there is on iOS and Android
class DesktopDownloader extends BaseDownloader {
  final _log = Logger('DesktopDownloader');
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
  Future<bool> enqueue(Task task,
      [TaskNotificationConfig? notificationConfig]) async {
    try {
      Uri.decodeFull(task.url);
    } catch (e) {
      _log.fine('Invalid url: ${task.url} error: $e');
      return false;
    }
    super.enqueue(task);
    _queue.add(task);
    processStatusUpdate(TaskStatusUpdate(task, TaskStatus.enqueued));
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
    final data = await getResumeData(task.taskId);
    final isResume = _resume.remove(task) && data != null;
    final filePath = await task.filePath();
    final tempFilePath = isResume
        ? data.data // always non-null
        : path.join((await getTemporaryDirectory()).path,
            'com.bbflight.background_downloader${Random().nextInt(1 << 32).toString()}');
    final requiredStartByte = data?.requiredStartByte ?? 0; // start for resume
    // spawn an isolate to do the task
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    errorPort.listen((message) {
      final exceptionDescription = (message as List).first as String;
      logError(task, exceptionDescription);
      processStatusUpdate(TaskStatusUpdate(
          task, TaskStatus.failed, TaskException(exceptionDescription)));
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
        // Process the message
        if (message is double) {
          // progress
          processProgressUpdate(TaskProgressUpdate(task, message));
        } else if (message is bool) {
          // canResume flag
          setCanResume(task, message);
        } else if (message is List) {
          switch (message[0] as String) {
            case 'statusUpdate':
              final status = message[1] as TaskStatus;
              if (status.isFinalState) {
                _remove(task);
              }
              processStatusUpdate(TaskStatusUpdate(
                  task,
                  status,
                  status == TaskStatus.failed
                      ? message[2] as TaskException
                      : null));
              break;

            case 'resumeData':
              setResumeData(
                  ResumeData(task, message[1] as String, message[2] as int));
              break;

            default:
              throw ArgumentError(
                  'Did not recognize message: ${message[0] as String}');
          }
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
      await cancelTasksWithIds(taskIds);
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
      processStatusUpdate(TaskStatusUpdate(task, TaskStatus.canceled));
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
  Future<bool> resume(Task task,
      [TaskNotificationConfig? notificationConfig]) async {
    if (await super.resume(task)) {
      _resume.add(task);
      return enqueue(task);
    }
    return false;
  }

  @override
  Future<Map<String, dynamic>> popUndeliveredData(Undelivered dataType) =>
      Future.value({});

  @override
  Future<Duration> getTaskTimeout() => Future.value(const Duration(days: 1));

  @override
  Future<void> setForceFailPostOnBackgroundChannel(bool value) {
    throw UnimplementedError();
  }

  @override
  Future<String?> moveToSharedStorage(String filePath,
      SharedStorage destination, String directory, String? mimeType) async {
    final destDirectoryPath =
        await getDestinationDirectoryPath(destination, directory);
    if (destDirectoryPath == null) {
      return null;
    }
    if (!await Directory(destDirectoryPath).exists()) {
      await Directory(destDirectoryPath).create(recursive: true);
    }
    final fileName = path.basename(filePath);
    final destFilePath = path.join(destDirectoryPath, fileName);
    try {
      await File(filePath).rename(destFilePath);
    } on FileSystemException catch (e) {
      _log.warning('Error moving $filePath to shared storage: $e');
      return null;
    }
    return destFilePath;
  }

  @override
  Future<String?> pathInSharedStorage(
      String filePath, SharedStorage destination, String directory) async {
    final destDirectoryPath =
        await getDestinationDirectoryPath(destination, directory);
    if (destDirectoryPath == null) {
      return null;
    }
    final fileName = path.basename(filePath);
    return path.join(destDirectoryPath, fileName);
  }

  /// Returns the path of the destination directory in shared storage, or null
  ///
  /// Only the .Downloads directory is supported on desktop.
  /// The [directory] is appended to the base Downloads directory.
  /// The directory at the returned path is not guaranteed to exist.
  Future<String?> getDestinationDirectoryPath(
      SharedStorage destination, String directory) async {
    if (destination != SharedStorage.downloads) {
      _log.finer('Desktop only supports .downloads destination');
      return null;
    }
    final downloadsDirectory = await getDownloadsDirectory();
    if (downloadsDirectory == null) {
      _log.warning('Could not obtain downloads directory');
      return null;
    }
    // remove leading and trailing slashes from [directory]
    var cleanDirectory = directory.replaceAll(RegExp(r'^/+'), '');
    cleanDirectory = cleanDirectory.replaceAll(RegExp(r'/$'), '');
    return cleanDirectory.isEmpty
        ? downloadsDirectory.path
        : path.join(downloadsDirectory.path, cleanDirectory);
  }

  @override
  Future<bool> openFile(Task? task, String? filePath, String? mimeType) async {
    final executable = Platform.isLinux
        ? 'xdg-open'
        : Platform.isMacOS
            ? 'open'
            : 'start';
    filePath ??= await task!.filePath();
    if (!await File(filePath).exists()) {
      _log.fine('File to open does not exist: $filePath');
      return false;
    }
    final result = await Process.run(executable, [filePath], runInShell: true);
    if (result.exitCode != 0) {
      _log.fine(
          'openFile command $executable returned exit code ${result.exitCode}');
    }
    return result.exitCode == 0;
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
