// ignore: unused_import
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/persistent_storage.dart';
import 'package:logging/logging.dart';

// ignore: unused_import
import 'package:path/path.dart' as p;

// ignore: unused_import
import 'package:path_provider/path_provider.dart';

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
  try {
    setUp(() async {
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen((LogRecord rec) {
        debugPrint(
            '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
      });
      WidgetsFlutterBinding.ensureInitialized();
      // if you need to delete the database file, use the following, once
      // Do not leave it uncommented, as it generate an error SQLITE_READONLY_DBMOVED
      // final databasesPath = await (Platform.isIOS || Platform.isMacOS
      //     ? getLibraryDirectory()
      //     : getApplicationSupportDirectory());
      // final dbPath = p.join(databasesPath.path, 'background_downloader.sqlite');
      // try {
      //   File(dbPath).deleteSync();
      // } on FileSystemException {
      //   // ignore
      // }
      db = SqlitePersistentStorage();
      database = Database(db);
      await db.initialize();
    });
  } catch (e, s) {
    debugPrint('$e\n$s');
  }

  tearDown(() async {
    await database.deleteAllRecords();
  });

  group('TaskRecords via database', () {
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

    testWidgets('update record', (widgetTester) async {
      await database.updateRecord(record);
      final updatedRecord = record.copyWith(status: TaskStatus.failed);
      await database.updateRecord(updatedRecord);
      final r = await database.recordForId(record.taskId);
      expect(r, equals(updatedRecord));
    });
  });

  group('SQLitePersistentStorage direct', () {
    testWidgets('TaskRecord', (widgetTester) async {
      final sql = SqlitePersistentStorage();
      await sql.initialize();
      await sql.removeTaskRecord(null);
      expect(await sql.retrieveAllTaskRecords(), isEmpty);
      await sql.storeTaskRecord(record);
      await sql.storeTaskRecord(record2);
      expect(await sql.retrieveTaskRecord(record.taskId), equals(record));
      expect(await sql.retrieveTaskRecord(record2.taskId), equals(record2));
      expect(await sql.retrieveTaskRecord('unknown_id'), isNull);
      // try raw query
      expect(
          (await sql.retrieveTaskRecords(
                  'status = ?', [TaskStatus.running.index]))
              .first,
          equals(record));
      expect((await sql.retrieveTaskRecords('progress >= ?', [0])).length,
          equals(2));
      await sql.removeTaskRecord(null);
    });

    testWidgets('Other types', (widgetTester) async {
      final sql = SqlitePersistentStorage();
      await sql.initialize();
      // ModifiedTask
      await sql.removeModifiedTask(null);
      expect(await sql.retrieveAllModifiedTasks(), isEmpty);
      await sql.storeModifiedTask(task);
      expect(await sql.retrieveModifiedTask(task.taskId), equals(task));
      expect(await sql.retrieveModifiedTask(task2.taskId), isNull);
      await sql.removeModifiedTask(null);
      // PausedTask
      await sql.removePausedTask(null);
      expect(await sql.retrieveAllPausedTasks(), isEmpty);
      await sql.storePausedTask(task);
      expect(await sql.retrievePausedTask(task.taskId), equals(task));
      expect(await sql.retrievePausedTask(task2.taskId), isNull);
      await sql.removePausedTask(null);
      // ResumeData
      final resumeData = ResumeData(task, 'test', 100, 'tag');
      await sql.removeResumeData(null);
      expect(await sql.retrieveAllResumeData(), isEmpty);
      await sql.storeResumeData(resumeData);
      expect(await sql.retrieveResumeData(task.taskId), equals(resumeData));
      expect(await sql.retrieveResumeData(task2.taskId), isNull);
      await sql.removeResumeData(null);
    });

    testWidgets('purge old records', (widgetTester) async {
      final sql = SqlitePersistentStorage();
      await sql.initialize();
      // ModifiedTask
      await sql.removeModifiedTask(null);
      expect(await sql.retrieveAllModifiedTasks(), isEmpty);
      await sql.storeModifiedTask(task);
      expect(await sql.retrieveModifiedTask(task.taskId), equals(task));
      await sql.purgeOldRecords();
      expect(await sql.retrieveModifiedTask(task.taskId), equals(task));
      await sql.purgeOldRecords(age: const Duration(seconds: -10));
      expect(await sql.retrieveModifiedTask(task.taskId), isNull);
    });
  });
}
