import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader_example/sqlite_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/persistent_storage.dart';

const def = 'default';
const workingUrl = 'https://google.com';
const defaultFilename = 'google.html';
const tasksPath = LocalStorePersistentStorage.taskRecordsPath;
final task = DownloadTask(url: workingUrl, filename: defaultFilename);
final task2 = DownloadTask(url: workingUrl, filename: '$defaultFilename-2');
final record = TaskRecord(task, TaskStatus.running, 0.5, 1000);
final record2 = TaskRecord(task2, TaskStatus.enqueued, 0, 1000);

SqlitePersistentStorage db = SqlitePersistentStorage();

Database database = Database(db);

void main() {
  setUp(() async {
    WidgetsFlutterBinding.ensureInitialized();
    db = SqlitePersistentStorage();
    database = Database(db);
    await db.initialize();
  });

  tearDown(() async {
    await database.deleteAllRecords();
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
