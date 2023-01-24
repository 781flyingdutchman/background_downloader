import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'models.dart';

/// Signature for a function you can register to be called
/// when the download state of a [task] changes.
typedef DownloadStatusCallback = void Function(
    BackgroundDownloadTask task, DownloadTaskStatus status);

/// Signature for a function you can register to be called
/// for every download progress change of a [task].
///
/// A successfully downloaded task will always finish with progress 1.0
/// [DownloadTaskStatus.failed] results in progress -1.0
/// [DownloadTaskStatus.canceled] results in progress -2.0
/// [DownloadTaskStatus.notFound] results in progress -3.0
/// [DownloadTaskStatus.waitingToRetry] results in progress -4.0
/// These constants are available as [progressFailed] etc
typedef DownloadProgressCallback = void Function(
    BackgroundDownloadTask task, double progress);

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static final _log = Logger('FileDownloader');
  static const defaultGroup = 'default';
  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.background_downloader.background');
  static http.Client? httpClient;
  static bool _initialized = false;
  static final _downloadCompleters =
      <BackgroundDownloadTask, Completer<DownloadTaskStatus>>{};
  static final _batches = <BackgroundDownloadBatch>[];

  static final _tasksWaitingToRetry = <BackgroundDownloadTask>[];

  /// Registered [DownloadStatusCallback] for each group
  static final statusCallbacks = <String, DownloadStatusCallback>{};

  /// Registered [DownloadProgressCallback] for each group
  static final progressCallbacks = <String, DownloadProgressCallback>{};

  /// StreamController for [BackgroundDownloadEvent] updates
  static var _updates = StreamController<BackgroundDownloadEvent>();

  /// Stream of [BackgroundDownloadEvent] updates for downloads that do
  /// not have a registered callback
  static Stream<BackgroundDownloadEvent> get updates => _updates.stream;

  /// True if [FileDownloader] was initialized
  static bool get initialized => _initialized;

  /// Initialize the downloader and potentially register callbacks to
  /// handle status and progress updates
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Note that callbacks will be called based on a task's [progressUpdates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [DownloadProgressCallback] and
  /// set the task's [progressUpdates] property to .progressUpdates or
  /// .statusChangeAndProgressUpdates
  static void initialize(
      {String group = defaultGroup,
      DownloadStatusCallback? downloadStatusCallback,
      DownloadProgressCallback? downloadProgressCallback}) {
    WidgetsFlutterBinding.ensureInitialized();
    _tasksWaitingToRetry.clear();
    _batches.clear();
    _downloadCompleters.clear();
    if (_updates.hasListener) {
      _log.warning('initialize called while the updates stream is still '
          'being listened to. That listener will no longer receive status updates.');
    }
    _updates = StreamController<BackgroundDownloadEvent>();
    // listen to the background channel, receiving updates on download status
    // or progress
    _backgroundChannel.setMethodCallHandler((call) async {
      final args = call.arguments as List<dynamic>;
      final task =
          BackgroundDownloadTask.fromJsonMap(jsonDecode(args.first as String));
      switch (call.method) {
        case 'statusUpdate':
          // Normal status updates are only sent here when the task is expected
          // to provide those.  The exception is a .failed status when a task
          // has retriesRemaining > 0: those are always sent here, and are
          // intercepted to hold the task and reschedule in the near future
          final downloadTaskStatus =
              DownloadTaskStatus.values[args.last as int];
          // intercept failed download if task has retries left
          if (downloadTaskStatus == DownloadTaskStatus.failed &&
              task.retriesRemaining > 0) {
            _provideStatusUpdate(task, DownloadTaskStatus.waitingToRetry);
            _provideProgressUpdate(task, progressWaitingToRetry);
            task.retriesRemaining--;
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
                  _provideStatusUpdate(task, DownloadTaskStatus.failed);
                  _provideProgressUpdate(task, progressFailed);
                }
              }
            });
          } else {
            // normal status update
            _provideStatusUpdate(task, downloadTaskStatus);
          }
          break;

        case 'progressUpdate':
          final progress = args.last as double;
          _provideProgressUpdate(task, progress);
          break;

        default:
          throw UnimplementedError(
              'Background channel method call ${call.method} not supported');
      }
    });
    // register any callbacks provided with initialization
    _initialized = true;
    if (downloadStatusCallback != null || downloadProgressCallback != null) {
      registerCallbacks(
          group: group,
          downloadStatusCallback: downloadStatusCallback,
          downloadProgressCallback: downloadProgressCallback);
    }
  }

  /// Provide the status update for this task to its callback or listener
  static void _provideStatusUpdate(
      BackgroundDownloadTask task, DownloadTaskStatus downloadTaskStatus) {
    if (task.providesStatusUpdates) {
      final downloadStatusCallback = statusCallbacks[task.group];
      if (downloadStatusCallback != null) {
        downloadStatusCallback(task, downloadTaskStatus);
      } else {
        if (_updates.hasListener) {
          _updates.add(BackgroundDownloadStatusEvent(task, downloadTaskStatus));
        } else {
          _log.warning('Requested status updates for task ${task.taskId} in '
              'group ${task.group} but no downloadStatusCallback '
              'was registered, and there is no listener to the '
              'updates stream');
        }
      }
    }
  }

  /// Provide the progress update for this task to its callback or listener
  static void _provideProgressUpdate(BackgroundDownloadTask task, progress) {
    if (task.providesProgressUpdates) {
      final progressUpdateCallback = progressCallbacks[task.group];
      if (progressUpdateCallback != null) {
        progressUpdateCallback(task, progress);
      } else if (_updates.hasListener) {
        _updates.add(BackgroundDownloadProgressEvent(task, progress));
      } else {
        _log.warning('Requested progress updates for task ${task.taskId} in '
            'group ${task.group} but no progressUpdateCallback '
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
  /// can be passed on with the [BackgroundDownloadTask] to ensure the
  /// appropriate callbacks are called for that group.
  ///
  /// Note that callbacks will be called based on a task's [progressUpdates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [DownloadProgressCallback] and
  /// set the task's [progressUpdates] property to .progressUpdates or
  /// .statusChangeAndProgressUpdates
  static void registerCallbacks(
      {String group = defaultGroup,
      DownloadStatusCallback? downloadStatusCallback,
      DownloadProgressCallback? downloadProgressCallback}) {
    _ensureInitialized();
    assert(downloadStatusCallback != null || (downloadProgressCallback != null),
        'Must provide a status update callback or a progress update callback, or both');
    if (downloadStatusCallback != null) {
      statusCallbacks[group] = downloadStatusCallback;
    }
    if (downloadProgressCallback != null) {
      progressCallbacks[group] = downloadProgressCallback;
    }
  }

  /// Start a new download task
  ///
  /// Returns true if successfully enqueued. A new task will also generate
  /// a [DownloadTaskStatus.running] update to the registered callback,
  /// if requested by its [progressUpdates] property
  static Future<bool> enqueue(BackgroundDownloadTask task) async {
    _ensureInitialized();
    return await _channel
            .invokeMethod<bool>('enqueue', [jsonEncode(task.toJsonMap())]) ??
        false;
  }

  /// Download a file
  ///
  /// Different from [enqueue], this method does not return until the file
  /// has been downloaded, or an error has occurred.  While it uses the same
  /// download mechanism as [enqueue], and will execute the download also when
  /// the app moves to the background, it is meant for downloads that are
  /// awaited while the app is in the foreground.
  ///
  /// Note that [group] is ignored as it is replaced with an internal group
  /// name '_foregroundDownload' to track status
  static Future<DownloadTaskStatus> download(
      BackgroundDownloadTask task) async {
    const groupName = '_foregroundDownload';

    /// internal callback function that completes the completer associated
    /// with this task
    internalCallback(BackgroundDownloadTask task, DownloadTaskStatus status) {
      if (status.isFinalState) {
        if (_batches.isNotEmpty) {
          // check if this task is part of a batch
          for (final batch in _batches) {
            if (batch.tasks.contains(task)) {
              batch.results[task] = status;
              if (batch.batchDownloadProgressCallback != null) {
                batch.batchDownloadProgressCallback!(
                    batch.numSucceeded, batch.numFailed);
              }
              break;
            }
          }
        }
        var downloadCompleter = _downloadCompleters.remove(task);
        downloadCompleter?.complete(status);
      }
    }

    registerCallbacks(
        group: groupName, downloadStatusCallback: internalCallback);
    final internalTask = task.copyWith(
        group: groupName,
        progressUpdates: DownloadTaskProgressUpdates.statusChange);
    final downloadCompleter = Completer<DownloadTaskStatus>();
    _downloadCompleters[internalTask] = downloadCompleter;
    final enqueueSuccess = await enqueue(internalTask);
    if (!enqueueSuccess) {
      _log.warning('Could not enqueue task $task}');
      return Future.value(DownloadTaskStatus.failed);
    }
    return downloadCompleter.future;
  }

  /// Enqueues a list of files to download and returns when all downloads
  /// have finished (successfully or otherwise). The returned value is a
  /// [BackgroundDownloadBatch] object that contains the original [tasks], the
  /// [results] and convenience getters to filter successful and failed results.
  ///
  /// If an optional [batchDownloadProgressCallback] function is provided, it will be
  /// called upon completion (successfully or otherwise) of each task in the
  /// batch, with two parameters: the number of succeeded and the number of
  /// failed tasks. The callback can be used, for instance, to show a progress
  /// indicator for the batch, where
  ///    double percent_complete = (succeeded + failed) / tasks.length
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [group] and [progressUpdates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [BackgroundDownloadBatch]
  /// object.
  static Future<BackgroundDownloadBatch> downloadBatch(
      final List<BackgroundDownloadTask> tasks,
      [BatchDownloadProgressCallback? batchDownloadProgressCallback]) async {
    assert(tasks.isNotEmpty, 'List of tasks cannot be empty');
    if (batchDownloadProgressCallback != null) {
      batchDownloadProgressCallback(0, 0); // initial callback
    }
    final batch = BackgroundDownloadBatch(tasks, batchDownloadProgressCallback);
    _batches.add(batch);
    final downloadFutures = <Future<DownloadTaskStatus>>[];
    var counter = 0;
    for (final task in tasks) {
      downloadFutures.add(download(task));
      counter++;
      if (counter % 3 == 0) {
        // To prevent blocking the UI we 'yield' for a few ms after every 3
        // tasks we enqueue
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    await Future.wait(downloadFutures); // wait for all downloads to complete
    _batches.remove(batch);
    return batch;
  }

  /// Resets the downloader by cancelling all ongoing download tasks within
  /// the provided group
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [DownloadTaskStatus.canceled] update to the registered callback, if
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
  static Future<List<BackgroundDownloadTask>> allTasks(
      {String group = defaultGroup,
      bool includeTasksWaitingToRetry = true}) async {
    _ensureInitialized();
    final result =
        await _channel.invokeMethod<List<dynamic>?>('allTasks', group) ?? [];
    final tasks = result
        .map((e) => BackgroundDownloadTask.fromJsonMap(jsonDecode(e as String)))
        .toList();
    if (includeTasksWaitingToRetry) {
      tasks.addAll(_tasksWaitingToRetry.where((task) => task.group == group));
    }
    return tasks;
  }

  /// Delete all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [DownloadTaskStatus.canceled] update to
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
      _provideStatusUpdate(task, DownloadTaskStatus.canceled);
      _provideProgressUpdate(task, progressCanceled);
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

  /// Return [BackgroundDownloadTask] for the given [taskId], or null
  /// if not found.
  ///
  /// Only running tasks are guaranteed to be returned, but returning a task
  /// does not guarantee that the task is still running. To keep track of
  /// the status of tasks, use a [DownloadStatusCallback]
  static Future<BackgroundDownloadTask?> taskForId(String taskId) async {
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
      return BackgroundDownloadTask.fromJsonMap(jsonDecode(jsonString));
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
  ///
  /// The request will abide by the [retries] set on the [request], and set
  /// [headers] included in the [request]
  ///
  /// The [http.Client] object used for this request is the [httpClient] field of
  /// the downloader. If not set, the default [http.Client] will be used.
  /// The request is executed on an Isolate, to ensure minimal interference
  /// with the main Isolate
  Future<http.Response> request(Request request) => compute(doRequest, request);

  /// Assert that the [FileDownloader] has been initialized
  static void _ensureInitialized() {
    assert(_initialized, 'FileDownloader must be initialized before use');
  }

  /// Destroy the [FileDownloader]. Subsequent use requires initialization
  static void destroy() {
    _initialized = false;
    _tasksWaitingToRetry.clear();
    _batches.clear();
    _downloadCompleters.clear();
    statusCallbacks.clear();
    progressCallbacks.clear();
  }
}

/// Performs the actual server request, with retries
///
/// This function is run on an Isolate to ensure performance on the main
/// Isolate is not affected
Future<http.Response> doRequest(Request request) async {
  FileDownloader.httpClient ??= http.Client();
  final client = FileDownloader.httpClient!;
  while (request.retriesRemaining >= 0) {
    final response = request.post == null
        ? await client.get(Uri.parse(request.url), headers: request.headers)
        : await client.post(Uri.parse(request.url),
            headers: request.headers, body: request.post);
    if ([200, 201, 202, 203, 204, 205, 206, 404]
        .contains(response.statusCode)) {
      return response;
    }
    // error, retry if allowed
    request.retriesRemaining--;
    if (request.retriesRemaining < 0) {
      return response; // final response with error
    }
    final waitTime = Duration(
        seconds: pow(2, (request.retries - request.retriesRemaining)).toInt());
    await Future.delayed(waitTime);
  }
  throw ArgumentError('Request to ${request.url} had negative '
      'retriesRemaining');
}
