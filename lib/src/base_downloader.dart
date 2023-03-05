import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:collection/collection.dart';

import 'database.dart';
import 'desktop_downloader.dart';
import 'models.dart';
import 'native_downloader.dart';

/// Common download functionality
///
/// Concrete subclass will implement platform-specific functionality, eg
/// [DesktopDownloader] for dart based desktop platforms, and
/// [NativeDownloader] for iOS and Android
///
/// The common functionality mostly relates to:
/// - callback handling (for groups of tasks registered via the [FileDownloader])
/// - tasks waiting to retry and retry handling
/// - Task updates provided to the [FileDownloader]
/// - Pause/resume status and information
abstract class BaseDownloader {
  final log = Logger('BaseDownloader');
  final tasksWaitingToRetry = <Task>[];

  /// Registered [TaskStatusCallback] for each group
  final groupStatusCallbacks = <String, TaskStatusCallback>{};

  /// Registered [TaskProgressCallback] for each group
  final groupProgressCallbacks = <String, TaskProgressCallback>{};

  /// StreamController for [TaskUpdate] updates
  var updates = StreamController<TaskUpdate>();

  /// Groups tracked in persistent database
  final trackedGroups = <String>{};

  /// Map of tasks and completer to indicate whether task can be resumed
  final canResumeTask = <Task, Completer<bool>>{};

  /// Map of data needed to resume a task
  ///
  /// On iOS, the first item, a String, is the iOS resumeData encoded
  /// On other platforms, the first item, a String, is the path to the
  /// temp filename where the partial download is stored
  /// The second parameter is the startByte (0 for iOS)
  final resumeData = <Task, List<dynamic>>{}; // [String filename, int bytes]

  /// Set of paused tasks
  ///
  /// May not include tasks that paused before the app was started
  final pausedTasks = <Task>{};

  BaseDownloader();

  factory BaseDownloader.instance() {
    final instance = Platform.isMacOS || Platform.isLinux || Platform.isWindows
        ? DesktopDownloader()
        : NativeDownloader();
    instance.initialize();
    return instance;
  }

  /// Initialize
  void initialize() {}

  /// Enqueue the task
  @mustCallSuper
  Future<bool> enqueue(Task task) async {
    if (task.allowPause) {
      canResumeTask[task] = Completer();
    }
    return true;
  }

  /// Resets the download worker by cancelling all ongoing tasks for the group
  ///
  ///  Returns the number of tasks canceled
  @mustCallSuper
  Future<int> reset(String group) async {
    final retryCount =
        tasksWaitingToRetry.where((task) => task.group == group).length;
    tasksWaitingToRetry.removeWhere((task) => task.group == group);
    final pausedCount = pausedTasks.where((task) => task.group == group).length;
    pausedTasks.removeWhere((task) => task.group == group);
    return retryCount + pausedCount;
  }

