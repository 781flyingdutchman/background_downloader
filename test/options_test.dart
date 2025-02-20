import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

@pragma("vm:entry-point")
Future<Task?> onTaskStartFunction(Task original) async {
  return original;
}

@pragma("vm:entry-point")
Future<void> onTaskFinishedCallback(TaskStatusUpdate statusUpdate) async {}

@pragma("vm:entry-point")
Future<TaskStatusUpdate?> beforeTaskStartCallback(Task task) async {
  return TaskStatusUpdate(task, TaskStatus.enqueued);
}

void main() {
  test('onTaskStartCallback', () async {
    final options = TaskOptions(onTaskStart: onTaskStartFunction);
    expect(options.onTaskStartCallBack, isNotNull);
    expect(options.onTaskStartCallBack, equals(onTaskStartFunction));
    final task = DownloadTask(url: 'https://google.com');
    final result = await options.onTaskStartCallBack?.call(task);
    expect(result, equals(task));
  });

  test('onTaskFinishedCallback', () async {
    final options = TaskOptions(onTaskFinished: onTaskFinishedCallback);
    expect(options.onTaskFinishedCallBack, isNotNull);
    expect(options.onTaskFinishedCallBack, equals(onTaskFinishedCallback));
    final task = DownloadTask(url: 'https://google.com');
    final statusUpdate = TaskStatusUpdate(task, TaskStatus.complete);
    await options.onTaskFinishedCallBack?.call(statusUpdate);
  });

  test('beforeTaskStartCallback', () async {
    final options = TaskOptions(beforeTaskStart: beforeTaskStartCallback);
    expect(options.beforeTaskStartCallBack, isNotNull);
    expect(options.beforeTaskStartCallBack, equals(beforeTaskStartCallback));
    final task = DownloadTask(url: 'https://google.com');
    final statusUpdate = await options.beforeTaskStartCallBack?.call(task);
    expect(statusUpdate?.task, equals(task));
    expect(statusUpdate?.status, equals(TaskStatus.enqueued));
  });
}
