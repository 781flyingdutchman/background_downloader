import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/options/task_options.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Task?> onTaskStartFunction(Task original) async {
  return original;
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
}
