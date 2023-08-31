import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'base_downloader.dart';
import 'database.dart';
import 'web_downloader.dart' if (dart.library.io) 'desktop_downloader.dart';
import 'exceptions.dart';
import 'localstore/localstore.dart';
import 'models.dart';
import 'persistent_storage.dart';

/// Provides access to all functions of the plugin in a single place.
interface class FileDownloader {
  final _log = Logger('FileDownloader');
  static FileDownloader? _singleton;

  /// If no group is specified the default group name will be used
  static const defaultGroup = 'default';

  /// Calls to [download], [upload], [downloadBatch] and [uploadBatch] are
  /// monitored 'internally' in this special group
  static const awaitGroup = 'await';

  /// Database where tracked tasks are stored.
  ///
  /// Activate tracking by calling [trackTasks], and access the records in the
  /// database via this [database] object.
  late final Database database;

  final _taskCompleters = <Task, Completer<TaskStatusUpdate>>{};
  final _batches = <Batch>[];
  late final BaseDownloader _downloader;

  /// Do not use: for testing only
  @visibleForTesting
  BaseDownloader get downloaderForTesting => _downloader;

  /// Registered short status callback for convenience down/upload tasks
  ///
  /// Short callbacks omit the [Task] as they are available from the closure
  final _shortTaskStatusCallbacks = <String, void Function(TaskStatus)>{};

  /// Registered short progress callback for convenience down/upload tasks
  ///
  /// Short callbacks omit the [Task] as they are available from the closure
  final _shortTaskProgressCallbacks = <String, void Function(double)>{};

  /// Registered [TaskStatusCallback] for convenience batch down/upload tasks
  final _taskStatusCallbacks = <String, TaskStatusCallback>{};

  /// Registered [TaskProgressCallback] for convenience batch down/upload tasks
  final _taskProgressCallbacks = <String, TaskProgressCallback>{};

  factory FileDownloader({PersistentStorage? persistentStorage}) {
    assert(
        _singleton == null || persistentStorage == null,
        'You can only supply a persistentStorage on the very first call to '
        'FileDownloader()');
    _singleton ??= FileDownloader._internal(
        persistentStorage ?? LocalStorePersistentStorage());
    return _singleton!;
  }

  FileDownloader._internal(PersistentStorage persistentStorage) {
    database = Database(persistentStorage);
    _downloader = BaseDownloader.instance(persistentStorage, database);
  }

  /// Stream of [TaskUpdate] updates for downloads that do
  /// not have a registered callback
  Stream<TaskUpdate> get updates => _downloader.updates.stream;

  /// Configures the downloader
  ///
  /// Configuration is either a single configItem or a list of configItems.
  /// Each configItem is a (String, dynamic) where the String is the config
  /// type and 'dynamic' can be any appropriate parameter, including another Record.
  /// [globalConfig] is routed to every platform, whereas the platform specific
  /// ones only get routed to that platform, after the global configs have
  /// completed.
  /// If a config type appears more than once, they will all be executed in order,
  /// with [globalConfig] executed before the platform-specific config.
  ///
  /// Returns a list of (String, String) which is the config type and a response
  /// which is empty if OK, 'not implemented' if the item could not be recognized and
  /// processed, or may contain other error/warning information
  ///
  /// Please see [CONFIG.md](https://github.com/781flyingdutchman/background_downloader/blob/main/CONFIG.md)
  /// for more information
  Future<List<(String, String)>> configure(
          {dynamic globalConfig,
          dynamic androidConfig,
          dynamic iOSConfig,
          dynamic desktopConfig}) =>
      _downloader.configure(
          globalConfig: globalConfig,
          androidConfig: androidConfig,
          iOSConfig: iOSConfig,
          desktopConfig: desktopConfig);

