import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';

import '../task.dart';

typedef OnTaskStartCallback = Future<Task?> Function(Task original);

typedef OnTaskFinishedCallback = Future<void> Function(
    TaskStatusUpdate taskStatusUpdate);

/// Holds various options related to the task that are not included in the
/// task's properties, as they are rare
class TaskOptions {
  final int? _onTaskStartRawHandle;
  final int? _onTaskFinishedRawHandle;

  TaskOptions(
      {OnTaskStartCallback? onTaskStart,
      OnTaskFinishedCallback? onTaskFinished})
      : _onTaskStartRawHandle = onTaskStart != null
            ? PluginUtilities.getCallbackHandle(onTaskStart)?.toRawHandle()
            : null,
        _onTaskFinishedRawHandle = onTaskFinished != null
            ? PluginUtilities.getCallbackHandle(onTaskFinished)?.toRawHandle()
            : null;

  /// Create the object from JSON
  TaskOptions.fromJson(Map<String, dynamic> json)
      : _onTaskStartRawHandle = json['onTaskStartRawHandle'] as int?,
        _onTaskFinishedRawHandle = json['onTaskFinishedRawHandle'] as int?;

  /// Returns the [OnTaskStartCallback] registered with this [TaskOption]
  OnTaskStartCallback? get onTaskStartCallBack => _onTaskStartRawHandle != null
      ? PluginUtilities.getCallbackFromHandle(
              CallbackHandle.fromRawHandle(_onTaskStartRawHandle))
          as OnTaskStartCallback
      : null;

  /// Returns the [OnTaskFinishedCallback] registered with this [TaskOption]
  OnTaskFinishedCallback? get onTaskFinishedCallBack =>
      _onTaskFinishedRawHandle != null
          ? PluginUtilities.getCallbackFromHandle(
                  CallbackHandle.fromRawHandle(_onTaskFinishedRawHandle))
              as OnTaskFinishedCallback
          : null;

  /// True if [TaskOptions] contains any callback
  bool get hasCallback =>
      onTaskStartCallBack != null || onTaskFinishedCallBack != null;

  /// Creates JSON map of this object
  Map<String, dynamic> toJson() => {
        'onTaskStartRawHandle': _onTaskStartRawHandle,
        'onTaskFinishedRawHandle': _onTaskFinishedRawHandle
      };
}
