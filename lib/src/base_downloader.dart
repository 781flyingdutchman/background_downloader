import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/src/native_downloader.dart';
import 'package:logging/logging.dart';

import 'desktop_downloader.dart';
import 'models.dart';

abstract class BaseDownloader {
  final log = Logger('BackgroundDownloader');
  final tasksWaitingToRetry = <Task>[];

  /// Registered [TaskStatusCallback] for each group
  final groupStatusCallbacks = <String, TaskStatusCallback>{};

  /// Registered [TaskProgressCallback] for each group
  final groupProgressCallbacks = <String, TaskProgressCallback>{};

  /// StreamController for [TaskUpdate] updates
  var updates = StreamController<TaskUpdate>();

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

  /// Enqueue the task and advance the queue
  Future<bool> enqueue(Task task);

  /// Resets the download worker by cancelling all ongoing tasks for the group
  ///
  ///  Returns the number of tasks canceled
  Future<int> reset(String group) async {
    final count =
        tasksWaitingToRetry.where((task) => task.group == group).length;
    tasksWaitingToRetry.removeWhere((task) => task.group == group);
    return count;
  }

  /// Returns a list of all tasks in progress, matching [group]
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final tasks = <Task>[];
    if (includeTasksWaitingToRetry) {
      tasks.addAll(tasksWaitingToRetry.where((task) => task.group == group));
    }
    return tasks;
  }

  /// Cancels ongoing tasks whose taskId is in the list provided with this call
  ///
  /// Returns true if all cancellations were successful
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
    // cancel remaining taskIds on the platform
    final platformTaskIds = taskIds
        .where((taskId) => !matchingTaskIdsWaitingToRetry.contains(taskId))
        .toList(growable: false);
    if (platformTaskIds.isEmpty) {
      return true;
    }
    return cancelPlatformTasksWithIds(platformTaskIds);
  }

  /// Cancel these tasks on the platform
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds);

  /// Returns Task for this taskId, or nil
  Future<Task?> taskForId(String taskId) async {
    try {
      return tasksWaitingToRetry.where((task) => task.taskId == taskId).first;
    } on StateError {
      return null;
    }
  }

  /// Destroy requiring re-initialization
  ///
  /// Clears all queues and references without sending cancellation
  /// messages or status updates
  void destroy() {
    tasksWaitingToRetry.clear();
    groupStatusCallbacks.clear();
    groupProgressCallbacks.clear();
    updates.close();
    updates = StreamController();
  }

  /// Process status update coming from plugin or [DesktopDownloader]
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

  void processProgressUpdate(Task task, double progress) {
    _emitProgressUpdate(task, progress);
  }

  /// Emits the status update for this task to its callback or listener
  void _emitStatusUpdate(Task task, TaskStatus taskStatus) {
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

  /// Emit the progress update for this task to its callback or listener
  void _emitProgressUpdate(Task task, progress) {
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
}
