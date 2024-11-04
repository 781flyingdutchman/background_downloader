import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Task?> onTaskStartFunction(Task original) async {
  return original;
}

Future<void> onTaskFinishedCallback(TaskStatusUpdate statusUpdate) async {}

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
}
