import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'base_downloader.dart';
import 'exceptions.dart';
import 'models.dart';

/// Implementation of download functionality for native platforms
///
/// Uses [MethodChannel] to communicate with native platforms
final class NativeDownloader extends BaseDownloader {
  static final NativeDownloader _singleton = NativeDownloader._internal();
  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.background_downloader.background');

  factory NativeDownloader() {
    return _singleton;
  }

  NativeDownloader._internal();

  @override
  Future<void> initialize() async {
    await super.initialize();
    WidgetsFlutterBinding.ensureInitialized();
    // listen to the background channel, receiving updates on download status
    // or progress.
    // First argument is the Task as JSON string, next argument(s) depends
    // on the method
    _backgroundChannel.setMethodCallHandler((call) async {
      final args = call.arguments as List<dynamic>;
      final task = Task.createFromJsonMap(jsonDecode(args.first as String));
      final message = (
        call.method,
        args.length > 2
            ? args.getRange(1, args.length).toList(growable: false)
            : args[1]
      );
      switch (message) {
        case ('statusUpdate', int statusOrdinal):
          final status = TaskStatus.values[statusOrdinal];
          await killFailedTask(task, status);
          processStatusUpdate(TaskStatusUpdate(task, status));

        case (
            'statusUpdate',
            [
              int statusOrdinal,
              String typeString,
              String description,
              int httpResponseCode
            ]
          ):
          final status = TaskStatus.values[statusOrdinal];
          await killFailedTask(task, status);
          TaskException? exception;
          if (status == TaskStatus.failed) {
            exception = TaskException.fromTypeString(
                typeString, description, httpResponseCode);
          }
          processStatusUpdate(TaskStatusUpdate(task, status, exception));

        case ('progressUpdate', [double progress, int expectedFileSize]):
          processProgressUpdate(
              TaskProgressUpdate(task, progress, expectedFileSize));

        case ('canResume', bool canResume):
          setCanResume(task, canResume);

        case ('resumeData', [String tempFilename, int requiredStartByte]):
          setResumeData(ResumeData(task, tempFilename, requiredStartByte));

        case ('notificationTap', int notificationTypeOrdinal):
          final notificationType =
              NotificationType.values[notificationTypeOrdinal];
          processNotificationTap(task, notificationType);

        default:
          throw StateError('Background channel: no match for message $message');
      }
    });
  }

  @override
  Future<bool> enqueue(Task task,
      [TaskNotificationConfig? notificationConfig]) async {
    super.enqueue(task);
    return await _channel.invokeMethod<bool>('enqueue', [
          jsonEncode(task.toJsonMap()),
          notificationConfig != null
              ? jsonEncode(notificationConfig.toJsonMap())
              : null,
        ]) ??
        false;
  }

  @override
  Future<int> reset(String group) async {
    final retryAndPausedTaskCount = await super.reset(group);
    final nativeCount = await _channel.invokeMethod<int>('reset', group) ?? 0;
    return retryAndPausedTaskCount + nativeCount;
  }

  @override
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final retryAndPausedTasks =
        await super.allTasks(group, includeTasksWaitingToRetry);
    final result =
        await _channel.invokeMethod<List<dynamic>?>('allTasks', group) ?? [];
    final tasks = result
        .map((e) => Task.createFromJsonMap(jsonDecode(e as String)))
        .toList();
    return [...retryAndPausedTasks, ...tasks];
  }

  @override
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds) async =>
      await _channel.invokeMethod<bool>('cancelTasksWithIds', taskIds) ?? false;

  /// Kills the task if it failed, on Android only
  ///
  /// See methodKillTaskWithId in the Android plugin for explanation
  Future<void> killFailedTask(Task task, TaskStatus status) async {
    if (Platform.isAndroid &&
        (status == TaskStatus.failed || status == TaskStatus.canceled)) {
      _channel.invokeMethod('killTaskWithId', task.taskId);
    }
  }

  @override
  Future<Task?> taskForId(String taskId) async {
    var task = await super.taskForId(taskId);
    if (task != null) {
      return task;
    }
    final jsonString = await _channel.invokeMethod<String>('taskForId', taskId);
    if (jsonString != null) {
      return Task.createFromJsonMap(jsonDecode(jsonString));
    }
    return null;
  }

  @override
  Future<bool> pause(Task task) async =>
      await _channel.invokeMethod<bool>('pause', task.taskId) ?? false;

  @override
  Future<bool> resume(Task task,
      [TaskNotificationConfig? notificationConfig]) async {
    if (await super.resume(task)) {
      final taskResumeData = await getResumeData(task.taskId);
      if (taskResumeData != null) {
        return await _channel.invokeMethod<bool>('enqueue', [
              jsonEncode(task.toJsonMap()),
              notificationConfig != null
                  ? jsonEncode(notificationConfig.toJsonMap())
                  : null,
              taskResumeData.data,
              taskResumeData.requiredStartByte
            ]) ??
            false;
      }
    }
    return false;
  }

  /// Retrieve data that was not delivered to Dart, as a Map keyed by taskId
  /// with one map for each taskId
  ///
  /// Asks the native platform for locally stored data for resumeData,
  /// status updates or progress updates.
  /// ResumeData has a [ResumeData] json representation
  /// StatusUpdates has a mixed Task & TaskStatus json representation 'taskStatus'
  /// ProgressUpdates has a mixed Task & double json representation 'progress'
  @override
  Future<Map<String, dynamic>> popUndeliveredData(Undelivered dataType) async {
    final String jsonMapString = await switch (dataType) {
      Undelivered.resumeData => _channel.invokeMethod('popResumeData'),
      Undelivered.statusUpdates => _channel.invokeMethod('popStatusUpdates'),
      Undelivered.progressUpdates => _channel.invokeMethod('popProgressUpdates')
    };
    return jsonDecode(jsonMapString);
  }

  @override
  Future<Duration> getTaskTimeout() async {
    if (Platform.isAndroid) {
      final timeoutMillis =
          await _channel.invokeMethod<int>('getTaskTimeout') ?? 0;
      return Duration(milliseconds: timeoutMillis);
    }
    return const Duration(hours: 4); // on iOS, resource timeout
  }

  @override
  Future<void> setForceFailPostOnBackgroundChannel(bool value) async {
    await _channel.invokeMethod('forceFailPostOnBackgroundChannel', value);
  }

  @override
  Future<String?> moveToSharedStorage(String filePath,
          SharedStorage destination, String directory, String? mimeType) =>
      _channel.invokeMethod<String?>('moveToSharedStorage',
          [filePath, destination.index, directory, mimeType]);

  @override
  Future<String?> pathInSharedStorage(
          String filePath, SharedStorage destination, String directory) =>
      _channel.invokeMethod<String?>(
          'pathInSharedStorage', [filePath, destination.index, directory]);

  @override
  Future<bool> openFile(Task? task, String? filePath, String? mimeType) async {
    final result = await _channel.invokeMethod<bool>('openFile', [
      task != null ? jsonEncode(task.toJsonMap()) : null,
      filePath,
      mimeType
    ]);
    return result ?? false;
  }
}
