// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/json_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JsonProcessor Functional Tests', () {
    test('processTaskFromJson decodes correctly', () async {
      final task = DownloadTask(
          url: 'https://google.com',
          filename: 'test.html',
          headers: {'Cookie': 'foo=bar'});
      final jsonString = jsonEncode(task.toJson());

      final result =
          await JsonProcessor().decodeTask(jsonString);

      expect(result, isA<DownloadTask>());
      expect(result.url, equals(task.url));
      expect(result.filename, equals(task.filename));
      expect(result.headers, equals(task.headers));
    });

    test('processDownloadTaskListFromJson decodes list correctly', () async {
      final task1 = DownloadTask(url: 'https://google.com/1', filename: '1');
      final task2 = DownloadTask(url: 'https://google.com/2', filename: '2');
      final list = [task1, task2];
      final jsonString = jsonEncode(list);

      final result = await JsonProcessor()
          .decodeDownloadTaskList(jsonString);

      expect(result, hasLength(2));
      expect(result[0].url, equals(task1.url));
      expect(result[1].url, equals(task2.url));
    });

    test('processTaskListFromListStrings decodes list of strings correctly',
        () async {
      final task1 = DownloadTask(url: 'https://google.com/1', filename: '1');
      final task2 = DownloadTask(url: 'https://google.com/2', filename: '2');
      final listStrings = [
        jsonEncode(task1.toJson()),
        jsonEncode(task2.toJson())
      ];

      final result = await JsonProcessor()
          .decodeTaskList(listStrings);

      expect(result, hasLength(2));
      expect(result[0].url, equals(task1.url));
      expect(result[1].url, equals(task2.url));
    });

    test('processTaskAndNotificationConfigJsonStrings encodes correctly',
        () async {
      final task = DownloadTask(url: 'https://google.com', filename: 'test');
      final tasks = [task];
      final configs = {
        TaskNotificationConfig(
            taskOrGroup: task,
            running: const TaskNotification('Running', 'body'))
      };

      final (tasksJson, configsJson) = await JsonProcessor()
          .encodeTaskAndNotificationConfig(tasks, configs);

      final decodedTasks = jsonDecode(tasksJson);
      expect(decodedTasks, isA<List>());
      expect(decodedTasks[0]['url'], equals(task.url));

      final decodedConfigs = jsonDecode(configsJson);
      expect(decodedConfigs, isA<List>());
      // Helper check logic might be complex, but basic existence is good
    });
  });

  test('Benchmark: JsonProcessor vs Direct', () async {
    // 1. Create large task
    final headers = <String, String>{};
    for (var i = 0; i < 1000; i++) {
      headers['header_$i'] = 'value_$i' * 10; // 80 chars value
    }
    final task = DownloadTask(
        url: 'https://example.com/very/long/path/' * 5,
        filename: 'large_task_filename.txt',
        headers: headers,
        metaData: 'some metadata ' * 100);
    final taskJsonString = jsonEncode(task.toJson());
    print('taskJsonString is ${taskJsonString.length} characters');
    // 2. Benchmark

    const iterations = 1000;

    // Method 1: Direct (Main Thread)
    final stopwatchDirect = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      final decoded = Task.createFromJson(jsonDecode(taskJsonString));
      // quick check to prevent optimization
      if (decoded.url.isEmpty) throw Exception('Validation failed');
    }
    stopwatchDirect.stop();
    print('Direct (Main Thread): ${stopwatchDirect.elapsedMilliseconds} ms');

    // Method 2: JsonProcessor (Isolate)
    final stopwatchProcessor = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      final decoded =
          await JsonProcessor().decodeTask(taskJsonString);
      // quick check to prevent optimization
      if (decoded.url.isEmpty) throw Exception('Validation failed');
    }
    stopwatchProcessor.stop();
    print(
        'JsonProcessor (Isolate): ${stopwatchProcessor.elapsedMilliseconds} ms');

    // Allow isolate to shutdown naturally or force it if test runner hangs (timer is 1 min)
    // We don't have public shutdown.
  });
}
