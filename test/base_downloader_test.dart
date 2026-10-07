import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var enqueueResult = true;
  MethodCall? lastEnqueueCall;

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
        'enqueue' => () {
          lastEnqueueCall = call;
          return enqueueResult;
        }(),
        'pause' || 'resume' || 'cancelTasksWithIds' => true,
        'enqueueAll' => (jsonDecode(
          call.arguments[0] as String,
        ) as List).map((_) => enqueueResult).toList(),
        'reset' => 0,
        'platformVersion' => '34',
        'allTasks' => <dynamic>[],
        'taskForId' => null,
        'popResumeData' || 'popStatusUpdates' || 'popProgressUpdates' => '{}',
        _ => null,
      },
    );
  });

  setUp(() {
    enqueueResult = true;
    lastEnqueueCall = null;
    FileDownloader().destroy();
  });

  tearDown(() {
    FileDownloader().destroy();
    FileDownloader().isConnected = true;
  });

  group('Failure while offline', () {
    test(
      'non-connection failure while offline fails a task without retries',
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
      },
    );

    test(
      'connection failure while offline is held until network restored',
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
      },
    );
  });

  group('enqueueAndAwait when enqueue fails', () {
    test('callbacks and elapsed time timer are removed', () async {
      enqueueResult = false;
      final statuses = <TaskStatus>[];
      var elapsedTimeCalls = 0;
      final task = DownloadTask(url: 'https://example.com/file.bin');
      final result = await FileDownloader().download(
        task,
        onStatus: statuses.add,
        onElapsedTime: (_) => elapsedTimeCalls++,
        elapsedTimeInterval: const Duration(milliseconds: 10),
      );
      expect(result.status, equals(TaskStatus.failed));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(elapsedTimeCalls, equals(0));
      // a later update for the same task must not reach the stale callback
      FileDownloader().downloaderForTesting.processStatusUpdate(
        TaskStatusUpdate(task, TaskStatus.complete),
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(statuses, isEmpty);
      expect(FileDownloader().downloaderForTesting.awaitTasks, isEmpty);
    });
  });

  group('Task.notificationConfig', () {
    test('is used on enqueue, overrides group config, survives json', () async {
      FileDownloader().configureNotificationForGroup(
        FileDownloader.defaultGroup,
        complete: const TaskNotification('Group complete', ''),
      );
      final task = DownloadTask(
        url: 'https://example.com/file.bin',
        notificationConfig: TaskNotificationConfig(
          complete: const TaskNotification('Task complete', ''),
        ),
      );
      expect(await FileDownloader().enqueue(task), isTrue);
      final sentConfig = jsonDecode(
        (lastEnqueueCall!.arguments as List)[1] as String,
      );
      expect(sentConfig['complete']['title'], equals('Task complete'));
      // a task restored from json (e.g. for a retry) has no notificationConfig,
      // but the registered configuration still applies
      final restoredTask = Task.createFromJson(
        FileDownloader().withNamespacedGroup(task).toJson(),
      );
      expect(restoredTask.notificationConfig, isNull);
      expect(
        FileDownloader().downloaderForTesting
            .notificationConfigForTask(restoredTask)
            ?.complete
            ?.title,
        equals('Task complete'),
      );
    });

    test('is used on enqueueAll', () async {
      final task = DownloadTask(
        url: 'https://example.com/file.bin',
        notificationConfig: TaskNotificationConfig(
          running: const TaskNotification('Task running', ''),
        ),
      );
      expect(await FileDownloader().enqueueAll([task]), equals([true]));
      expect(
        FileDownloader().notificationConfigForTask(task)?.running?.title,
        equals('Task running'),
      );
    });
  });
}
