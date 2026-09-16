import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/background_downloader.dart';

class InMemoryPersistentStorage implements PersistentStorage {
  final Map<String, TaskRecord> records = {};
  final Map<String, Task> pausedTasks = {};
  final Map<String, ResumeData> resumeData = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    records[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async =>
      records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();

  @override
  Future<void> removeTaskRecord(String? taskId) async {
    if (taskId == null) {
      records.clear();
    } else {
      records.remove(taskId);
    }
  }

  @override
  (String, int) get currentDatabaseVersion => ('', 0);

  @override
  Future<(String, int)> get storedDatabaseVersion async => ('', 0);

  @override
  Future<void> removePausedTask(String? taskId) async {
    if (taskId == null) {
      pausedTasks.clear();
    } else {
      pausedTasks.remove(taskId);
    }
  }

  @override
  Future<void> removeResumeData(String? taskId) async {
    if (taskId == null) {
      resumeData.clear();
    } else {
      resumeData.remove(taskId);
    }
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() async =>
      pausedTasks.values.toList();

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      resumeData.values.toList();

  @override
  Future<Task?> retrievePausedTask(String taskId) async => pausedTasks[taskId];

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async =>
      resumeData[taskId];

  @override
  Future<void> storePausedTask(Task task) async {
    pausedTasks[task.taskId] = task;
  }

  @override
  Future<void> storeResumeData(ResumeData resumeData) async {
    this.resumeData[resumeData.taskId] = resumeData;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryPersistentStorage testStorage;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => '/tmp',
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (MethodCall call) async => ['wifi'],
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bbflight.background_downloader'),
          (MethodCall call) async {
            switch (call.method) {
              case 'enqueue':
              case 'pause':
              case 'resume':
              case 'cancelTasksWithIds':
                return true;
              case 'enqueueAll':
                final tasksJson =
                    jsonDecode(call.arguments[0] as String) as List;
                return tasksJson.map((_) => true).toList();
              case 'reset':
                return 0;
              case 'platformVersion':
                return '34';
              case 'allTasks':
                return <dynamic>[];
              case 'taskForId':
                return null;
              case 'popResumeData':
              case 'popStatusUpdates':
              case 'popProgressUpdates':
                return '{}';
              default:
                return null;
            }
          },
        );
    testStorage = InMemoryPersistentStorage();
    FileDownloader(persistentStorage: testStorage);
  });

  tearDown(() {
    FileDownloader().destroy();
  });

  test('Issue #727: updates stream receives all updates when doTrackTasks: true and task is enqueued', () async {
    final receivedUpdates = <TaskUpdate>[];
    final subscription = FileDownloader().updates.listen((update) {
      receivedUpdates.add(update);
    });

    await FileDownloader().start(doTrackTasks: true);

    final task = DownloadTask(
      taskId: 'task_727',
      url: 'https://storage.googleapis.com/test/file.tar.xz',
      filename: 'test_enqueue.bin',
      updates: Updates.statusAndProgress,
    );

    final enqueued = await FileDownloader().enqueue(task);
    expect(enqueued, isTrue);

    // 1. Initial updates (enqueued, running, progress 0.0)
    final statusEnqueued = TaskStatusUpdate(task, TaskStatus.enqueued);
    final statusRunning = TaskStatusUpdate(task, TaskStatus.running);
    final progress0 = TaskProgressUpdate(task, 0.0);

    FileDownloader().downloaderForTesting.processStatusUpdate(statusEnqueued);
    FileDownloader().downloaderForTesting.processStatusUpdate(statusRunning);
    FileDownloader().downloaderForTesting.processProgressUpdate(progress0);

    // Wait for database async queue / stream processing
    await Future.delayed(const Duration(milliseconds: 100));

    // 2. Subsequent updates during download
    final progress50 = TaskProgressUpdate(task, 0.5);
    final statusComplete = TaskStatusUpdate(task, TaskStatus.complete);
    final progress100 = TaskProgressUpdate(task, 1.0);

    FileDownloader().downloaderForTesting.processProgressUpdate(progress50);
    FileDownloader().downloaderForTesting.processStatusUpdate(statusComplete);
    FileDownloader().downloaderForTesting.processProgressUpdate(progress100);

    await Future.delayed(const Duration(milliseconds: 100));

    expect(
      receivedUpdates.whereType<TaskStatusUpdate>().map((u) => u.status),
      containsAllInOrder([
        TaskStatus.enqueued,
        TaskStatus.running,
        TaskStatus.complete,
      ]),
    );
    expect(
      receivedUpdates.whereType<TaskProgressUpdate>().map((u) => u.progress),
      containsAllInOrder([0.0, 0.5, 1.0]),
    );

    await subscription.cancel();
  });
}
