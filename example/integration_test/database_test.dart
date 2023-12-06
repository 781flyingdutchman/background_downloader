import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:background_downloader/src/localstore/localstore.dart';

const def = 'default';
const workingUrl = 'https://google.com';
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
}
