import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/persistent_storage.dart';
import 'package:logging/logging.dart';

const def = 'default';
const workingUrl = 'https://google.com';
const defaultFilename = 'google.html';
final task = DownloadTask(url: workingUrl, filename: defaultFilename);
final task2 = DownloadTask(url: workingUrl, filename: '$defaultFilename-2');
final resumeData = ResumeData(task, 'data', 100);
final record = TaskRecord(task, TaskStatus.running, 0.5, 1000);


void main() {
  setUp(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      debugPrint('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    });
    WidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() async {

  });


  group('Migrations', () {
    testWidgets('migrate from LocalStore', (widgetTester) async {
      final store = LocalStorePersistentStorage();
      await store.removeModifiedTask(null);
      await store.removePausedTask(null);
      await store.removeResumeData(null);
      await store.removeTaskRecord(null);
      expect(await store.retrieveAllModifiedTasks(), isEmpty);
      expect(await store.retrieveAllPausedTasks(), isEmpty);
      expect(await store.retrieveAllResumeData(), isEmpty);
      expect(await store.retrieveAllTaskRecords(), isEmpty);
      await store.storeModifiedTask(task);
      await store.storePausedTask(task2);
      await store.storeResumeData(resumeData);
      await store.storeTaskRecord(record);
      // delete sql database
      final tempSql = SqlitePersistentStorage();
      await tempSql.initialize();
      await tempSql.db.close();
      await File(tempSql.db.path).delete();
      // now migrate
      final sql = SqlitePersistentStorage(migrationOptions: ['local_store']);
      await sql.initialize();
      // after migration, expect data is in sql storage
      expect((await sql.retrieveAllModifiedTasks()).first, equals(task));
      expect((await sql.retrieveAllPausedTasks()).first, equals(task2));
      expect((await sql.retrieveAllResumeData()).first.taskId, equals(task.taskId));
      expect((await sql.retrieveAllTaskRecords()).first.taskId, equals(task.taskId));
      // and expect original data is gone
      final store2 = LocalStorePersistentStorage(); // new to prevent cached values
      expect(await store2.retrieveAllModifiedTasks(), isEmpty);
      expect(await store2.retrieveAllPausedTasks(), isEmpty);
      expect(await store2.retrieveAllResumeData(), isEmpty);
      expect(await store2.retrieveAllTaskRecords(), isEmpty);
      await (sql.db.close());
      await File(sql.db.path).delete();
      debugPrint('Finished migrate from LocalStore');
    });
  });

}
