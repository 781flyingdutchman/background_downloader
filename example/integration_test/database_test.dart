import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/database.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

const def = 'default';
const workingUrl = 'https://google.com';
const defaultFilename = 'google.html';
const tasksPath = Database.tasksPath;
final task = DownloadTask(url: workingUrl, filename: defaultFilename);
final task2 = DownloadTask(url: workingUrl, filename: '$defaultFilename-2');
final record = TaskRecord(task, TaskStatus.running, 0.5);
final record2 = TaskRecord(task2, TaskStatus.enqueued, 0);

void main() {

  setUp(() async {
    WidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('updateRecord', (tester) async {
    await Database().updateRecord(record);
    final records = await Database().db.collection(tasksPath).get();
    expect(records?.values.length, equals(1));
    final storedRecordJsonMap = records?.values.first;
    expect(storedRecordJsonMap, isNotNull);
    final storedRecord = TaskRecord.fromJsonMap(storedRecordJsonMap);
    expect(storedRecord, equals(record));
    await Database().updateRecord(record2);
    final records2 = await Database().db.collection(tasksPath).get();
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
    final records = await Database().allRecords(def);
    expect(records.length, equals(2));
    if (records.first == record) {
      expect(records.last, equals(record2));
    } else {
      expect(records.first, equals(record2));
      expect(records.last, equals(record));
    }
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
    await Database().deleteRecords();
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