  /// Returns a list of all tasks in progress, matching [group]
  @mustCallSuper
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final tasks = <Task>[];
    if (includeTasksWaitingToRetry) {
      tasks.addAll(tasksWaitingToRetry.where((task) => task.group == group));
    }
    tasks.addAll(pausedTasks.where((task) => task.group == group));
    return tasks;
  }

  /// Cancels ongoing tasks whose taskId is in the list provided with this call
  ///
  /// Returns true if all cancellations were successful
  @mustCallSuper
  Future<bool> cancelTasksWithIds(List<String> taskIds) async {
    final matchingTasksWaitingToRetry = tasksWaitingToRetry
        .where((task) => taskIds.contains(task.taskId))
        .toList(growable: false);
    final matchingTaskIdsWaitingToRetry = matchingTasksWaitingToRetry
        .map((task) => task.taskId)
        .toList(growable: false);
    // remove tasks waiting to retry from the list so they won't be retried
    for (final task in matchingTasksWaitingToRetry) {
      tasksWaitingToRetry.remove(task);
      _emitStatusUpdate(task, TaskStatus.canceled);
      _emitProgressUpdate(task, progressCanceled);
    }
    final remainingTaskIds = taskIds
        .where((taskId) => !matchingTaskIdsWaitingToRetry.contains(taskId));
    // cancel paused tasks
    final pausedTaskIdsToCancel = pausedTasks
        .where((task) => remainingTaskIds.contains(task.taskId))
        .map((e) => e.taskId)
        .toList(growable: false);
    cancelPausedPlatformTasksWithIds(pausedTaskIdsToCancel);
    // cancel remaining taskIds on the platform
    final platformTaskIds = remainingTaskIds
        .where((taskId) => !pausedTaskIdsToCancel.contains(taskId))
        .toList(growable: false);
    if (platformTaskIds.isEmpty) {
      return true;
    }
    return cancelPlatformTasksWithIds(platformTaskIds);
  }

  /// Cancel these tasks on the platform
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds);

  /// Cancel paused tasks
  ///
  /// Deletes the associated temp file and emits [TaskStatus.cancel]
  void cancelPausedPlatformTasksWithIds(List<String> taskIds) async {
    for (final taskId in taskIds) {
      final task =
          pausedTasks.firstWhereOrNull((element) => element.taskId == taskId);
      if (task != null) {
        final data = resumeData[task];
        if (!Platform.isIOS && data != null) {
          // on non-iOS, data[0] is the tempFilePath, and that file must be
          // deleted
          final tempFilePath = data[0] as String;
          try {
            await File(tempFilePath).delete();
          } on FileSystemException {
            log.fine('Could not delete temp file $tempFilePath');
          }
        }
        processStatusUpdate(task, TaskStatus.canceled);
      }
    }
  }

  /// Returns Task for this taskId, or nil
  @mustCallSuper
  Future<Task?> taskForId(String taskId) async {
    try {
      return tasksWaitingToRetry.where((task) => task.taskId == taskId).first;
    } on StateError {
      try {
        return pausedTasks.where((task) => task.taskId == taskId).first;
      } on StateError {
        return null;
      }
    }
  }

  /// Activate tracking for tasks in this group
  ///
  /// All subsequent tasks in this group will be recorded in persistent storage
  /// and can be queried with methods that include 'tracked', e.g.
  /// [allTrackedTasks]
  ///
  /// If [markDownloadedComplete] is true (default) then all tasks that are
  /// marked as not yet [TaskStatus.complete] will be set to complete if the
  /// target file for that task exists, and will emit [TaskStatus.complete]
  /// and [progressComplete] to their registered listener or callback.
  /// This is a convenient way to capture downloads that have completed while
  /// the app was suspended, provided you have registered your listeners
  /// or callback before calling this.
  Future<void> trackTasks(String group, bool markDownloadedComplete) async {
    trackedGroups.add(group);
    if (markDownloadedComplete) {
      final records = await Database().allRecords(group: group);
      for (var record in records.where((record) =>
          record.task is DownloadTask &&
          record.taskStatus != TaskStatus.complete)) {
        final filePath = await record.task.filePath();
        if (await File(filePath).exists()) {
          processStatusUpdate(record.task, record.taskStatus);
          final updatedRecord = record.copyWith(
              taskStatus: TaskStatus.complete, progress: progressComplete);
          await Database().updateRecord(updatedRecord);
        }
      }
    }
  }

  /// Sets the 'canResumeTask' flag for this task
  ///
  /// Completes the completer already associated with this task
  void setCanResume(Task task, bool canResume) {
    if (canResumeTask[task]?.isCompleted == false) {
      canResumeTask[task]?.complete(canResume);
    }
  }

  /// Returns a Future that indicates whether this task can be resumed
  Future<bool> taskCanResume(Task task) =>
      canResumeTask[task]?.future ?? Future.value(false);

  /// Stores the resume data: a String, representing temp filename on all
  /// platforms  except iOS (where it is a base64 encoded String)
  /// and the startByte position for this task, if available
  void setResumeData(Task task, String stringData, int startByte) =>
      resumeData[task] = [stringData, startByte];

  /// Clear pause and resume info associated with this task
  void _clearPauseResumeInfo(Task task) {
    canResumeTask.remove(task);
    resumeData.remove(task);
    pausedTasks.remove(task);
  }

  Future<bool> pause(Task task);

  /// Attempt to resume this [task]
  ///
  /// Returns true if successful
  @mustCallSuper
  Future<bool> resume(Task task) async {
    pausedTasks.remove(task);
    if (resumeData[task] != null) {
      canResumeTask[task] = Completer();
      return true;
    }
    return false;
  }

  /// Destroy - clears callbacks, updates stream and retry queue
  ///
  /// Clears all queues and references without sending cancellation
  /// messages or status updates
  @mustCallSuper
  void destroy() {
    tasksWaitingToRetry.clear();
    groupStatusCallbacks.clear();
    groupProgressCallbacks.clear();
    trackedGroups.clear();
    canResumeTask.clear();
    resumeData.clear();
    pausedTasks.clear();
    updates.close();
    updates = StreamController();
  }

  /// Process status update coming from Downloader and emits to listener
  ///
  /// Also manages retries ([tasksWaitingToRetry] and delay) and pause/resume
  /// ([pausedTasks] and [_clearPauseResumeInfo]
  void processStatusUpdate(Task task, TaskStatus taskStatus) {
    // Normal status updates are only sent here when the task is expected
    // to provide those.  The exception is a .failed status when a task
    // has retriesRemaining > 0: those are always sent here, and are
    // intercepted to hold the task and reschedule in the near future
    if (taskStatus == TaskStatus.failed && task.retriesRemaining > 0) {
      _emitStatusUpdate(task, TaskStatus.waitingToRetry);
      _emitProgressUpdate(task, progressWaitingToRetry);
      task.decreaseRetriesRemaining();
      tasksWaitingToRetry.add(task);
      final waitTime = Duration(
          seconds: pow(2, (task.retries - task.retriesRemaining)).toInt());
      log.finer('TaskId ${task.taskId} failed, waiting ${waitTime.inSeconds}'
          ' seconds before retrying. ${task.retriesRemaining}'
          ' retries remaining');
      Future.delayed(waitTime, () async {
        // after delay, enqueue task again if it's still waiting
        if (tasksWaitingToRetry.remove(task)) {
          if (!await enqueue(task)) {
            log.warning('Could not enqueue task $task after retry timeout');
            _clearPauseResumeInfo(task);
            _emitStatusUpdate(task, TaskStatus.failed);
            _emitProgressUpdate(task, progressFailed);
          }
        }
      });
    } else {
      // normal status update
      if (taskStatus == TaskStatus.paused) {
        pausedTasks.add(task);
      }
      if (taskStatus.isFinalState) {
        _clearPauseResumeInfo(task);
      }
      _emitStatusUpdate(task, taskStatus);
    }
  }

  /// Process progress update coming from Downloader to client listener
  void processProgressUpdate(Task task, double progress) {
    _emitProgressUpdate(task, progress);
  }

  /// Emits the status update for this task to its callback or listener, and
  /// update the task in the database
  void _emitStatusUpdate(Task task, TaskStatus taskStatus) {
    _updateTaskInDatabase(task, status: taskStatus);
    if (task.providesStatusUpdates) {
      final taskStatusCallback = groupStatusCallbacks[task.group];
      if (taskStatusCallback != null) {
        taskStatusCallback(task, taskStatus);
      } else {
        if (updates.hasListener) {
          updates.add(TaskStatusUpdate(task, taskStatus));
        } else {
          log.warning('Requested status updates for task ${task.taskId} in '
              'group ${task.group} but no TaskStatusCallback '
              'was registered, and there is no listener to the '
              'updates stream');
        }
      }
    }
  }

  /// Emit the progress update for this task to its callback or listener, and
  /// update the task in the database
  void _emitProgressUpdate(Task task, progress) {
    _updateTaskInDatabase(task, progress: progress);
    if (task.providesProgressUpdates) {
      final taskProgressCallback = groupProgressCallbacks[task.group];
      if (taskProgressCallback != null) {
        taskProgressCallback(task, progress);
      } else if (updates.hasListener) {
        updates.add(TaskProgressUpdate(task, progress));
      } else {
        log.warning('Requested progress updates for task ${task.taskId} in '
            'group ${task.group} but no TaskProgressCallback '
            'was registered, and there is no listener to the '
            'updates stream');
      }
    }
  }

  /// Insert or update the [TaskRecord] in the tracking database
  Future<void> _updateTaskInDatabase(Task task,
      {TaskStatus? status, double? progress}) async {
    if (trackedGroups.contains(task.group)) {
      if (status == null && progress != null) {
        // update existing record with progress only
        final existingRecord = await Database().recordForId(task.taskId);
        if (existingRecord != null) {
          Database().updateRecord(existingRecord.copyWith(progress: progress));
        }
        return;
      }
      if (progress == null && status != null) {
        // set progress based on status
        switch (status) {
          case TaskStatus.enqueued:
          case TaskStatus.running:
            progress = 0.0;
            break;
          case TaskStatus.complete:
            progress = progressComplete;
            break;
          case TaskStatus.notFound:
            progress = progressNotFound;
            break;
          case TaskStatus.failed:
            progress = progressFailed;
            break;
          case TaskStatus.canceled:
            progress = progressCanceled;
            break;
          case TaskStatus.waitingToRetry:
            progress = progressWaitingToRetry;
            break;
          case TaskStatus.paused:
            progress = progressPaused;
            break;
        }
      }
      Database().updateRecord(TaskRecord(task, status!, progress!));
    }
  }
}
