import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:background_downloader/src/localstore/localstore.dart';
import 'test_utils.dart';

const def = 'default';
final workingUrl = urlWithoutContentLength;
const defaultFilename = 'google.html';
const tasksPath = LocalStorePersistentStorage.taskRecordsPath;
final task = DownloadTask(url: workingUrl, filename: defaultFilename);
final task2 = DownloadTask(url: workingUrl, filename: '$defaultFilename-2');
final record = TaskRecord(task, TaskStatus.running, 0.5, 1000);
final record2 = TaskRecord(task2, TaskStatus.enqueued, 0, 1000);

final db = LocalStorePersistentStorage();

final database = Database(db);

Future<void> deleteAllTaskDataFromFileSystem() async {
  final docDirTasksDir =
      path.join((await getApplicationDocumentsDirectory()).path, tasksPath);
  final supportDirTasksDir =
      path.join((await getApplicationSupportDirectory()).path, tasksPath);
  try {
    await Directory(docDirTasksDir).delete(recursive: true);
  } catch (e) {
    debugPrint(e.toString());
  }
  try {
    await Directory(supportDirTasksDir).delete(recursive: true);
  } catch (e) {
    debugPrint(e.toString());
  }
}

void main() {
  setUp(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      debugPrint(
          '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    });
    WidgetsFlutterBinding.ensureInitialized();
    await deleteAllTaskDataFromFileSystem();
    Localstore.instance.clearCache();
  });

  tearDown(() async {
    await deleteAllTaskDataFromFileSystem();
    Localstore.instance.clearCache();
  });

  testWidgets('updateRecord', (tester) async {
    await database.updateRecord(record);
    final records = await db.retrieveAll(tasksPath);
    expect(records.values.length, equals(1));
    final storedRecordJsonMap = records.values.first;
    expect(storedRecordJsonMap, isNotNull);
    final storedRecord = TaskRecord.fromJson(storedRecordJsonMap);
    expect(storedRecord, equals(record));
    await database.updateRecord(record2);
    final records2 = await db.retrieveAll(tasksPath);
    expect(records2.values.length, equals(2));
    // confirm file exists in file system
    await Future.delayed(const Duration(milliseconds: 200));
    final docDir = await getApplicationSupportDirectory();
    final filePath = '$tasksPath/${record.taskId}';
    expect(File(path.join(docDir.path, filePath)).existsSync(), isTrue);
  });

  testWidgets('allRecords', (widgetTester) async {
    await database.updateRecord(record);
    await database.updateRecord(record2);
    final result = await database.allRecords();
    expect(result.length, equals(2));
    if (result.first == record) {
      expect(result.last, equals(record2));
    } else {
      expect(result.first, equals(record2));
      expect(result.last, equals(record));
    }
    // add a record in a different group
    final task2 = DownloadTask(url: 'something', group: 'newGroup');
    final record3 = TaskRecord(task2, TaskStatus.running, 0.2, 1000);
    await database.updateRecord(record3);
    final result2 = await database.allRecords();
    expect(result2.length, equals(3));
    await database.updateRecord(record2);
    final result3 = await database.allRecords(group: 'newGroup');
    expect(result3.length, equals(1));
    expect(result3.first, equals(record3));
  });

  testWidgets('recordForId', (widgetTester) async {
    await database.updateRecord(record);
    await database.updateRecord(record2);
    final r = await database.recordForId(record.taskId);
    expect(r, equals(record));
    final r2 = await database.recordForId(record2.taskId);
    expect(r2, equals(record2));
    // unknown taskId or group
    final r3 = await database.recordForId('unknown');
    expect(r3, isNull);
  });

  testWidgets('deleteRecords', (widgetTester) async {
    await database.updateRecord(record);
    await database.updateRecord(record2);
    final r = await database.recordForId(record.taskId);
    expect(r, equals(record));
    final r2 = await database.recordForId(record2.taskId);
    expect(r2, equals(record2));
    await database.deleteAllRecords();
    // this brief delay should not be necessary, see issue #24 in localstore
    await Future.delayed(const Duration(milliseconds: 100));
    // should be gone
    final r3 = await database.recordForId(record.taskId);
    expect(r3, isNull);
    final r4 = await database.recordForId(record2.taskId);
    expect(r4, isNull);
  });

  testWidgets('deleteRecordsWithIds', (widgetTester) async {
    await database.updateRecord(record);
    await database.updateRecord(record2);
    await database.deleteRecordWithId(record.taskId);
    final r = await database.recordForId(record.taskId);
    expect(r, isNull);
    final r2 = await database.recordForId(record2.taskId);
    expect(r2, equals(record2));
  });

  test('rescheduleMissingTasks', () async {
    expect(await FileDownloader().allTasks(), isEmpty);
    // without task tracking activated, throws assertionError
    expect(() async => await FileDownloader().rescheduleKilledTasks(),
        throwsAssertionError);
    await FileDownloader().trackTasks();
    // test empty
    final result = await FileDownloader().rescheduleKilledTasks();
    expect(result.$1, isEmpty);
    expect(result.$2, isEmpty);
    // add a record to the database that is not enqueued
    await FileDownloader().database.updateRecord(record);
    final result2 = await FileDownloader().rescheduleKilledTasks();
    expect(result2.$1.length, equals(1));
    expect(result2.$2, isEmpty);
    expect(result2.$1.first.taskId, equals(task.taskId));
    final allTasks = await FileDownloader().allTasks();
    expect(allTasks.first.taskId, equals(task.taskId));
    await Future.delayed(const Duration(seconds: 2));
    expect(await FileDownloader().allTasks(), isEmpty);
    // add a record to the database that is also enqueued
    expect(await FileDownloader().enqueue(task2), isTrue);
    expect(await FileDownloader().database.allRecords(), isNotEmpty);
    final result3 = await FileDownloader().rescheduleKilledTasks();
    expect(result3.$1, isEmpty);
    expect(result3.$2, isEmpty);
  });

  testWidgets('cleanUp', (widgetTester) async {
    // defaults
    database.cleanUp();
    // we need to access private vars to verify, but since we can't, we verify behavior
    // add many records (more than 500)
    for (int i = 0; i < 600; i++) {
      final t = DownloadTask(
          url: 'url',
          filename: 'f$i',
          taskId: 'id$i',
          creationTime: DateTime.now());
      final r = TaskRecord(t, TaskStatus.running, 0.5, 1000);
      await database.updateRecord(r);
    }
    expect((await database.allRecords()).length, 600);
    await Future.delayed(const Duration(seconds: 1));
    // force cleanup
    database.cleanUp();
    await Future.delayed(const Duration(seconds: 25));
    expect((await database.allRecords()).length, 500);

    // Attempt with small numbers for test speed
    await database.deleteAllRecords();
    for (int i = 0; i < 10; i++) {
      final t = DownloadTask(
          url: 'url',
          filename: 'f$i',
          taskId: 'id$i',
          creationTime: DateTime.now().subtract(Duration(days: i)));
      final r = TaskRecord(t, TaskStatus.running, 0.5, 1000);
      await database.updateRecord(r);
    }
    // Now we have 10 records, ages 0 to 9 days.
    // Clean up older than 5 days.
    database.cleanUp(maxAge: const Duration(days: 5), maxRecordCount: 100);
    // records 6, 7, 8, 9 days old should be removed (4 records)
    // 4 * 200ms = 800ms
    await Future.delayed(const Duration(seconds: 2));
    final records = await database.allRecords();
    expect(records.length, equals(5));

    // Clean up by count
    database.cleanUp(maxRecordCount: 3);
    // should remove 3 oldest records
    // 3 * 200ms = 600ms
    await Future.delayed(const Duration(seconds: 2));
    final records2 = await database.allRecords();
    expect(records2.length, equals(3));
    await database.deleteAllRecords();
  });

  testWidgets('autoClean', (widgetTester) async {
    await database.deleteAllRecords();
    database.cleanUp(autoClean: true, maxRecordCount: 5);
    // update 100 times
    for (int i = 0; i < 110; i++) {
      final t = DownloadTask(
          url: 'url',
          filename: 'f$i',
          taskId: 'id$i',
          creationTime: DateTime.now());
      final r = TaskRecord(t, TaskStatus.running, 0.5, 1000);
      await database.updateRecord(r);
    }
    // Triggered at 100. Should reduce to 5.
    // 100 * 200ms = 20 seconds... this is too slow for tests if we delete many.
    // But we process locally.
    // Wait a bit
    await Future.delayed(
        const Duration(seconds: 30)); // Give it plenty of time?
    // Actually, since we add 1 by 1, the count grows.
    // At 100th update, we have 100 records.
    // We want to keep 5. So we delete 95.
    // 95 * 0.2s = 19 seconds.
    final records = await database.allRecords();
    expect(records.length, equals(5)); // 5 kept
    await database.deleteAllRecords();
  });
}
