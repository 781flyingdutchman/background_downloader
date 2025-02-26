// ignore_for_file: avoid_print, empty_catches

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_utils.dart';

void main() {
  setUp(defaultSetup);

  tearDown(defaultTearDown);

  group('enqueue', () {
    testWidgets('EnqueueAll', (widgetTester) async {
      const numTasks = 10;
      final tasks = <Task>[];
      for (var n = 0; n < numTasks; n++) {
        tasks.add(DownloadTask(url: workingUrl));
      }
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final enqueueResult = await FileDownloader().enqueueAll(tasks);
      for (final result in enqueueResult) {
        expect(result, isTrue);
      }
      await Future.delayed(const Duration(seconds: 2));
      for (final task in tasks) {
        final file = File(await task.filePath());
        try {
          file.deleteSync();
        } on FileSystemException {}
      }
      expect(statusCallbackCounter, equals(3 * numTasks));
    });

    testWidgets('Enqueue Performance Comparison', (widgetTester) async {
      const numTasks = 1000; // Increase for more significant results
      final tasks = <Task>[];
      final tasks2 = <Task>[];
      for (var n = 0; n < numTasks; n++) {
        tasks.add(DownloadTask(
            url: 'https://example.com/file.txt',
            updates: Updates.none)); // Use a dummy URL
        tasks2.add(DownloadTask(
            url: 'https://example.com/file.txt',
            updates: Updates.none)); // Use a dummy URL
      }

      final fileDownloader = FileDownloader();

      // Measure enqueue (one by one) time
      final enqueueStartTime = DateTime.now();
      for (final task in tasks) {
        await fileDownloader.enqueue(task);
      }
      final enqueueEndTime = DateTime.now();
      final enqueueDuration = enqueueEndTime.difference(enqueueStartTime);
      print('Enqueue (one by one) took: ${enqueueDuration.inMilliseconds}ms');

      // Measure enqueueAll time
      final enqueueAllStartTime = DateTime.now();
      await fileDownloader.enqueueAll(tasks2);
      final enqueueAllEndTime = DateTime.now();
      final enqueueAllDuration =
          enqueueAllEndTime.difference(enqueueAllStartTime);
      print('enqueueAll took: ${enqueueAllDuration.inMilliseconds}ms');

      await Future.delayed(const Duration(seconds: 5));

      // Clean up
      for (final task in tasks) {
        final file = File(await task.filePath());
        try {
          file.deleteSync();
        } on FileSystemException {}
      }
      for (final task in tasks2) {
        final file = File(await task.filePath());
        try {
          file.deleteSync();
        } on FileSystemException {}
      }

      // Simply pass the test
      expect(true, isTrue); // Just to have a passing test
    });
  });
}
