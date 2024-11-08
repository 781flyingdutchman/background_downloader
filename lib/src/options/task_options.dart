import 'dart:ui';

import '../models.dart';
import '../task.dart';
import 'auth.dart';

typedef OnTaskStartCallback = Future<Task?> Function(Task original);

typedef OnTaskFinishedCallback = Future<void> Function(
    TaskStatusUpdate taskStatusUpdate);

/// Holds various options related to the task that are not included in the
/// task's properties, as they are rare
class TaskOptions {
  final int? _onTaskStartRawHandle;
  final int? _onTaskFinishedRawHandle;
  final Auth? auth;

  TaskOptions(
      {OnTaskStartCallback? onTaskStart,
      OnTaskFinishedCallback? onTaskFinished,
      this.auth})
      : _onTaskStartRawHandle = onTaskStart != null
            ? PluginUtilities.getCallbackHandle(onTaskStart)?.toRawHandle()
            : null,
        _onTaskFinishedRawHandle = onTaskFinished != null
            ? PluginUtilities.getCallbackHandle(onTaskFinished)?.toRawHandle()
            : null {
    assert(onTaskStart == null || _onTaskStartRawHandle != null,
        _notTopLevel('onTaskStart'));
    assert(onTaskFinished == null || _onTaskFinishedRawHandle != null,
        _notTopLevel('onTaskFinished'));
  }

  static String _notTopLevel(String callbackName) =>
      '$callbackName callback must be a top level or static function';

  /// Create the object from JSON
  TaskOptions.fromJson(Map<String, dynamic> json)
      : _onTaskStartRawHandle = json['onTaskStartRawHandle'] as int?,
        _onTaskFinishedRawHandle = json['onTaskFinishedRawHandle'] as int?,
        auth = json['auth'] != null ? Auth.fromJson(json['auth']) : null;

  /// Returns the [OnTaskStartCallback] registered with this [TaskOption], or null
  OnTaskStartCallback? get onTaskStartCallBack => _onTaskStartRawHandle != null
      ? PluginUtilities.getCallbackFromHandle(
              CallbackHandle.fromRawHandle(_onTaskStartRawHandle))
          as OnTaskStartCallback
      : null;

  /// Returns the [OnTaskFinishedCallback] registered with this [TaskOption], or null
  OnTaskFinishedCallback? get onTaskFinishedCallBack =>
      _onTaskFinishedRawHandle != null
          ? PluginUtilities.getCallbackFromHandle(
                  CallbackHandle.fromRawHandle(_onTaskFinishedRawHandle))
              as OnTaskFinishedCallback
          : null;

  /// True if [TaskOptions] contains any callback
  bool get hasCallback =>
      onTaskStartCallBack != null ||
      onTaskFinishedCallBack != null ||
      auth?.onAuthCallback != null;

  /// Creates JSON map of this object
  Map<String, dynamic> toJson() => {
        'onTaskStartRawHandle': _onTaskStartRawHandle,
        'onTaskFinishedRawHandle': _onTaskFinishedRawHandle,
        'auth': auth?.toJson()
      };
}
