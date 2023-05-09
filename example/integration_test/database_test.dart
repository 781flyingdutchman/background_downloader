import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localstore/localstore.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const def = 'default';
const workingUrl = 'https://google.com';
const defaultFilename = 'google.html';
const tasksPath = Database.tasksPath;
final task = DownloadTask(url: workingUrl, filename: defaultFilename);
final task2 = DownloadTask(url: workingUrl, filename: '$defaultFilename-2');
final record = TaskRecord(task, TaskStatus.running, 0.5);
final record2 = TaskRecord(task2, TaskStatus.enqueued, 0);

final db = Localstore.instance;

void main() {
  setUp(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Database().deleteAllRecords();
  });

  tearDown(() async {
    await Database().deleteAllRecords();
  });

  testWidgets('updateRecord', (tester) async {
    await Database().updateRecord(record);
    final records = await db.collection(tasksPath).get();
    expect(records?.values.length, equals(1));
    final storedRecordJsonMap = records?.values.first;
    expect(storedRecordJsonMap, isNotNull);
    final storedRecord = TaskRecord.fromJsonMap(storedRecordJsonMap);
    expect(storedRecord, equals(record));
    await Database().updateRecord(record2);
    final records2 = await db.collection(tasksPath).get();
    expect(records2?.values.length, equals(2));
    // confirm file exists in file system
    await Future.delayed(const Duration(milliseconds: 200));
    final docDir = await getApplicationDocumentsDirectory();
    final filePath = '$tasksPath/${record.taskId}';
    expect(File(path.join(docDir.path, filePath)).existsSync(), isTrue);
  });

  testWidgets('allRecords', (widgetTester) async {
    await Database().updateRecord(record);
    await Database().updateRecord(record2);
    final result = await Database().allRecords();
    expect(result.length, equals(2));
    if (result.first == record) {
      expect(result.last, equals(record2));
    } else {
      expect(result.first, equals(record2));
      expect(result.last, equals(record));
    }
    // add a record in a different group
    final task2 = DownloadTask(url: 'something', group: 'newGroup');
    final record3 = TaskRecord(task2, TaskStatus.running, 0.2);
    await Database().updateRecord(record3);
    final result2 = await Database().allRecords();
    expect(result2.length, equals(3));
    await Database().updateRecord(record2);
    final result3 = await Database().allRecords(group: 'newGroup');
    expect(result3.length, equals(1));
    expect(result3.first, equals(record3));
  });

  testWidgets('recordForId', (widgetTester) async {
    await Database().updateRecord(record);
    await Database().updateRecord(record2);
    final r = await Database().recordForId(record.taskId);
    expect(r, equals(record));
    final r2 = await Database().recordForId(record2.taskId);
    expect(r2, equals(record2));
    // unknown taskId or group
    final r3 = await Database().recordForId('unknown');
    expect(r3, isNull);
  });

  testWidgets('deleteRecords', (widgetTester) async {
    await Database().updateRecord(record);
    await Database().updateRecord(record2);
    final r = await Database().recordForId(record.taskId);
    expect(r, equals(record));
    final r2 = await Database().recordForId(record2.taskId);
    expect(r2, equals(record2));
    await Database().deleteAllRecords();
    // this brief delay should not be necessary, see issue #24 in localstore
    await Future.delayed(const Duration(milliseconds: 100));
    // should be gone
    final r3 = await Database().recordForId(record.taskId);
    expect(r3, isNull);
    final r4 = await Database().recordForId(record2.taskId);
    expect(r4, isNull);
  });

  testWidgets('deleteRecordsWithIds', (widgetTester) async {
    await Database().updateRecord(record);
    await Database().updateRecord(record2);
    await Database().deleteRecordWithId(record.taskId);
    final r = await Database().recordForId(record.taskId);
    expect(r, isNull);
    final r2 = await Database().recordForId(record2.taskId);
    expect(r2, equals(record2));
  });
}
