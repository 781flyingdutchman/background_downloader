import 'dart:async';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var enqueueResult = true;

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '/tmp',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (MethodCall call) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.bbflight.background_downloader'),
      (MethodCall call) async => switch (call.method) {
        'enqueue' => enqueueResult,
        'pause' || 'resume' || 'cancelTasksWithIds' => true,
        'enqueueAll' =>
          (jsonDecode(call.arguments[0] as String) as List)
              .map((_) => enqueueResult)
              .toList(),
        'reset' => 0,
        'platformVersion' => '34',
        'allTasks' => <dynamic>[],
        'taskForId' => null,
        'popResumeData' ||
        'popStatusUpdates' ||
        'popProgressUpdates' => '{}',
        _ => null,
      },
    );
  });

  setUp(() {
    enqueueResult = true;
    FileDownloader().destroy();
  });

  tearDown(() {
    FileDownloader().destroy();
    FileDownloader().isConnected = true;
  });

  group('Failure while offline', () {
    test('non-connection failure while offline fails a task without retries',
        () async {
      final downloader = FileDownloader().downloaderForTesting;
      final statuses = <TaskStatus>[];
      final subscription = FileDownloader().updates.listen((update) {
        if (update is TaskStatusUpdate) statuses.add(update.status);
      });
      final task = DownloadTask(url: 'https://example.com/file.bin');
      FileDownloader().isConnected = false;
      downloader.processStatusUpdate(
        TaskStatusUpdate(
          task,
          TaskStatus.failed,
          TaskHttpException('Forbidden', 403),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(statuses, equals([TaskStatus.failed]));
      expect(downloader.tasksWaitingToRetry, isEmpty);
      await subscription.cancel();
    });

    test('connection failure while offline is held until network restored',
        () async {
      final downloader = FileDownloader().downloaderForTesting;
      final statuses = <TaskStatus>[];
      final subscription = FileDownloader().updates.listen((update) {
        if (update is TaskStatusUpdate) statuses.add(update.status);
      });
      final task = DownloadTask(url: 'https://example.com/file.bin');
      FileDownloader().isConnected = false;
      downloader.processStatusUpdate(
        TaskStatusUpdate(
          task,
          TaskStatus.failed,
          TaskConnectionException('Connection lost'),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(statuses, equals([TaskStatus.waitingToRetry]));
      expect(downloader.tasksWaitingToRetry, contains(task));
      await subscription.cancel();
    });
  });
}
