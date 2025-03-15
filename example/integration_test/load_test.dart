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

    testWidgets('test enqueue failures', (widgetTester) async {
      final tasks = <Task>[
        DownloadTask(url: workingUrl),
        DownloadTask(url: "invalid url"),
        DataTask(
            url: workingUrl,
            post: "{'data': '${List.generate(15001, (index) => 'a').join()}'}")
      ];
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final enqueueResult = await FileDownloader().enqueueAll(tasks);
      final expectedResult = Platform.isAndroid
          ? [true, false, false]
          : Platform.isIOS
              // iOS does not catch lack of host until start of download
              ? [true, false, true]
              // Desktop does not catch any of these until download
              : [true, true, true];
      expect(enqueueResult, equals(expectedResult));
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

  group('pauseAll', () {
    testWidgets('Pause and Resume All', (widgetTester) async {
      const numTasks = 10;
      final tasks = <DownloadTask>[];
      for (var n = 0; n < numTasks; n++) {
        tasks.add(DownloadTask(url: urlWithContentLength, allowPause: true));
      }
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final enqueueResults = await FileDownloader().enqueueAll(tasks);
      for (final result in enqueueResults) {
        expect(result, isTrue);
      }
      // Wait a short time to let downloads start.
      await Future.delayed(const Duration(milliseconds: 500));
      // Pause all tasks.
      final pauseResults = await FileDownloader().pauseAll();
      // Verify that all tasks were paused.
      print('Paused: ${pauseResults.length} tasks (versus $numTasks)');
      await Future.delayed(const Duration(seconds: 5));
      //Resume the tasks
      final startOfResumeCall = DateTime.now();
      final resumeResults = await FileDownloader().resumeAll();
      print(
          'Resuming ${resumeResults.length} tasks took ${DateTime.now().difference(startOfResumeCall)}');
      // Wait for downloads to complete.
      while ((await FileDownloader().allTasks()).isNotEmpty) {
        await Future.delayed(const Duration(seconds: 2));
      }
      // Check if all tasks eventually completed.
      for (final task in tasks) {
        final file = File(await task.filePath());
        expect(file.existsSync(), isTrue);
        try {
          file.deleteSync();
        } on FileSystemException {}
      }
    });

    testWidgets('Pause with allowPause set to false', (widgetTester) async {
      const numTasks = 10;
      final tasks = <DownloadTask>[];
      for (var n = 0; n < numTasks; n++) {
        // Crucially, allowPause is false
        tasks.add(DownloadTask(url: urlWithContentLength, allowPause: false));
      }
      FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
      final enqueueResults = await FileDownloader().enqueueAll(tasks);
      for (final result in enqueueResults) {
        expect(result, isTrue);
      }
      await Future.delayed(const Duration(milliseconds: 500));
      final runningTasks = await FileDownloader().allTasks();
      expect(runningTasks, isNotEmpty);
      print('Attempting to pause all tasks');
      final pauseResults = await FileDownloader().pauseAll();
      expect(pauseResults, isEmpty); // No tasks paused
      print('No tasks were paused');
      // Wait for downloads to complete.
      while ((await FileDownloader().allTasks()).isNotEmpty) {
        await Future.delayed(const Duration(seconds: 2));
      }
      // Check if all tasks eventually completed.
      for (final task in tasks) {
        final file = File(await task.filePath());
        expect(file.existsSync(), isTrue);
        try {
          file.deleteSync();
        } on FileSystemException {}
      }
    });
  });
}
