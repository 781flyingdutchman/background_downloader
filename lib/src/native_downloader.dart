import 'dart:convert';

import 'package:background_downloader/src/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'base_downloader.dart';

/// Implementation of download functionality for native platforms
///
/// Uses [MethodChannel] to communicate with native platforms
class NativeDownloader extends BaseDownloader {
  static final NativeDownloader _singleton = NativeDownloader._internal();
  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.background_downloader.background');

  factory NativeDownloader() {
    return _singleton;
  }

  NativeDownloader._internal();

  @override
  void initialize() {
    super.initialize();
    WidgetsFlutterBinding.ensureInitialized();
    // listen to the background channel, receiving updates on download status
    // or progress
    _backgroundChannel.setMethodCallHandler((call) async {
      final args = call.arguments as List<dynamic>;
      final task = Task.createFromJsonMap(jsonDecode(args.first as String));
      switch (call.method) {
        case 'statusUpdate':
          final taskStatus = TaskStatus.values[args.last as int];
          processStatusUpdate(task, taskStatus);
          break;

        case 'progressUpdate':
          final progress = args.last as double;
          processProgressUpdate(task, progress);
          break;

        default:
          throw UnimplementedError(
              'Background channel method call ${call.method} not supported');
      }
    });
  }

  @override
  Future<bool> enqueue(Task task) async =>
      await _channel
          .invokeMethod<bool>('enqueue', [jsonEncode(task.toJsonMap())]) ??
      false;

  @override
  Future<int> reset(String group) async {
    final retriesTaskCount = await super.reset(group);
    final nativeCount = await _channel.invokeMethod<int>('reset', group) ?? 0;
    return retriesTaskCount + nativeCount;
  }

  @override
  Future<List<Task>> allTasks(
      String group, bool includeTasksWaitingToRetry) async {
    final retryTasks = await super.allTasks(group, includeTasksWaitingToRetry);
    final result =
        await _channel.invokeMethod<List<dynamic>?>('allTasks', group) ?? [];
    final tasks = result
        .map((e) => Task.createFromJsonMap(jsonDecode(e as String)))
        .toList();
    return [...retryTasks, ...tasks];
  }

  @override
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds) async =>
      await _channel.invokeMethod<bool>('cancelTasksWithIds', taskIds) ?? false;

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
}