  /// Register status or progress callbacks to monitor download progress, and
  /// [TaskNotificationTapCallback] to respond to user tapping a notification.
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Note that callbacks will be called based on a task's [updates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [TaskProgressCallback] and
  /// set the task's [updates] property to [Updates.progress] or
  /// [Updates.statusAndProgress].
  ///
  /// For notification callbacks, make sure your AndroidManifest includes
  /// android:launchMode="singleTask" to ensure proper behavior when a
  /// notification is tapped.
  ///
  /// Different callbacks can be set for different groups, and the group
  /// can be passed on with the [Task] to ensure the
  /// appropriate callbacks are called for that group.
  /// For the `taskNotificationTapCallback` callback, the `defaultGroup` callback
  /// is used when calling 'convenience' functions like `FileDownloader().download`
  ///
  /// The call returns the [FileDownloader] to make chaining easier
  FileDownloader registerCallbacks(
      {String group = defaultGroup,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback,
      TaskNotificationTapCallback? taskNotificationTapCallback}) {
    assert(
        taskStatusCallback != null ||
            taskProgressCallback != null ||
            taskNotificationTapCallback != null,
        'Must provide at least one callback');
    if (taskStatusCallback != null) {
      _downloader.groupStatusCallbacks[group] = taskStatusCallback;
    }
    if (taskProgressCallback != null) {
      _downloader.groupProgressCallbacks[group] = taskProgressCallback;
    }
    if (taskNotificationTapCallback != null) {
      _downloader.groupNotificationTapCallbacks[group] =
          taskNotificationTapCallback;
      if (group == defaultGroup) {
        _downloader.groupNotificationTapCallbacks[awaitGroup] =
            taskNotificationTapCallback;
      }
    }
    return this;
  }

  /// Unregister a previously registered [TaskStatusCallback], [TaskProgressCallback]
  /// or [TaskNotificationTapCallback].
  ///
  /// [group] defaults to the [FileDownloader.defaultGroup]
  /// If [callback] is null, all callbacks for the [group] are unregistered
  FileDownloader unregisterCallbacks(
      {String group = defaultGroup, Function? callback}) {
    if (callback != null) {
      // remove specific callback
      if (_downloader.groupStatusCallbacks[group] == callback) {
        _downloader.groupStatusCallbacks.remove(group);
      }
      if (_downloader.groupProgressCallbacks[group] == callback) {
        _downloader.groupProgressCallbacks.remove(group);
      }
      if (_downloader.groupNotificationTapCallbacks[group] == callback) {
        _downloader.groupNotificationTapCallbacks.remove(group);
      }
    } else {
      // remove all callbacks related to group
      _downloader.groupStatusCallbacks.remove(group);
      _downloader.groupProgressCallbacks.remove(group);
      _downloader.groupNotificationTapCallbacks.remove(group);
    }
    return this;
  }

  /// Enqueue a new [Task]
  ///
  /// Returns true if successfully enqueued. A new task will also generate
  /// a [TaskStatus.enqueued] update to the registered callback,
  /// if requested by its [updates] property
  ///
  /// Use [enqueue] instead of the convenience functions (like
  /// [download] and [upload]) if:
  /// - your download/upload is likely to take long and may require
  ///   running in the background
  /// - you want to monitor tasks centrally, via a listener
  /// - you want more detailed progress information
  ///   (e.g. file size, network speed, time remaining)
  Future<bool> enqueue(Task task) => _downloader.enqueue(task);

  /// Download a file and return the final [TaskStatusUpdate]
  ///
  /// Different from [enqueue], this method returns a [Future] that completes
  /// when the file has been downloaded, or an error has occurred.
  /// While it uses the same download mechanism as [enqueue],
  /// and will execute the download also when
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
  /// An optional callback [onElapsedTime] will be called at regular intervals
  /// (defined by [elapsedTimeInterval], which defaults to 5 seconds) with a
  /// single argument that is the elapsed time since the call to [download].
  /// This can be used to trigger UI warnings (e.g. 'this is taking rather long')
  /// or to cancel the task if it does not complete within a desired time.
  /// For performance reasons the [elapsedTimeInterval] should not be set to
  /// a value less than one second.
  /// The [onElapsedTime] callback should not be used to indicate progress. For
  /// that, use the [onProgress] callback.
  ///
  /// Note that the task's [group] is ignored and will be replaced with an
  /// internal group name [awaitGroup] to track status
  ///
  /// Use [enqueue] instead of [download] if:
  /// - your download/upload is likely to take long and may require
  ///   running in the background
  /// - you want to monitor tasks centrally, via a listener
  /// - you want more detailed progress information
  ///   (e.g. file size, network speed, time remaining)
  Future<TaskStatusUpdate> download(DownloadTask task,
          {void Function(TaskStatus)? onStatus,
          void Function(double)? onProgress,
          void Function(Duration)? onElapsedTime,
          Duration? elapsedTimeInterval}) =>
      _enqueueAndAwait(task,
          onStatus: onStatus,
          onProgress: onProgress,
          onElapsedTime: onElapsedTime,
          elapsedTimeInterval: elapsedTimeInterval);

