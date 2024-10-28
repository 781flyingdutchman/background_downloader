import 'dart:ui';

import '../task.dart';

typedef OnTaskStartCallback = Future<Task?> Function(Task original);

/// Holds various options related to the task that are not included in the
/// task's properties, as they are rare
class TaskOptions {
  final int? _onTaskStartRawHandle;

  TaskOptions({OnTaskStartCallback? onTaskStart})
      : _onTaskStartRawHandle = onTaskStart != null
            ? PluginUtilities.getCallbackHandle(onTaskStart)?.toRawHandle()
            : null;

  /// Create the object from JSON
  TaskOptions.fromJson(Map<String, dynamic> json)
      : _onTaskStartRawHandle = json['onTaskStartRawHandle'] as int?;

  /// Returns the [OnTaskStartCallback] registered with this [TaskOption]
  OnTaskStartCallback? get onTaskStartCallBack => _onTaskStartRawHandle != null
      ? PluginUtilities.getCallbackFromHandle(
              CallbackHandle.fromRawHandle(_onTaskStartRawHandle))
          as OnTaskStartCallback
      : null;

  /// True if [TaskOptions] contains any callback
  bool get hasCallback => onTaskStartCallBack != null;

  /// Creates JSON map of this object
  Map<String, dynamic> toJson() =>
      {'onTaskStartRawHandle': _onTaskStartRawHandle};
}
