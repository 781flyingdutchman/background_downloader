import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'models.dart';

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static final _log = Logger('FileDownloader');
  static const defaultGroup = 'default';
  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.background_downloader.background');
  static http.Client? httpClient;
  static bool _initialized = false;
  static final _taskCompleters = <Task, Completer<TaskStatus>>{};
  static final _batches = <Batch>[];

  static final _tasksWaitingToRetry = <Task>[];

  /// Registered [TaskStatusCallback] for each group
  static final _groupStatusCallbacks = <String, TaskStatusCallback>{};

  /// Registered [TaskProgressCallback] for each group
  static final _groupProgressCallbacks = <String, TaskProgressCallback>{};

  /// Registered [TaskStatusCallback] for convenience down/upload tasks
  static final _taskStatusCallbacks = <String, void Function(TaskStatus)>{};

  /// Registered [TaskProgressCallback] for convenience down/upload tasks
  static final _taskProgressCallbacks = <String, void Function(double)>{};

  /// StreamController for [TaskUpdate] updates
  static var _updates = StreamController<TaskUpdate>();

  /// Stream of [TaskUpdate] updates for downloads that do
  /// not have a registered callback
  static Stream<TaskUpdate> get updates => _updates.stream;

  static StreamSubscription? _desktopDownloaderUpdates;

  /// True if [FileDownloader] was initialized
  static bool get initialized => _initialized;

  /// Initialize the Downloader and potentially register callbacks to
  /// handle status and progress updates
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Note that callbacks will be called based on a task's [updates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [TaskProgressCallback] and
  /// set the task's [updates] property to [Updates.progress] or
  /// [Updates.statusAndProgress]
  static void initialize(
      {String group = defaultGroup,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback}) {
    if (_initialized) {
      _log.warning('Calling initialize when Downloader is already initialized. '
          'This may lead to unexpected behavior and missed status/progress updates. '
          'Prefer calling .destroy before re-initialization');
    }
    WidgetsFlutterBinding.ensureInitialized();
    if (DesktopDownloader().supportsThisPlatform) {
      DesktopDownloader().initialize();
      // listen to updates and pass on to the processors
      _desktopDownloaderUpdates?.cancel();
      _desktopDownloaderUpdates = DesktopDownloader().updates.listen(
          (update) {
            final args = update as List;
            final task = args.first;
            final message = args.last;
            if (message is TaskStatus) {
              _processStatusUpdate(task, message);
            } else if (message is double) {
              _processProgressUpdate(task, message);
            } else {
              _log.warning('Received message with unknown type '
                  '${message.runtimeType} from DesktopDownloader');
            }

      });
    }
    if (_updates.hasListener) {
      _log.warning('initialize called while the updates stream is still '
          'being listened to. That listener will no longer receive status updates.');
    }
    _updates = StreamController<TaskUpdate>();
    // listen to the background channel, receiving updates on download status
    // or progress
    _backgroundChannel.setMethodCallHandler((call) async {
      final args = call.arguments as List<dynamic>;
      final task = Task.createFromJsonMap(jsonDecode(args.first as String));
      switch (call.method) {
        case 'statusUpdate':
          final taskStatus = TaskStatus.values[args.last as int];
          _processStatusUpdate(task, taskStatus);
          break;

        case 'progressUpdate':
          final progress = args.last as double;
          _emitProgressUpdate(task, progress);
          break;

        default:
          throw UnimplementedError(
              'Background channel method call ${call.method} not supported');
      }
    });
    // register any callbacks provided with initialization
    _initialized = true;
    if (taskStatusCallback != null || taskProgressCallback != null) {
      registerCallbacks(
          group: group,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback);
    }
  }

  /// Process status update coming from plugin or [DesktopDownloader]
  static void _processStatusUpdate(Task task, TaskStatus taskStatus) {
    // Normal status updates are only sent here when the task is expected
    // to provide those.  The exception is a .failed status when a task
    // has retriesRemaining > 0: those are always sent here, and are
    // intercepted to hold the task and reschedule in the near future
    if (taskStatus == TaskStatus.failed && task.retriesRemaining > 0) {
      _emitStatusUpdate(task, TaskStatus.waitingToRetry);
      _emitProgressUpdate(task, progressWaitingToRetry);
      task.decreaseRetriesRemaining();
      _tasksWaitingToRetry.add(task);
      final waitTime = Duration(
          seconds:
          pow(2, (task.retries - task.retriesRemaining)).toInt());
      _log.finer(
          'TaskId ${task.taskId} failed, waiting ${waitTime.inSeconds}'
              ' seconds before retrying. ${task.retriesRemaining}'
              ' retries remaining');
      Future.delayed(waitTime, () async {
        // after delay, enqueue task again if it's still waiting
        if (_tasksWaitingToRetry.remove(task)) {
          if (!await enqueue(task)) {
            _log.warning(
                'Could not enqueue task $task after retry timeout');
            _emitStatusUpdate(task, TaskStatus.failed);
            _emitProgressUpdate(task, progressFailed);
          }
        }
      });
    } else {
      // normal status update
      _emitStatusUpdate(task, taskStatus);
    }
  }

  static void _processProgressUpdate(Task task, double progress) {
    _emitProgressUpdate(task, progress);
  }

  /// Emits the status update for this task to its callback or listener
  static void _emitStatusUpdate(Task task, TaskStatus taskStatus) {
    if (task.providesStatusUpdates) {
      final taskStatusCallback = _groupStatusCallbacks[task.group];
      if (taskStatusCallback != null) {
        taskStatusCallback(task, taskStatus);
      } else {
        if (_updates.hasListener) {
          _updates.add(TaskStatusUpdate(task, taskStatus));
        } else {
          _log.warning('Requested status updates for task ${task.taskId} in '
              'group ${task.group} but no TaskStatusCallback '
              'was registered, and there is no listener to the '
              'updates stream');
        }
      }
    }
  }

  /// Emit the progress update for this task to its callback or listener
  static void _emitProgressUpdate(Task task, progress) {
    if (task.providesProgressUpdates) {
      final taskProgressCallback = _groupProgressCallbacks[task.group];
      if (taskProgressCallback != null) {
        taskProgressCallback(task, progress);
      } else if (_updates.hasListener) {
        _updates.add(TaskProgressUpdate(task, progress));
      } else {
        _log.warning('Requested progress updates for task ${task.taskId} in '
            'group ${task.group} but no TaskProgressCallback '
            'was registered, and there is no listener to the '
            'updates stream');
      }
    }
  }

  /// Register status or progress callbacks to monitor download progress.
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Different callbacks can be set for different groups, and the group
  /// can be passed on with the [DownloadTask] to ensure the
  /// appropriate callbacks are called for that group.
  ///
  /// Note that callbacks will be called based on a task's [updates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [TaskProgressCallback] and
  /// set the task's [updates] property to [Updates.progress] or
  /// [Updates.statusAndProgress]
  static void registerCallbacks(
      {String group = defaultGroup,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback}) {
    _ensureInitialized();
    assert(taskStatusCallback != null || (taskProgressCallback != null),
        'Must provide a TaskStatusCallback or a TaskProgressCallback, or both');
    if (taskStatusCallback != null) {
      _groupStatusCallbacks[group] = taskStatusCallback;
    }
    if (taskProgressCallback != null) {
      _groupProgressCallbacks[group] = taskProgressCallback;
    }
  }

  /// Start a new task
  ///
  /// Returns true if successfully enqueued. A new task will also generate
  /// a [TaskStatus.enqueued] update to the registered callback,
  /// if requested by its [updates] property
  static Future<bool> enqueue(Task task) async {
    _ensureInitialized();
    if (Platform.isMacOS) {
      return DesktopDownloader().enqueue(task);
    }
    return await _channel
            .invokeMethod<bool>('enqueue', [jsonEncode(task.toJsonMap())]) ??
        false;
  }

  /// Download a file and return the final [TaskStatus]
  ///
  /// Different from [enqueue], this method does not return until the file
  /// has been downloaded, or an error has occurred.  While it uses the same
  /// download mechanism as [enqueue], and will execute the download also when
  /// the app moves to the background, it is meant for downloads that are
  /// awaited while the app is in the foreground.
  ///
  /// Optional callbacks for status and progress updates may be
  /// added. These function only take a [TaskStatus] or [double] argument as
  /// the task they refer to is expected to be captured in the closure for
  /// this call.
  /// For example `Downloader.download(task, onStatus: (status) =>`
  /// `print('Status for ${task.taskId} is $status);`
  ///
  /// Note that the task's [group] is ignored and will be replaced with an
  /// internal group name '_enqueueAndWait' to track status
  static Future<TaskStatus> download(DownloadTask task,
          {void Function(TaskStatus)? onStatus,
          void Function(double)? onProgress}) =>
      _enqueueAndAwait(task, onStatus: onStatus, onProgress: onProgress);

  /// Upload a file and return the final [TaskStatus]
  ///
  /// Different from [enqueue], this method does not return until the file
  /// has been uploaded, or an error has occurred.  While it uses the same
  /// upload mechanism as [enqueue], and will execute the upload also when
  /// the app moves to the background, it is meant for uploads that are
  /// awaited while the app is in the foreground.
  ///
  /// Optional callbacks for status and progress updates may be
  /// added. These function only take a [TaskStatus] or [double] argument as
  /// the task they refer to is expected to be captured in the closure for
  /// this call.
  /// For example `Downloader.download(task, onStatus: (status) =>`
  /// `print('Status for ${task.taskId} is $status);`
  ///
  /// Note that the task's [group] is ignored and will be replaced with an
  /// internal group name '_enqueueAndWait' to track status
  static Future<TaskStatus> upload(UploadTask task,
          {void Function(TaskStatus)? onStatus,
          void Function(double)? onProgress}) =>
      _enqueueAndAwait(task, onStatus: onStatus, onProgress: onProgress);

  /// Enqueue the [task] and wait for completion
  ///
  /// Returns the final [TaskStatus] of the [task]
  static Future<TaskStatus> _enqueueAndAwait(Task task,
      {void Function(TaskStatus)? onStatus,
      void Function(double)? onProgress}) async {
    const groupName = '_enqueueAndAwait';

    /// Internal callback function that passes the update on to different
    /// callbacks
    ///
    /// The update is passed on to:
    /// 1. Task-specific callback, passed as parameter to call
    /// 2. Batch-related callback, if this task is part of a batch operation
    ///    and is in a final state
    ///
    /// If the task is in final state, also removes the reference to the
    /// task-specific callbacks and completes the completer associated
    /// with this task
    internalStatusCallback(Task task, TaskStatus status) {
      _taskStatusCallbacks[task.taskId]?.call(status);
      if (status.isFinalState) {
        if (_batches.isNotEmpty) {
          // check if this task is part of a batch
          for (final batch in _batches) {
            if (batch.tasks.contains(task)) {
              batch.results[task] = status;
              if (batch.batchProgressCallback != null) {
                batch.batchProgressCallback!(
                    batch.numSucceeded, batch.numFailed);
              }
              break;
            }
          }
        }
        _taskStatusCallbacks.remove(task.taskId);
        _taskProgressCallbacks.remove(task.taskId);
        var taskCompleter = _taskCompleters.remove(task);
        taskCompleter?.complete(status);
      }
    }

    /// Internal callback function that only passes progress updates on
    /// to the task-specific progress callback passed as parameter to call
    internalProgressCallBack(Task task, double progress) {
      _taskProgressCallbacks[task.taskId]?.call(progress);
    }

    // register the internal callbacks and store the task-specific ones
    registerCallbacks(
        group: groupName,
        taskStatusCallback: internalStatusCallback,
        taskProgressCallback: internalProgressCallBack);
    final internalTask = task.copyWith(
        group: groupName,
        updates:
            onProgress != null ? Updates.statusAndProgress : Updates.status);
    if (onStatus != null) {
      _taskStatusCallbacks[task.taskId] = onStatus;
    }
    if (onProgress != null) {
      _taskProgressCallbacks[task.taskId] = onProgress;
    }
    // Create taskCompleter and enqueue the task.
    // The completer will be completed in the internal status callback
    final taskCompleter = Completer<TaskStatus>();
    _taskCompleters[internalTask] = taskCompleter;
    final enqueueSuccess = await enqueue(internalTask);
    if (!enqueueSuccess) {
      _log.warning('Could not enqueue task $task}');
      return Future.value(TaskStatus.failed);
    }
    return taskCompleter.future;
  }

  /// Enqueues a list of files to download and returns when all downloads
  /// have finished (successfully or otherwise). The returned value is a
  /// [Batch] object that contains the original [tasks], the
  /// [results] and convenience getters to filter successful and failed results.
  ///
  /// If an optional [batchProgressCallback] function is provided, it will be
  /// called upon completion (successfully or otherwise) of each task in the
  /// batch, with two parameters: the number of succeeded and the number of
  /// failed tasks. The callback can be used, for instance, to show a progress
  /// indicator for the batch, where
  ///    double percent_complete = (succeeded + failed) / tasks.length
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [Task.group] and [Task.updates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [Batch]
  /// object.
  static Future<Batch> downloadBatch(final List<DownloadTask> tasks,
          [BatchProgressCallback? batchProgressCallback]) =>
      _enqueueAndAwaitBatch(tasks, batchProgressCallback);

  /// Enqueues a list of files to upload and returns when all uploads
  /// have finished (successfully or otherwise). The returned value is a
  /// [Batch] object that contains the original [tasks], the
  /// [results] and convenience getters to filter successful and failed results.
  ///
  /// If an optional [batchProgressCallback] function is provided, it will be
  /// called upon completion (successfully or otherwise) of each task in the
  /// batch, with two parameters: the number of succeeded and the number of
  /// failed tasks. The callback can be used, for instance, to show a progress
  /// indicator for the batch, where
  ///    double percent_complete = (succeeded + failed) / tasks.length
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [Task.group] and [Task.updates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [Batch]
  /// object.
  static Future<Batch> uploadBatch(final List<UploadTask> tasks,
          [BatchProgressCallback? batchProgressCallback]) =>
      _enqueueAndAwaitBatch(tasks, batchProgressCallback);

  /// Enqueue a list of tasks and wait for completion
  ///
  /// Returns a [Batch] object
  static Future<Batch> _enqueueAndAwaitBatch(final List<Task> tasks,
      [BatchProgressCallback? batchProgressCallback]) async {
    assert(tasks.isNotEmpty, 'List of tasks cannot be empty');
    if (batchProgressCallback != null) {
      batchProgressCallback(0, 0); // initial callback
    }
    final batch = Batch(tasks, batchProgressCallback);
    _batches.add(batch);
    final taskFutures = <Future<TaskStatus>>[];
    var counter = 0;
    for (final task in tasks) {
      taskFutures.add(_enqueueAndAwait(task));
      counter++;
      if (counter % 3 == 0) {
        // To prevent blocking the UI we 'yield' for a few ms after every 3
        // tasks we enqueue
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    await Future.wait(taskFutures); // wait for all tasks to complete
    _batches.remove(batch);
    return batch;
  }

  /// Resets the downloader by cancelling all ongoing tasks within
  /// the provided group
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [TaskStatus.canceled] update to the registered callback, if
  /// requested
  static Future<int> reset({String? group = defaultGroup}) async {
    _ensureInitialized();
    _tasksWaitingToRetry.clear();
    return await _channel.invokeMethod<int>('reset', group) ?? -1;
  }

  /// Returns a list of taskIds of all tasks currently active in this group
  ///
  /// Active means enqueued or running, and if [includeTasksWaitingToRetry] is
  /// true also tasks that are waiting to be retried
  static Future<List<String>> allTaskIds(
          {String group = defaultGroup,
          bool includeTasksWaitingToRetry = true}) async =>
      (await allTasks(
              group: group,
              includeTasksWaitingToRetry: includeTasksWaitingToRetry))
          .map((task) => task.taskId)
          .toList();

  /// Returns a list of all tasks currently active in this group
  ///
  /// Active means enqueued or running, and if [includeTasksWaitingToRetry] is
  /// true also tasks that are waiting to be retried
  static Future<List<Task>> allTasks(
      {String group = defaultGroup,
      bool includeTasksWaitingToRetry = true}) async {
    _ensureInitialized();
    final result =
        await _channel.invokeMethod<List<dynamic>?>('allTasks', group) ?? [];
    final tasks = result
        .map((e) => Task.createFromJsonMap(jsonDecode(e as String)))
        .toList();
    if (includeTasksWaitingToRetry) {
      tasks.addAll(_tasksWaitingToRetry.where((task) => task.group == group));
    }
    return tasks;
  }

  /// Delete all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [TaskStatus.canceled] update to
  /// the registered callback, if requested
  static Future<bool> cancelTasksWithIds(List<String> taskIds) async {
    _ensureInitialized();
    final matchingTasksWaitingToRetry = _tasksWaitingToRetry
        .where((task) => taskIds.contains(task.taskId))
        .toList(growable: false);
    final matchingTaskIdsWaitingToRetry = matchingTasksWaitingToRetry
        .map((task) => task.taskId)
        .toList(growable: false);
    // remove tasks waiting to retry from the list so they won't be retried
    for (final task in matchingTasksWaitingToRetry) {
      _tasksWaitingToRetry.remove(task);
      _emitStatusUpdate(task, TaskStatus.canceled);
      _emitProgressUpdate(task, progressCanceled);
    }
    // cancel remaining taskIds on the native platform
    final remainingTaskIds = taskIds
        .where((taskId) => !matchingTaskIdsWaitingToRetry.contains(taskId))
        .toList(growable: false);
    if (remainingTaskIds.isNotEmpty) {
      return await _channel.invokeMethod<bool>(
              'cancelTasksWithIds', remainingTaskIds) ??
          false;
    }
    return true;
  }

  /// Return [Task] for the given [taskId], or null
  /// if not found.
  ///
  /// Only running tasks are guaranteed to be returned, but returning a task
  /// does not guarantee that the task is still running. To keep track of
  /// the status of tasks, use a [TaskStatusCallback]
  static Future<Task?> taskForId(String taskId) async {
    _ensureInitialized();
    // check if task with this Id is waiting to retry
    final taskWaitingToRetry =
        _tasksWaitingToRetry.where((task) => task.taskId == taskId);
    if (taskWaitingToRetry.isNotEmpty) {
      return taskWaitingToRetry.first;
    }
    // if not, ask the native platform for the task matching this id
    final jsonString = await _channel.invokeMethod<String>('taskForId', taskId);
    if (jsonString != null) {
      return Task.createFromJsonMap(jsonDecode(jsonString));
    }
    return null;
  }

  /// Perform a server request for this [request]
  ///
  /// A server request returns an [http.Response] object that includes
  /// the [body] as String, the [bodyBytes] as [UInt8List] and the [json]
  /// representation if available.
  /// It also contains the [statusCode] and [reasonPhrase] that may indicate
  /// an error, and several other fields that may be useful.
  /// A local error (e.g. a SocketException) will yield [statusCode] 499, with
  /// details in the [reasonPhrase]
  ///
  /// The request will abide by the [retries] set on the [request], and set
  /// [headers] included in the [request]
  ///
  /// The [http.Client] object used for this request is the [httpClient] field of
  /// the downloader. If not set, the default [http.Client] will be used.
  /// The request is executed on an Isolate, to ensure minimal interference
  /// with the main Isolate
  static Future<http.Response> request(Request request) =>
      compute(doRequest, request);

  /// Assert that the [FileDownloader] has been initialized
  static void _ensureInitialized() {
    assert(_initialized, 'FileDownloader must be initialized before use');
  }

  /// Destroy the [FileDownloader]. Subsequent use requires initialization
  static void destroy() {
    _initialized = false;
    _tasksWaitingToRetry.clear();
    _batches.clear();
    _taskCompleters.clear();
    _groupStatusCallbacks.clear();
    _groupProgressCallbacks.clear();
    _taskStatusCallbacks.clear();
    _taskProgressCallbacks.clear();
    _desktopDownloaderUpdates?.cancel();
    _desktopDownloaderUpdates = null;
  }
}

/// Performs the actual server request, with retries
///
/// This function is run on an Isolate to ensure performance on the main
/// Isolate is not affected
Future<http.Response> doRequest(Request request) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    if (kDebugMode) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    }
  });
  final log = Logger('FileDownloader.request');
  FileDownloader.httpClient ??= http.Client();
  final client = FileDownloader.httpClient!;
  var response = http.Response('', 499,
      reasonPhrase: 'Not attempted'); // dummy to start with
  while (request.retriesRemaining >= 0) {
    try {
      response = request.post == null
          ? await client.get(Uri.parse(request.url), headers: request.headers)
          : await client.post(Uri.parse(request.url),
              headers: request.headers, body: request.post);
      if ([200, 201, 202, 203, 204, 205, 206, 404]
          .contains(response.statusCode)) {
        return response;
      }
    } catch (e) {
      log.warning(e);
      response = http.Response('', 499, reasonPhrase: e.toString());
    }
    // error, retry if allowed
    request.decreaseRetriesRemaining();
    if (request.retriesRemaining < 0) {
      return response; // final response with error
    }
    final waitTime = Duration(
        seconds: pow(2, (request.retries - request.retriesRemaining)).toInt());
    await Future.delayed(waitTime);
  }
  throw ArgumentError('Request to ${request.url} had no retries remaining');
}