  /// Upload a file and return the final [TaskStatusUpdate]
  ///
  /// Different from [enqueue], this method returns a [Future] that completes
  /// when the file has been uploaded, or an error has occurred.
  /// While it uses the same upload mechanism as [enqueue],
  /// and will execute the upload also when
  /// the app moves to the background, it is meant for uploads that are
  /// awaited while the app is in the foreground.
  ///
  /// Optional callbacks for status and progress updates may be
  /// added. These function only take a [TaskStatus] or [double] argument as
  /// the task they refer to is expected to be captured in the closure for
  /// this call.
  /// For example `Downloader.upload(task, onStatus: (status) =>`
  /// `print('Status for ${task.taskId} is $status);`
  ///
  /// An optional callback [onElapsedTime] will be called at regular intervals
  /// (defined by [elapsedTimeInterval], which defaults to 5 seconds) with a
  /// single argument that is the elapsed time since the call to [upload].
  /// This can be used to trigger UI warnings (e.g. 'this is taking rather long')
  /// or to cancel the task if it does not complete within a desired time.
  /// For performance reasons the [elapsedTimeInterval] should not be set to
  /// a value less than one second.
  /// The [onElapsedTime] callback should not be used to indicate progress. For
  /// that, use the [onProgress] callback.
  ///
  /// Note that the task's [group] is ignored and will be replaced with an
  /// internal group name 'await' to track status
  ///
  /// Use [enqueue] instead of [upload] if:
  /// - your download/upload is likely to take long and may require
  ///   running in the background
  /// - you want to monitor tasks centrally, via a listener
  /// - you want more detailed progress information
  ///   (e.g. file size, network speed, time remaining)
  Future<TaskStatusUpdate> upload(UploadTask task,
          {void Function(TaskStatus)? onStatus,
          void Function(double)? onProgress,
          void Function(Duration)? onElapsedTime,
          Duration? elapsedTimeInterval}) =>
      _enqueueAndAwait(task,
          onStatus: onStatus,
          onProgress: onProgress,
          onElapsedTime: onElapsedTime,
          elapsedTimeInterval: elapsedTimeInterval);

  /// Enqueue the [task] and wait for completion
  ///
  /// Returns the final [TaskStatus] of the [task].
  /// This method is used to enqueue:
  /// 1. `download` and `upload` tasks, which may have a short callback
  ///    for status and progress (omitting Task)
  /// 2. `downloadBatch` and `uploadBatch`, which may have a full callback
  ///    that is used for every task in the batch
  Future<TaskStatusUpdate> _enqueueAndAwait(Task task,
      {void Function(TaskStatus)? onStatus,
      void Function(double)? onProgress,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback,
      void Function(Duration)? onElapsedTime,
      Duration? elapsedTimeInterval}) async {
    /// Internal callback function that passes the update on to different
    /// callbacks
    ///
    /// The update is passed on to:
    /// 1. Task-specific callback, passed as parameter to call
    /// 2. Short task-specific callback, passed as parameter to call
    /// 3. Batch-related callback, if this task is part of a batch operation
    ///    and is in a final state
    ///
    /// If the task is in final state, also removes the reference to the
    /// task-specific callbacks and completes the completer associated
    /// with this task
    internalStatusCallback(TaskStatusUpdate statusUpdate) {
      final task = statusUpdate.task;
      final status = statusUpdate.status;
      _shortTaskStatusCallbacks[task.taskId]?.call(status);
      _taskStatusCallbacks[task.taskId]?.call(statusUpdate);
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
        _shortTaskStatusCallbacks.remove(task.taskId);
        _shortTaskProgressCallbacks.remove(task.taskId);
        _taskStatusCallbacks.remove(task.taskId);
        _taskProgressCallbacks.remove(task.taskId);
        var taskCompleter = _taskCompleters.remove(task);
        taskCompleter?.complete(statusUpdate);
      }
    }

    /// Internal callback function that only passes progress updates on
    /// to the task-specific progress callback passed as parameter to call
    internalProgressCallBack(TaskProgressUpdate progressUpdate) {
      _shortTaskProgressCallbacks[progressUpdate.task.taskId]
          ?.call(progressUpdate.progress);
      _taskProgressCallbacks[progressUpdate.task.taskId]?.call(progressUpdate);
    }

