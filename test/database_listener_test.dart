import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/database.dart';
import 'package:background_downloader/src/persistent_storage.dart';
import 'package:background_downloader/src/models.dart';
import 'package:background_downloader/src/task.dart';

final defaultTask =
    DownloadTask(taskId: 'task1', url: 'https://google.com', group: 'group');

late Database db;

void main() {
  setUp(() {
    db = Database(MockPersistentStorage());
  });

  tearDown(() {
    db.destroy(); // destroys the singleton
  });

  group('Database Listener Test', () {
    test('emits updated record when listener is active', () async {
      final task = defaultTask;
      final record = TaskRecord(task, TaskStatus.running, 0.0, 100);
      final listener = db.updates;
      final completer = Completer<TaskRecord>();
      listener.listen(completer.complete);
      db.updateRecord(record);
      final emittedRecord = await completer.future;
      expect(emittedRecord, equals(record));
    });

    test('emits multiple updated records when listener is active', () async {
      final task1 = defaultTask;
      final task2 = defaultTask.copyWith(taskId: 'task2');
      final record1 = TaskRecord(task1, TaskStatus.running, 0.0, 100);
      final record2 = TaskRecord(task2, TaskStatus.running, 0.0, 100);
      final listener = db.updates;
      var counter = 0;
      listener.listen((record) => counter++);
      await db.updateRecord(record1);
      await db.updateRecord(record2);
      await Future.delayed(const Duration(seconds: 1));
      expect(counter, equals(2));
    });

    test('two listeners receive the same TaskRecord', () async {
      final task = defaultTask;
      final record = TaskRecord(task, TaskStatus.running, 0.0, 100);
      final listener1 = db.updates;
      final listener2 = db.updates;
      final completer1 = Completer<TaskRecord>();
      final completer2 = Completer<TaskRecord>();
      listener1.listen(completer1.complete);
      listener2.listen(completer2.complete);
      await db.updateRecord(record);
      final emittedRecord1 = await completer1.future;
      final emittedRecord2 = await completer2.future;
      expect(emittedRecord1, equals(record));
      expect(emittedRecord2, equals(record));
    });
  });
}

class MockPersistentStorage implements PersistentStorage {
  @override
  Future<void> storeTaskRecord(TaskRecord record) {
    return Future.value();
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) {
    return Future.value(TaskRecord(defaultTask, TaskStatus.running, 0.0, 100));
  }

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() {
    return Future.value(
        [TaskRecord(defaultTask, TaskStatus.running, 0.0, 100)]);
  }

  @override
  Future<void> removeTaskRecord(String? taskId) {
    return Future.value();
  }

  @override
  // TODO: implement currentDatabaseVersion
  (String, int) get currentDatabaseVersion => throw UnimplementedError();

  @override
  Future<void> initialize() {
    // TODO: implement initialize
    throw UnimplementedError();
  }

  @override
  Future<void> removePausedTask(String? taskId) {
    // TODO: implement removePausedTask
    throw UnimplementedError();
  }

  @override
  Future<void> removeResumeData(String? taskId) {
    // TODO: implement removeResumeData
    throw UnimplementedError();
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() {
    // TODO: implement retrieveAllPausedTasks
    throw UnimplementedError();
  }

  @override
  Future<List<ResumeData>> retrieveAllResumeData() {
    // TODO: implement retrieveAllResumeData
    throw UnimplementedError();
  }

  @override
  Future<Task?> retrievePausedTask(String taskId) {
    // TODO: implement retrievePausedTask
    throw UnimplementedError();
  }

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) {
    // TODO: implement retrieveResumeData
    throw UnimplementedError();
  }

  @override
  Future<void> storePausedTask(Task task) {
    // TODO: implement storePausedTask
    throw UnimplementedError();
  }

  @override
  Future<void> storeResumeData(ResumeData resumeData) {
    // TODO: implement storeResumeData
    throw UnimplementedError();
  }

  @override
  // TODO: implement storedDatabaseVersion
  Future<(String, int)> get storedDatabaseVersion => throw UnimplementedError();
}
