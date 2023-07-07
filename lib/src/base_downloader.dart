import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:collection/collection.dart';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'desktop_downloader.dart';
import 'exceptions.dart';
import 'localstore/localstore.dart';
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
  static const resumeDataPath = 'backgroundDownloaderResumeData';
  static const pausedTasksPath = 'backgroundDownloaderPausedTasks';
  static const modifiedTasksPath = 'backgroundDownloaderModifiedTasks';
  static const metaDataCollection = 'backgroundDownloaderDatabase';

  static const databaseVersion = 1;

  /// Persistent storage
  final _db = Localstore.instance;

  final tasksWaitingToRetry = <Task>[];

  /// Registered [TaskStatusCallback] for each group
  final groupStatusCallbacks = <String, TaskStatusCallback>{};

  /// Registered [TaskProgressCallback] for each group
  final groupProgressCallbacks = <String, TaskProgressCallback>{};

  /// Registered [TaskNotificationTapCallback] for each group
  final groupNotificationTapCallbacks = <String, TaskNotificationTapCallback>{};

  /// StreamController for [TaskUpdate] updates
  var updates = StreamController<TaskUpdate>();

  /// Groups tracked in persistent database
  final trackedGroups = <String?>{};

  /// Map of tasks and completer to indicate whether task can be resumed
  final canResumeTask = <Task, Completer<bool>>{};

  /// Flag indicating we have retrieved missed data
  var _retrievedLocallyStoredData = false;

  BaseDownloader();

  factory BaseDownloader.instance() {
    final instance = Platform.isMacOS || Platform.isLinux || Platform.isWindows
        ? DesktopDownloader()
        : NativeDownloader();
    unawaited(instance.initialize());
    return instance;
  }

  /// Initialize
  ///
  /// Initializes the Localstore instance and if necessary perform database
  /// migration, then initializes the subclassed implementation for
  /// desktop or native
  @mustCallSuper
  Future<void> initialize() async {
    final metaData =
        await _db.collection(metaDataCollection).doc('metaData').get();
    final version = metaData?['version'] ?? 0;
    if (version != databaseVersion) {
      log.fine('Migrating database from version $version to $databaseVersion');
      switch (version) {
        case 0:
          // move files from docDir to supportDir
          final docDir = await getApplicationDocumentsDirectory();
          final supportDir = await getApplicationSupportDirectory();
          for (String path in [
            resumeDataPath,
            pausedTasksPath,
            modifiedTasksPath,
            Database.tasksPath
          ]) {
            try {
              final fromPath = join(docDir.path, path);
              if (await Directory(fromPath).exists()) {
                log.finest('Moving $path to support directory');
                final toPath = join(supportDir.path, path);
                await Directory(toPath).create(recursive: true);
                await Directory(fromPath).list().forEach((entity) {
                  if (entity is File) {
                    entity.copySync(join(toPath, basename(entity.path)));
                  }
                });
                await Directory(fromPath).delete(recursive: true);
              }
            } catch (e) {
              log.fine('Error migrating database for path $path: $e');
            }
          }
          break;

        default:
          log.warning('Illegal starting version: $version');
          break;
      }
      await _db
          .collection(metaDataCollection)
          .doc('metaData')
          .set({'version': databaseVersion});
    }
  }

  /// Retrieve data that was stored locally because it could not be
  /// delivered to the downloader
  Future<void> retrieveLocallyStoredData() async {
    if (!_retrievedLocallyStoredData) {
      final resumeDataMap = await popUndeliveredData(Undelivered.resumeData);
      for (var taskId in resumeDataMap.keys) {
        // map is <taskId, ResumeData>
        final resumeData = ResumeData.fromJsonMap(resumeDataMap[taskId]);
        await setResumeData(resumeData);
        await setPausedTask(resumeData.task);
      }
      final statusUpdateMap =
          await popUndeliveredData(Undelivered.statusUpdates);
      for (var taskId in statusUpdateMap.keys) {
        // map is <taskId, Task/TaskStatus> where TaskStatus is added to Task JSON
        final payload = statusUpdateMap[taskId];
        processStatusUpdate(TaskStatusUpdate.fromJsonMap(payload));
      }
      final progressUpdateMap =
          await popUndeliveredData(Undelivered.progressUpdates);
      for (var taskId in progressUpdateMap.keys) {
        // map is <taskId, Task/progress> where progress is added to Task JSON
        final payload = progressUpdateMap[taskId];
        processProgressUpdate(TaskProgressUpdate.fromJsonMap(payload));
      }
      _retrievedLocallyStoredData = true;
    }
  }

  /// Enqueue the task
  @mustCallSuper
  Future<bool> enqueue(Task task,
      [TaskNotificationConfig? notificationConfig]) async {
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
    final pausedTasks = await getPausedTasks();
    var pausedCount = 0;
    for (var task in pausedTasks) {
      if (task.group == group) {
        await removePausedTask(task.taskId);
        pausedCount++;
      }
    }
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
    final pausedTasks = await getPausedTasks();
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
      processStatusUpdate(TaskStatusUpdate(task, TaskStatus.canceled));
      processProgressUpdate(TaskProgressUpdate(task, progressCanceled));
    }
    final remainingTaskIds = taskIds
        .where((taskId) => !matchingTaskIdsWaitingToRetry.contains(taskId));
    // cancel paused tasks
    final pausedTasks = await getPausedTasks();
    final pausedTaskIdsToCancel = pausedTasks
        .where((task) => remainingTaskIds.contains(task.taskId))
        .map((e) => e.taskId)
        .toList(growable: false);
    await cancelPausedPlatformTasksWithIds(pausedTasks, pausedTaskIdsToCancel);
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
  Future<void> cancelPausedPlatformTasksWithIds(
      List<Task> pausedTasks, List<String> taskIds) async {
    for (final taskId in taskIds) {
      final task =
          pausedTasks.firstWhereOrNull((element) => element.taskId == taskId);
      if (task != null) {
        final resumeData = await getResumeData(task.taskId);
        if (!Platform.isIOS && resumeData != null) {
          // on non-iOS, data[0] is the tempFilePath, and that file must be
          // deleted
          final tempFilePath = resumeData.data;
          try {
            await File(tempFilePath).delete();
          } on FileSystemException {
            log.fine('Could not delete temp file $tempFilePath');
          }
        }
        processStatusUpdate(TaskStatusUpdate(task, TaskStatus.canceled));
        processProgressUpdate(TaskProgressUpdate(task, progressCanceled));
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
        final pausedTasks = await getPausedTasks();
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
  Future<void> trackTasks(String? group, bool markDownloadedComplete) async {
    trackedGroups.add(group);
    if (markDownloadedComplete) {
      final records = await Database().allRecords(group: group);
      for (var record in records.where((record) =>
          record.task is DownloadTask &&
          record.status != TaskStatus.complete)) {
        final filePath = await record.task.filePath();
        if (await File(filePath).exists()) {
          processStatusUpdate(
              TaskStatusUpdate(record.task, TaskStatus.complete));
          final updatedRecord = record.copyWith(
              status: TaskStatus.complete, progress: progressComplete);
          await Database().updateRecord(updatedRecord);
        }
      }
    }
  }

  /// Attempt to pause this [task]
  ///
  /// Returns true if successful
  Future<bool> pause(Task task);

  /// Attempt to resume this [task]
  ///
  /// Returns true if successful
  @mustCallSuper
  Future<bool> resume(Task task,
      [TaskNotificationConfig? notificationConfig]) async {
    await removePausedTask(task.taskId);
    if (await getResumeData(task.taskId) != null) {
      canResumeTask[task] = Completer();
      return true;
    }
    return false;
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

  /// Stores the resume data
  Future<void> setResumeData(ResumeData resumeData) => _db
      .collection(resumeDataPath)
      .doc(_safeId(resumeData.taskId))
      .set(resumeData.toJsonMap());

  /// Retrieve the resume data for this [taskId]
  Future<ResumeData?> getResumeData(String taskId) async {
    final jsonMap =
        await _db.collection(resumeDataPath).doc(_safeId(taskId)).get();
    return jsonMap == null ? null : ResumeData.fromJsonMap(jsonMap);
  }

  /// Remove resumeData for this [taskId], or all if null
  Future<void> removeResumeData([String? taskId]) async {
    if (taskId == null) {
      await _db.collection(resumeDataPath).delete();
      return;
    }
    await _db.collection(resumeDataPath).doc(_safeId(taskId)).delete();
  }

  /// Store the paused [task]
  Future<void> setPausedTask(Task task) => _db
      .collection(pausedTasksPath)
      .doc(_safeId(task.taskId))
      .set(task.toJsonMap());

  /// Return a stored paused task with this [taskId], or null if not found
  Future<Task?> getPausedTask(String taskId) async {
    final jsonMap =
        await _db.collection(pausedTasksPath).doc(_safeId(taskId)).get();
    return jsonMap == null ? null : Task.createFromJsonMap(jsonMap);
  }

  /// Return a list of paused [Task] objects
  Future<List<Task>> getPausedTasks() async {
    final jsonMap = await _db.collection(pausedTasksPath).get();
    if (jsonMap == null) {
      return [];
    }
    return jsonMap.values.map((e) => Task.createFromJsonMap(e)).toList();
  }

  /// Remove paused task for this taskId, or all if null
  Future<void> removePausedTask([String? taskId]) async {
    if (taskId == null) {
      await _db.collection(pausedTasksPath).delete();
      return;
    }
    await _db.collection(pausedTasksPath).doc(_safeId(taskId)).delete();
  }

  /// Retrieve data that was not delivered to Dart
  Future<Map<String, dynamic>> popUndeliveredData(Undelivered dataType);

  /// Clear pause and resume info associated with this [task]
  void _clearPauseResumeInfo(Task task) {
    canResumeTask.remove(task);
    removeResumeData(task.taskId);
    removePausedTask(task.taskId);
  }

  /// Get the duration for a task to timeout - Android only, for testing
  @visibleForTesting
  Future<Duration> getTaskTimeout();

  /// Set forceFailPostOnBackgroundChannel for native downloader
  @visibleForTesting
  Future<void> setForceFailPostOnBackgroundChannel(bool value);

  /// Move the file at [filePath] to the shared storage
  /// [destination] and potential subdirectory [directory]
  ///
  /// Returns the path to the file in shared storage, or null
  Future<String?> moveToSharedStorage(String filePath,
      SharedStorage destination, String directory, String? mimeType) {
    return Future.value(null);
  }

  /// Returns the path to the file at [filePath] in shared storage
  /// [destination] and potential subdirectory [directory], or null
  Future<String?> pathInSharedStorage(
      String filePath, SharedStorage destination, String directory) {
    return Future.value(null);
  }

  /// Open the file represented by [task] or [filePath] using the application
  /// available on the platform.
  ///
  /// [mimeType] may override the mimetype derived from the file extension,
  /// though implementation depends on the platform and may not always work.
  ///
  /// Returns true if an application was launched successfully
  ///
  /// Precondition: either task or filename is not null
  Future<bool> openFile(Task? task, String? filePath, String? mimeType);

  /// Stores modified [modifiedTask] in local storage if [Task.group]
  /// or [Task.updates] fields differ from [originalTask]
  ///
  /// Modification happens in convenience functions, and storing the modified
  /// version allows us to replace the original when used in pause/resume
  /// functionality. Without this, a convenience download may not be
  /// resumable using the original [modifiedTask] object (as the [Task.group]
  /// and [Task.updates] fields may have been modified)
  Future<void> setModifiedTask(Task modifiedTask, Task originalTask) async {
    if (modifiedTask.group != originalTask.group ||
        modifiedTask.updates != originalTask.updates) {
      await _db
          .collection(modifiedTasksPath)
          .doc(_safeId(originalTask.taskId))
          .set(modifiedTask.toJsonMap());
    }
  }

  /// Retrieves modified version of the [originalTask] or null
  ///
  /// See [setModifiedTask]
  Future<Task?> getModifiedTask(Task originalTask) async {
    final jsonMap = await _db
        .collection(modifiedTasksPath)
        .doc(_safeId(originalTask.taskId))
        .get();
    if (jsonMap == null) {
      return null;
    }
    return Task.createFromJsonMap(jsonMap);
  }

  /// Remove modified [task], or all if null
  Future<void> removeModifiedTask([Task? task]) async {
    if (task == null) {
      await _db.collection(modifiedTasksPath).delete();
      return;
    }
    await _db.collection(modifiedTasksPath).doc(task.taskId).delete();
  }

  /// Closes the [updates] stream and re-initializes the [StreamController]
  /// such that the stream can be listened to again
  Future<void> resetUpdatesStreamController() async {
    if (updates.hasListener && !updates.isPaused) {
      await updates.close();
    }
    updates = StreamController();
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
    removeResumeData(); // removes all
    removePausedTask(); // removes all
    removeModifiedTask(); // removes all
    resetUpdatesStreamController();
  }

  /// Process status update coming from Downloader and emits to listener
  ///
  /// Also manages retries ([tasksWaitingToRetry] and delay) and pause/resume
  /// ([pausedTasks] and [_clearPauseResumeInfo]
  void processStatusUpdate(TaskStatusUpdate update) {
    // Normal status updates are only sent here when the task is expected
    // to provide those.  The exception is a .failed status when a task
    // has retriesRemaining > 0: those are always sent here, and are
    // intercepted to hold the task and reschedule in the near future
    final task = update.task;
    if (update.status == TaskStatus.failed && task.retriesRemaining > 0) {
      _emitStatusUpdate(TaskStatusUpdate(task, TaskStatus.waitingToRetry));
      _emitProgressUpdate(TaskProgressUpdate(task, progressWaitingToRetry));
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
            removeModifiedTask(task);
            _clearPauseResumeInfo(task);
            _emitStatusUpdate(TaskStatusUpdate(
                task,
                TaskStatus.failed,
                TaskException(
                    'Could not enqueue task $task after retry timeout')));
            _emitProgressUpdate(TaskProgressUpdate(task, progressFailed));
          }
        }
      });
    } else {
      // normal status update
      if (update.status == TaskStatus.paused) {
        setPausedTask(task);
      }
      if (update.status.isFinalState) {
        removeModifiedTask(task);
        _clearPauseResumeInfo(task);
      }
      _emitStatusUpdate(update);
    }
  }

  /// Process progress update coming from Downloader to client listener
  void processProgressUpdate(TaskProgressUpdate update) {
    _emitProgressUpdate(update);
  }

  /// Process user tapping on a notification
  ///
  /// Because a notification tap may cause the app to start from scratch, we
  /// allow a few retries with backoff to let the app register a callback
  Future<void> processNotificationTap(
      Task task, NotificationType notificationType) async {
    var retries = 0;
    var success = false;
    while (retries < 5 && !success) {
      final notificationTapCallback = groupNotificationTapCallbacks[task.group];
      if (notificationTapCallback != null) {
        notificationTapCallback(task, notificationType);
        success = true;
      } else {
        await Future.delayed(
            Duration(milliseconds: 100 * pow(2, retries).round()));
        retries++;
      }
    }
  }

  /// Emits the status update for this task to its callback or listener, and
  /// update the task in the database
  void _emitStatusUpdate(TaskStatusUpdate update) {
    final task = update.task;
    _updateTaskInDatabase(task,
        status: update.status, taskException: update.exception);
    if (task.providesStatusUpdates) {
      final taskStatusCallback = groupStatusCallbacks[task.group];
      if (taskStatusCallback != null) {
        taskStatusCallback(update);
      } else {
        if (updates.hasListener) {
          updates.add(update);
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
  void _emitProgressUpdate(TaskProgressUpdate update) {
    final task = update.task;
    _updateTaskInDatabase(task, progress: update.progress);
    if (task.providesProgressUpdates) {
      final taskProgressCallback = groupProgressCallbacks[task.group];
      if (taskProgressCallback != null) {
        taskProgressCallback(update);
      } else if (updates.hasListener) {
        updates.add(update);
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
      {TaskStatus? status,
      double? progress,
      TaskException? taskException}) async {
    if (trackedGroups.contains(null) || trackedGroups.contains(task.group)) {
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
      Database()
          .updateRecord(TaskRecord(task, status!, progress!, taskException));
    }
  }

  final _illegalPathCharacters = RegExp(r'[\\/:*?"<>|]');

  /// Make the id safe for storing in the localStore
  String _safeId(String id) => id.replaceAll(_illegalPathCharacters, '_');
}