    // register the internal callbacks and store the task-specific ones
    registerCallbacks(
        group: awaitGroup,
        taskStatusCallback: internalStatusCallback,
        taskProgressCallback: internalProgressCallBack);
    final internalTask = task.copyWith(
        group: awaitGroup,
        updates: (onProgress != null || taskProgressCallback != null)
            ? Updates.statusAndProgress
            : Updates.status);
    await _downloader.setModifiedTask(internalTask, task);
    if (onStatus != null) {
      _shortTaskStatusCallbacks[task.taskId] = onStatus;
    }
    if (onProgress != null) {
      _shortTaskProgressCallbacks[task.taskId] = onProgress;
    }
    if (taskStatusCallback != null) {
      _taskStatusCallbacks[task.taskId] = taskStatusCallback;
    }
    if (taskProgressCallback != null) {
      _taskProgressCallbacks[task.taskId] = taskProgressCallback;
    }
    // start the elapsedTime timer if necessary. It is cancelled when the
    // taskCompleter completes (when the task itself completes)
    Timer? timer;
    if (onElapsedTime != null) {
      final interval = elapsedTimeInterval ?? const Duration(seconds: 5);
      timer = Timer.periodic(interval, (timer) {
        onElapsedTime(interval * timer.tick);
      });
    }
    // Create taskCompleter and enqueue the task.
    // The completer will be completed in the internal status callback
    final taskCompleter = Completer<TaskStatusUpdate>();
    _taskCompleters[internalTask] = taskCompleter;
    final enqueueSuccess = await enqueue(internalTask);
    if (!enqueueSuccess) {
      _log.warning('Could not enqueue task $task');
      return Future.value(TaskStatusUpdate(task, TaskStatus.failed,
          TaskException('Could not enqueue task $task')));
    }
    if (timer != null) {
      taskCompleter.future.then((_) => timer?.cancel());
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
  /// To also monitor status and/or progress for each task in the batch, provide
  /// a [taskStatusCallback] and/or [taskProgressCallback], which will be used
  /// for each task in the batch.
  ///
  /// An optional callback [onElapsedTime] will be called at regular intervals
  /// (defined by [elapsedTimeInterval], which defaults to 5 seconds) with a
  /// single argument that is the elapsed time since the call to [downloadBatch].
  /// This can be used to trigger UI warnings (e.g. 'this is taking rather long')
  /// or to cancel the task if it does not complete within a desired time.
  /// For performance reasons the [elapsedTimeInterval] should not be set to
  /// a value less than one second.
  /// The [onElapsedTime] callback should not be used to indicate progress.
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [Task.group] and [Task.updates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [Batch]
  /// object.
  Future<Batch> downloadBatch(final List<DownloadTask> tasks,
          {BatchProgressCallback? batchProgressCallback,
          TaskStatusCallback? taskStatusCallback,
          TaskProgressCallback? taskProgressCallback,
          void Function(Duration)? onElapsedTime,
          Duration? elapsedTimeInterval}) =>
      _enqueueAndAwaitBatch(tasks,
          batchProgressCallback: batchProgressCallback,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback,
          onElapsedTime: onElapsedTime,
          elapsedTimeInterval: elapsedTimeInterval);

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
  /// To also monitor status and/or progress for each task in the batch, provide
  /// a [taskStatusCallback] and/or [taskProgressCallback], which will be used
  /// for each task in the batch.
  ///
  /// An optional callback [onElapsedTime] will be called at regular intervals
  /// (defined by [elapsedTimeInterval], which defaults to 5 seconds) with a
  /// single argument that is the elapsed time since the call to [uploadBatch].
  /// This can be used to trigger UI warnings (e.g. 'this is taking rather long')
  /// or to cancel the task if it does not complete within a desired time.
  /// For performance reasons the [elapsedTimeInterval] should not be set to
  /// a value less than one second.
  /// The [onElapsedTime] callback should not be used to indicate progress.
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [Task.group] and [Task.updates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [Batch]
  /// object.
  Future<Batch> uploadBatch(final List<UploadTask> tasks,
          {BatchProgressCallback? batchProgressCallback,
          TaskStatusCallback? taskStatusCallback,
          TaskProgressCallback? taskProgressCallback,
          void Function(Duration)? onElapsedTime,
          Duration? elapsedTimeInterval}) =>
      _enqueueAndAwaitBatch(tasks,
          batchProgressCallback: batchProgressCallback,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback,
          onElapsedTime: onElapsedTime,
          elapsedTimeInterval: elapsedTimeInterval);

  /// Enqueue a list of tasks and wait for completion
  ///
  /// Returns a [Batch] object
  Future<Batch> _enqueueAndAwaitBatch(final List<Task> tasks,
      {BatchProgressCallback? batchProgressCallback,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback,
      void Function(Duration)? onElapsedTime,
      Duration? elapsedTimeInterval}) async {
    assert(tasks.isNotEmpty, 'List of tasks cannot be empty');
    if (batchProgressCallback != null) {
      batchProgressCallback(0, 0); // initial callback
    }
    Timer? timer;
    if (onElapsedTime != null) {
      final interval = elapsedTimeInterval ?? const Duration(seconds: 5);
      timer = Timer.periodic(interval, (timer) {
        onElapsedTime(interval * timer.tick);
      });
    }
    final batch = Batch(tasks, batchProgressCallback);
    _batches.add(batch);
    final taskFutures = <Future<TaskStatusUpdate>>[];
    var counter = 0;
    for (final task in tasks) {
      taskFutures.add(_enqueueAndAwait(task,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback));
      counter++;
      if (counter % 3 == 0) {
        // To prevent blocking the UI we 'yield' for a few ms after every 3
        // tasks we enqueue
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    await Future.wait(taskFutures); // wait for all tasks to complete
    _batches.remove(batch);
    timer?.cancel();
    return batch;
  }

  /// Resets the downloader by cancelling all ongoing tasks within
  /// the provided [group]
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [TaskStatus.canceled] update to the registered callback, if
  /// requested
  ///
  /// This method acts on a [group] of tasks. If omitted, the [defaultGroup]
  /// is used, which is the group used when you [enqueue] a task. If you
  /// use a convenience function such as [download], the [group] of the
  /// task is changed to [awaitGroup]. Therefore, for this method to act on
  /// tasks used in a convenience function, make sure to pass [awaitGroup]
  /// as the [group] argument.
  Future<int> reset({String group = defaultGroup}) => _downloader.reset(group);

  /// Returns a list of taskIds of all tasks currently active in this [group]
  ///
  /// Active means enqueued or running, and if [includeTasksWaitingToRetry] is
  /// true also tasks that are waiting to be retried
  ///
  /// This method acts on a [group] of tasks. If omitted, the [defaultGroup]
  /// is used, which is the group used when you [enqueue] a task. If you
  /// use a convenience function such as [download], the [group] of the
  /// task is changed to [awaitGroup]. Therefore, for this method to act on
  /// tasks used in a convenience function, make sure to pass [awaitGroup]
  /// as the [group] argument.
  Future<List<String>> allTaskIds(
          {String group = defaultGroup,
          bool includeTasksWaitingToRetry = true}) async =>
      (await allTasks(
              group: group,
              includeTasksWaitingToRetry: includeTasksWaitingToRetry))
          .map((task) => task.taskId)
          .toList();

  /// Returns a list of all tasks currently active in this [group]
  ///
  /// Active means enqueued or running, and if [includeTasksWaitingToRetry] is
  /// true also tasks that are waiting to be retried
  ///
  /// This method acts on a [group] of tasks. If omitted, the [defaultGroup]
  /// is used, which is the group used when you [enqueue] a task. If you
  /// use a convenience function such as [download], the [group] of the
  /// task is changed to [awaitGroup]. Therefore, for this method to act on
  /// tasks used in a convenience function, make sure to pass [awaitGroup]
  /// as the [group] argument.
  Future<List<Task>> allTasks(
          {String group = defaultGroup,
          bool includeTasksWaitingToRetry = true}) =>
      _downloader.allTasks(group, includeTasksWaitingToRetry);

  /// Returns true if tasks in this [group] are finished
  ///
  /// Finished means "not active", i.e. no tasks are enqueued or running,
  /// and if [includeTasksWaitingToRetry] is true (the default), no tasks are
  /// waiting to be retried.
  /// Finished does not mean that all tasks completed successfully.
  ///
  /// This method acts on a [group] of tasks. If omitted, the [defaultGroup]
  /// is used, which is the group used when you [enqueue] a task. If you
  /// use a convenience function such as [download], the [Task.group] of the
  /// task is changed to [awaitGroup]. Therefore, for this method to act on
  /// tasks used in a convenience function, make sure to pass [awaitGroup]
  /// as the [group] argument.
  ///
  /// If an [ignoreTask] is provided, it will be excluded from the test. This
  /// allows you to test for [tasksFinished] within the status update callback
  /// for a task that just finished. In that situation, that task may still
  /// be returned by the platform as 'active', but you already know it is not.
  /// Calling [tasksFinished] while passing that just-finished task will ensure
  /// a proper test in that situation.
  Future<bool> tasksFinished(
      {String group = defaultGroup,
      bool includeTasksWaitingToRetry = true,
      String? ignoreTaskId}) async {
    final tasksInProgress = await allTasks(
        group: group, includeTasksWaitingToRetry: includeTasksWaitingToRetry);
    if (ignoreTaskId != null) {
      tasksInProgress.removeWhere((task) => task.taskId == ignoreTaskId);
    }
    return tasksInProgress.isEmpty;
  }

  /// Cancel all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [TaskStatus.canceled] update to
  /// the registered callback, if requested
  Future<bool> cancelTasksWithIds(List<String> taskIds) =>
      _downloader.cancelTasksWithIds(taskIds);

  /// Cancel this task
  ///
  /// The task will emit a [TaskStatus.canceled] update to
  /// the registered callback, if requested
  Future<bool> cancelTaskWithId(String taskId) => cancelTasksWithIds([taskId]);

  /// Return [Task] for the given [taskId], or null
  /// if not found.
  ///
  /// Only running tasks are guaranteed to be returned, but returning a task
  /// does not guarantee that the task is still running. To keep track of
  /// the status of tasks, use a [TaskStatusCallback]
  Future<Task?> taskForId(String taskId) => _downloader.taskForId(taskId);

  /// Activate tracking for tasks in this [group]
  ///
  /// All subsequent tasks in this group will be recorded in persistent storage.
  /// Use the [FileDownloader.database] to get or remove [TaskRecord] objects,
  /// which contain a [Task], its [TaskStatus] and a [double] for progress.
  ///
  /// If [markDownloadedComplete] is true (default) then all tasks in the
  /// database that are marked as not yet [TaskStatus.complete] will be set to
  /// [TaskStatus.complete] if the target file for that task exists.
  /// They will also emit [TaskStatus.complete] and [progressComplete] to
  /// their registered listener or callback.
  /// This is a convenient way to capture downloads that have completed while
  /// the app was suspended: on app startup, immediately register your
  /// listener or callbacks, and call [trackTasks] for each group.
  ///
  /// Returns the [FileDownloader] for easy chaining
  Future<FileDownloader> trackTasksInGroup(String group,
      {bool markDownloadedComplete = true}) async {
    await _downloader.trackTasks(group, markDownloadedComplete);
    return this;
  }

  /// Activate tracking for all tasks
  ///
  /// All subsequent tasks will be recorded in persistent storage.
  /// Use the [FileDownloader.database] to get or remove [TaskRecord] objects,
  /// which contain a [Task], its [TaskStatus] and a [double] for progress.
  ///
  /// If [markDownloadedComplete] is true (default) then all tasks in the
  /// database that are marked as not yet [TaskStatus.complete] will be set to
  /// [TaskStatus.complete] if the target file for that task exists.
  /// They will also emit [TaskStatus.complete] and [progressComplete] to
  /// their registered listener or callback.
  /// This is a convenient way to capture downloads that have completed while
  /// the app was suspended: on app startup, immediately register your
  /// listener or callbacks, and call [trackTasks].
  ///
  /// Returns the [FileDownloader] for easy chaining
  Future<FileDownloader> trackTasks(
      {bool markDownloadedComplete = true}) async {
    await _downloader.trackTasks(null, markDownloadedComplete);
    return this;
  }

  /// Wakes up the FileDownloader from possible background state, triggering
  /// a stream of updates that may have been processed while in the background,
  /// and have not yet reached the callbacks or listener
  ///
  /// Calling this method multiple times has no effect.
  Future<void> resumeFromBackground() =>
      _downloader.retrieveLocallyStoredData();

  /// Returns true if task can be resumed on pause
  ///
  /// This future only completes once the task is running and has received
  /// information from the server to determine whether resume is possible, or
  /// if the task fails and resume is possible
  Future<bool> taskCanResume(Task task) => _downloader.taskCanResume(task);

  /// Pause the task
  ///
  /// Returns true if the pause was attempted successfully. Test the task's
  /// status to see if it was executed successfully [TaskStatus.paused] or if
  /// it failed after all [TaskStatus.failed]
  ///
  /// If the [Task.allowPause] field is set to false (default) or if this is
  /// a POST request, this method returns false immediately.
  Future<bool> pause(DownloadTask task) async {
    if (task.allowPause && task.post == null) {
      return _downloader.pause(task);
    }
    return false;
  }

  /// Resume the task
  ///
  /// If no resume data is available for this task, the call to [resume]
  /// will return false and the task is not resumed.
  /// If resume data is available, the call to [resume] will return true,
  /// but this does not guarantee that resuming is actually possible, just that
  /// the task is now enqueued for resume.
  /// If the task is able to resume, it will, otherwise it will restart the
  /// task from scratch, or fail.
  Future<bool> resume(DownloadTask task) async {
    final resumeTask = await _downloader.getModifiedTask(task) ?? task;
    return _downloader.resume(resumeTask);
  }

  /// Configure notification for a single task
  ///
  /// The configuration determines what notifications are shown,
  /// whether a progress bar is shown (Android only), and whether tapping
  /// the 'complete' notification opens the downloaded file.
  ///
  /// [running] is the notification used while the task is in progress
  /// [complete] is the notification used when the task completed
  /// [error] is the notification used when something went wrong,
  /// including pause, failed and notFound status
  ///
  /// The [TaskNotification] is the actual notification shown for a [Task], and
  /// [body] and [title] may contain special strings to substitute display values:
  /// {filename] to insert the filename
  /// {progress} to insert progress in %
  /// {networkSpeed} to insert the network speed in MB/s or kB/s, or '--' if N/A
  /// {timeRemaining} to insert the estimated time remaining to complete the task
  ///   in HH:MM:SS or MM:SS or --:-- if N/A
  ///
  /// Actual appearance of notification is dependent on the platform, e.g.
  /// on iOS {progress} is not available and ignored
  ///
  /// Returns the [FileDownloader] for easy chaining
  FileDownloader configureNotificationForTask(Task task,
      {TaskNotification? running,
      TaskNotification? complete,
      TaskNotification? error,
      TaskNotification? paused,
      bool progressBar = false,
      bool tapOpensFile = false}) {
    _downloader.notificationConfigs.add(TaskNotificationConfig(
        taskOrGroup: task,
        running: running,
        complete: complete,
        error: error,
        paused: paused,
        progressBar: progressBar,
        tapOpensFile: tapOpensFile));
    return this;
  }

  /// Configure notification for a group of tasks
  ///
  /// The configuration determines what notifications are shown,
  /// whether a progress bar is shown (Android only), and whether tapping
  /// the 'complete' notification opens the downloaded file.
  ///
  /// [running] is the notification used while the task is in progress
  /// [complete] is the notification used when the task completed
  /// [error] is the notification used when something went wrong,
  /// including pause, failed and notFound status
  ///
  /// The [TaskNotification] is the actual notification shown for a [Task], and
  /// [body] and [title] may contain special strings to substitute display values:
  /// {filename] to insert the filename
  /// {progress} to insert progress in %
  /// {networkSpeed} to insert the network speed in MB/s or kB/s, or '--' if N/A
  /// {timeRemaining} to insert the estimated time remaining to complete the task
  ///   in HH:MM:SS or MM:SS or --:-- if N/A
  ///
  /// Actual appearance of notification is dependent on the platform, e.g.
  /// on iOS {progress} is not available and ignored
  ///
  /// Returns the [FileDownloader] for easy chaining
  FileDownloader configureNotificationForGroup(String group,
      {TaskNotification? running,
      TaskNotification? complete,
      TaskNotification? error,
      TaskNotification? paused,
      bool progressBar = false,
      bool tapOpensFile = false}) {
    _downloader.notificationConfigs.add(TaskNotificationConfig(
        taskOrGroup: group,
        running: running,
        complete: complete,
        error: error,
        paused: paused,
        progressBar: progressBar,
        tapOpensFile: tapOpensFile));
    return this;
  }

  /// Configure default task notification
  ///
  /// This is the notification configuration used for tasks that do not
  /// match a task-specific or group-specific notification configuration
  ///
  /// The configuration determines what notifications are shown,
  /// whether a progress bar is shown (Android only), and whether tapping
  /// the 'complete' notification opens the downloaded file.
  ///
  /// [running] is the notification used while the task is in progress
  /// [complete] is the notification used when the task completed
  /// [error] is the notification used when something went wrong,
  /// including pause, failed and notFound status
  ///
  /// The [TaskNotification] is the actual notification shown for a [Task], and
  /// [body] and [title] may contain special strings to substitute display values:
  /// {filename] to insert the filename
  /// {progress} to insert progress in %
  /// {networkSpeed} to insert the network speed in MB/s or kB/s, or '--' if N/A
  /// {timeRemaining} to insert the estimated time remaining to complete the task
  ///   in HH:MM:SS or MM:SS or --:-- if N/A
  ///
  /// Actual appearance of notification is dependent on the platform, e.g.
  /// on iOS {progress} is not available and ignored
  ///
  /// Returns the [FileDownloader] for easy chaining
  FileDownloader configureNotification(
      {TaskNotification? running,
      TaskNotification? complete,
      TaskNotification? error,
      TaskNotification? paused,
      bool progressBar = false,
      bool tapOpensFile = false}) {
    _downloader.notificationConfigs.add(TaskNotificationConfig(
        taskOrGroup: null,
        running: running,
        complete: complete,
        error: error,
        paused: paused,
        progressBar: progressBar,
        tapOpensFile: tapOpensFile));
    return this;
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
  Future<http.Response> request(Request request) => compute(doRequest, (
        request,
        DesktopDownloader.requestTimeout,
        DesktopDownloader.proxy,
        DesktopDownloader.bypassTLSCertificateValidation
      ));

  /// Move the file represented by the [task] to a shared storage
  /// [destination] and potentially a [directory] within that destination. If
  /// the [mimeType] is not provided we will attempt to derive it from the
  /// [Task.filePath] extension
  ///
  /// Returns the path to the stored file, or null if not successful
  ///
  /// Platform-dependent, not consistent across all platforms
  Future<String?> moveToSharedStorage(
    DownloadTask task,
    SharedStorage destination, {
    String directory = '',
    String? mimeType,
  }) async =>
      moveFileToSharedStorage(await task.filePath(), destination,
          directory: directory, mimeType: mimeType);

  /// Move the file represented by [filePath] to a shared storage
  /// [destination] and potentially a [directory] within that destination. If
  /// the [mimeType] is not provided we will attempt to derive it from the
  /// [filePath] extension
  ///
  /// Returns the path to the stored file, or null if not successful
  ///
  /// Platform-dependent, not consistent across all platforms
  Future<String?> moveFileToSharedStorage(
    String filePath,
    SharedStorage destination, {
    String directory = '',
    String? mimeType,
  }) async =>
      _downloader.moveToSharedStorage(
          filePath, destination, directory, mimeType);

  /// Returns the filePath to the file represented by [filePath] in shared
  /// storage [destination] and potentially a [directory] within that
  /// destination.
  ///
  /// Returns the path to the stored file, or null if not successful
  ///
  /// Platform-dependent, not consistent across all platforms
  Future<String?> pathInSharedStorage(
          String filePath, SharedStorage destination,
          {String directory = ''}) async =>
      _downloader.pathInSharedStorage(filePath, destination, directory);

  /// Open the file represented by [task] or [filePath] using the application
  /// available on the platform.
  ///
  /// [mimeType] may override the mimetype derived from the file extension,
  /// though implementation depends on the platform and may not always work.
  ///
  /// Returns true if an application was launched successfully
  Future<bool> openFile({Task? task, String? filePath, String? mimeType}) {
    assert(task != null || filePath != null, 'Task or filePath must be set');
    assert(!(task != null && filePath != null),
        'Either task or filePath must be set, not both');
    return _downloader.openFile(task, filePath, mimeType);
  }

  /// Closes the [updates] stream and re-initializes the [StreamController]
  /// such that the stream can be listened to again
  Future<void> resetUpdates() => _downloader.resetUpdatesStreamController();

  /// Destroy the [FileDownloader]. Subsequent use requires initialization
  void destroy() {
    _batches.clear();
    _taskCompleters.clear();
    _shortTaskStatusCallbacks.clear();
    _shortTaskProgressCallbacks.clear();
    _taskStatusCallbacks.clear();
    _taskProgressCallbacks.clear();
    _downloader.destroy();
    Localstore.instance.clearCache();
  }
}

/// Performs the actual server request, with retries
///
/// This function is run on an Isolate to ensure performance on the main
/// Isolate is not affected
Future<http.Response> doRequest(
    (Request, Duration?, Map<String, dynamic>, bool) params) async {
  final (request, requestTimeout, proxy, bypassTLSCertificateValidation) =
      params;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    if (kDebugMode) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    }
  });
  final log = Logger('FileDownloader.request');
  DesktopDownloader.setHttpClient(
      requestTimeout, proxy, bypassTLSCertificateValidation);
  final client = DesktopDownloader.httpClient;
  var response = http.Response('', 499,
      reasonPhrase: 'Not attempted'); // dummy to start with
  while (request.retriesRemaining >= 0) {
    try {
      response = await switch (request.httpRequestMethod) {
        'GET' => client.get(Uri.parse(request.url), headers: request.headers),
        'POST' => client.post(Uri.parse(request.url),
            headers: request.headers, body: request.post),
        'HEAD' => client.head(Uri.parse(request.url), headers: request.headers),
        'PUT' => client.put(Uri.parse(request.url), headers: request.headers),
        'DELETE' =>
          client.delete(Uri.parse(request.url), headers: request.headers),
        'PATCH' =>
          client.patch(Uri.parse(request.url), headers: request.headers),
        _ => Future.value(response)
      };
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
