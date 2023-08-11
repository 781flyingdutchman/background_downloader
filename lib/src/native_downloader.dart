import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'base_downloader.dart';
import 'exceptions.dart';
import 'models.dart';

/// Implementation of download functionality for native platforms
///
/// Uses [MethodChannel] to communicate with native platforms
abstract base class NativeDownloader extends BaseDownloader {
  static const methodChannel =
      MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.background_downloader.background');

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
        // simple status update
        case ('statusUpdate', int statusOrdinal):
          final status = TaskStatus.values[statusOrdinal];
          processStatusUpdate(TaskStatusUpdate(task, status));

        // status update with responseBody, no exception
        case ('statusUpdate', [int statusOrdinal, String? responseBody]):
          final status = TaskStatus.values[statusOrdinal];
          processStatusUpdate(
              TaskStatusUpdate(task, status, null, responseBody));

        // status update with TaskException and responseBody
        case (
            'statusUpdate',
            [
              int statusOrdinal,
              String typeString,
              String description,
              int httpResponseCode,
              String? responseBody
            ]
          ):
          final status = TaskStatus.values[statusOrdinal];
          TaskException? exception;
          if (status == TaskStatus.failed) {
            exception = TaskException.fromTypeString(
                typeString, description, httpResponseCode);
          }
          processStatusUpdate(
              TaskStatusUpdate(task, status, exception, responseBody));

        case (
            'progressUpdate',
            [
              double progress,
              int expectedFileSize,
              double networkSpeed,
              int timeRemaining
            ]
          ):
          processProgressUpdate(TaskProgressUpdate(
              task,
              progress,
              expectedFileSize,
              networkSpeed,
              Duration(milliseconds: timeRemaining)));

        case ('canResume', bool canResume):
          setCanResume(task, canResume);

        case ('resumeData', [String tempFilename, int requiredStartByte, String? eTag]):
          setResumeData(ResumeData(task, tempFilename, requiredStartByte, eTag));

        case ('notificationTap', int notificationTypeOrdinal):
          final notificationType =
              NotificationType.values[notificationTypeOrdinal];
          processNotificationTap(task, notificationType);
          return true; // this message requires a confirmation

        default:
          throw StateError('Background channel: no match for message $message');
      }
    });
  }

  @override
  Future<bool> enqueue(Task task) async {
    super.enqueue(task);
    final notificationConfig = notificationConfigForTask(task);
    return await methodChannel.invokeMethod<bool>('enqueue', [
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
    final nativeCount =
        await methodChannel.invokeMethod<int>('reset', group) ?? 0;
    return retryAndPausedTaskCount + nativeCount;
  }

  @override
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final retryAndPausedTasks =
        await super.allTasks(group, includeTasksWaitingToRetry);
    final result =
        await methodChannel.invokeMethod<List<dynamic>?>('allTasks', group) ??
            [];
    final tasks = result
        .map((e) => Task.createFromJsonMap(jsonDecode(e as String)))
        .toList();
    return [...retryAndPausedTasks, ...tasks];
  }

  @override
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds) async =>
      await methodChannel.invokeMethod<bool>('cancelTasksWithIds', taskIds) ??
      false;

  @override
  Future<Task?> taskForId(String taskId) async {
    var task = await super.taskForId(taskId);
    if (task != null) {
      return task;
    }
    final jsonString =
        await methodChannel.invokeMethod<String>('taskForId', taskId);
    if (jsonString != null) {
      return Task.createFromJsonMap(jsonDecode(jsonString));
    }
    return null;
  }

  @override
  Future<bool> pause(Task task) async =>
      await methodChannel.invokeMethod<bool>('pause', task.taskId) ?? false;

  @override
  Future<bool> resume(Task task) async {
    if (await super.resume(task)) {
      final taskResumeData = await getResumeData(task.taskId);
      if (taskResumeData != null) {
        final notificationConfig = notificationConfigForTask(task);
        return await methodChannel.invokeMethod<bool>('enqueue', [
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
      Undelivered.resumeData => methodChannel.invokeMethod('popResumeData'),
      Undelivered.statusUpdates =>
        methodChannel.invokeMethod('popStatusUpdates'),
      Undelivered.progressUpdates =>
        methodChannel.invokeMethod('popProgressUpdates')
    };
    return jsonDecode(jsonMapString);
  }

  @override
  Future<Duration> getTaskTimeout() async {
    if (Platform.isAndroid) {
      final timeoutMillis =
          await methodChannel.invokeMethod<int>('getTaskTimeout') ?? 0;
      return Duration(milliseconds: timeoutMillis);
    }
    return const Duration(hours: 4); // on iOS, resource timeout
  }

  @override
  Future<void> setForceFailPostOnBackgroundChannel(bool value) async {
    await methodChannel.invokeMethod('forceFailPostOnBackgroundChannel', value);
  }

  @override
  Future<String?> moveToSharedStorage(String filePath,
          SharedStorage destination, String directory, String? mimeType) =>
      methodChannel.invokeMethod<String?>('moveToSharedStorage',
          [filePath, destination.index, directory, mimeType]);

  @override
  Future<String?> pathInSharedStorage(
          String filePath, SharedStorage destination, String directory) =>
      methodChannel.invokeMethod<String?>(
          'pathInSharedStorage', [filePath, destination.index, directory]);

  @override
  Future<bool> openFile(Task? task, String? filePath, String? mimeType) async {
    final result = await methodChannel.invokeMethod<bool>('openFile', [
      task != null ? jsonEncode(task.toJsonMap()) : null,
      filePath,
      mimeType
    ]);
    return result ?? false;
  }

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async {
    switch (configItem) {
      case ('requestTimeout', Duration? duration):
        await NativeDownloader.methodChannel
            .invokeMethod('configRequestTimeout', duration?.inSeconds);

      case ('proxy', (String address, int port)):
        await NativeDownloader.methodChannel
            .invokeMethod('configProxyAddress', address);
        await NativeDownloader.methodChannel
            .invokeMethod('configProxyPort', port);

      case ('proxy', false):
        await NativeDownloader.methodChannel
            .invokeMethod('configProxyAddress', null);
        await NativeDownloader.methodChannel
            .invokeMethod('configProxyPort', null);

      case ('checkAvailableSpace', int minimum):
        assert(minimum > 0, 'Minimum available space must be in MB and > 0');
        await NativeDownloader.methodChannel
            .invokeMethod('configCheckAvailableSpace', minimum);

      case ('checkAvailableSpace', false):
        await NativeDownloader.methodChannel
            .invokeMethod('configCheckAvailableSpace', null);

      default:
        return (
          configItem.$1,
          'not implemented'
        ); // this method did not process this configItem
    }
    return (configItem.$1, ''); // normal result
  }
}

/// Android native downloader
final class AndroidDownloader extends NativeDownloader {
  static final AndroidDownloader _singleton = AndroidDownloader._internal();

  factory AndroidDownloader() {
    return _singleton;
  }
  AndroidDownloader._internal();

  @override
  dynamic platformConfig(
          {dynamic globalConfig,
          dynamic androidConfig,
          dynamic iOSConfig,
          dynamic desktopConfig}) =>
      androidConfig;

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async {
    final superResult = await super.configureItem(configItem);
    if (superResult.$2 != 'not implemented') {
      return superResult;
    }
    switch (configItem) {
      case ('runInForeground', bool activate):
        await NativeDownloader.methodChannel
            .invokeMethod('configForegroundFileSize', activate ? 0 : -1);

      case ('runInForegroundIfFileLargerThan', int fileSize):
        await NativeDownloader.methodChannel
            .invokeMethod('configForegroundFileSize', fileSize);

      case ('bypassTLSCertificateValidation', bool bypass):
        if (bypass) {
          if (kReleaseMode) {
            throw ArgumentError(
                'You cannot bypass certificate validation in release mode');
          }
          await NativeDownloader.methodChannel
              .invokeMethod('configBypassTLSCertificateValidation');
          log.warning(
              'TLS certificate validation is bypassed. This is insecure and cannot be '
              'done in release mode');
        } else {
          throw ArgumentError('To undo bypassing the certificate validation, '
              'restart and leave out the "configBypassCertificateValidation" configuration');
        }

      default:
        return (
          configItem.$1,
          'not implemented'
        ); // this method did not process this configItem
    }
    return (configItem.$1, ''); // normal result
  }
}

/// iOS native downloader
final class IOSDownloader extends NativeDownloader {
  static final IOSDownloader _singleton = IOSDownloader._internal();

  factory IOSDownloader() {
    return _singleton;
  }
  IOSDownloader._internal();

  @override
  dynamic platformConfig(
          {dynamic globalConfig,
          dynamic androidConfig,
          dynamic iOSConfig,
          dynamic desktopConfig}) =>
      iOSConfig;

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async {
    final superResult = await super.configureItem(configItem);
    if (superResult.$2 != 'not implemented') {
      return superResult;
    }
    switch (configItem) {
      case ('resourceTimeout', Duration? duration):
        await NativeDownloader.methodChannel
            .invokeMethod('configResourceTimeout', duration?.inSeconds);

      case ("localize", Map<String, String>? translation):
        await NativeDownloader.methodChannel
            .invokeMethod('configLocalize', translation);

      default:
        return (
          configItem.$1,
          'not implemented'
        ); // this method did not process this configItem
    }
    return (configItem.$1, ''); // normal result
  }
}
