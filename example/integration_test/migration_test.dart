import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_downloader/flutter_downloader.dart' hide DownloadTask;
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/persistent_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:background_downloader/src/sqlite_storage.dart';

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
      debugPrint(
          '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    });
    WidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() async {});

  group('Migrations', () {
    testWidgets('migrate from LocalStore', (widgetTester) async {
      final store = LocalStorePersistentStorage();
      await store.initialize();
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
      expect((await sql.retrieveAllResumeData()).first.taskId,
          equals(task.taskId));
      expect((await sql.retrieveAllTaskRecords()).first.taskId,
          equals(task.taskId));
      // and expect original data is gone
      final store2 =
          LocalStorePersistentStorage(); // new to prevent cached values
      expect(await store2.retrieveAllModifiedTasks(), isEmpty);
      expect(await store2.retrieveAllPausedTasks(), isEmpty);
      expect(await store2.retrieveAllResumeData(), isEmpty);
      expect(await store2.retrieveAllTaskRecords(), isEmpty);
      // clean up
      await (sql.db.close());
      await File(sql.db.path).delete();
      debugPrint('Finished migrate from LocalStore');
    });

    testWidgets('migrate from Flutter Downloader', (widgetTester) async {
      final fdl = Platform.isAndroid
          ? FlutterDownloaderPersistentStorageAndroid()
          : FlutterDownloaderPersistentStorageIOS();
      final dbPath = await fdl.getDatabasePath();
      if (File(dbPath).existsSync()) {
        await File(dbPath).delete();
      }
      await FlutterDownloader.initialize(debug: true);
      FlutterDownloader.registerCallback(downloadCallback);
      final docsDir = await getApplicationDocumentsDirectory();
      final destPath = path.join(docsDir.path, defaultFilename);
      if (File(destPath).existsSync()) {
        File(destPath).deleteSync();
      }
      final fdlTaskId = await FlutterDownloader.enqueue(
          url: workingUrl,
          fileName: defaultFilename,
          headers: {'key': 'value'},
          savedDir: docsDir.path,
          showNotification: false,
          openFileFromNotification: false);
      await Future.delayed(const Duration(seconds: 2));
      expect(File(destPath).existsSync(), isTrue);
      expect(File(dbPath).existsSync(), isTrue);
      debugPrint('Loaded file, file exists, database exists');
      final fdlTask = (await FlutterDownloader.loadTasks())!.first;
      expect(fdlTask.taskId, equals(fdlTaskId));
      debugPrint(
          'FDL SQLite database contains the task with status ${fdlTask.status}');
      // delete sql database
      final tempSql = SqlitePersistentStorage();
      await tempSql.initialize();
      await tempSql.db.close();
      await File(tempSql.db.path).delete();
      // now migrate
      final sql =
          SqlitePersistentStorage(migrationOptions: ['flutter_downloader']);
      await sql.initialize();
      // after migration, expect data is in sql storage
      expect(await sql.retrieveAllModifiedTasks(), isEmpty);
      expect(await sql.retrieveAllPausedTasks(), isEmpty);
      expect(await sql.retrieveAllResumeData(), isEmpty);
      final newRecord = (await sql.retrieveAllTaskRecords()).first;
      expect(newRecord.taskId, equals(fdlTaskId));
      expect(newRecord.task.url, equals(workingUrl));
      expect(newRecord.task.filename, equals(defaultFilename));
      expect(newRecord.task.headers, equals({'key': 'value'}));
      expect(
          newRecord.task.creationTime
              .difference(DateTime.now())
              .inSeconds
              .abs(),
          lessThan(5));
      expect(newRecord.status, equals(TaskStatus.complete));
      expect(newRecord.progress, equals(1.0));
      expect(newRecord.expectedFileSize, equals(-1));
      final task = newRecord.task;
      expect(task.taskId, equals(fdlTaskId));
      expect(task.filename, equals(fdlTask.filename));
      final filePath = await task.filePath();
      expect(File(filePath).existsSync(), isTrue);
      expect(filePath, equals(destPath));
      // and expect original data is gone
      expect(File(dbPath).existsSync(), isFalse);
      // clean up
      await (sql.db.close());
      await File(sql.db.path).delete();
      debugPrint('Finished migrate from Flutter Downloader');
    });

    testWidgets('migration not possible', (widgetTester) async {
      // delete LocalStore database
      final store = LocalStorePersistentStorage();
      await store.initialize();
      await store.removeModifiedTask(null);
      await store.removePausedTask(null);
      await store.removeResumeData(null);
      await store.removeTaskRecord(null);
      // delete Flutter Downloader database
      final fdl = Platform.isAndroid
          ? FlutterDownloaderPersistentStorageAndroid()
          : FlutterDownloaderPersistentStorageIOS();
      final dbPath = await fdl.getDatabasePath();
      if (File(dbPath).existsSync()) {
        await File(dbPath).delete();
      }
      // now attempt to migrate
      final sql = SqlitePersistentStorage(
          migrationOptions: ['local_store', 'flutter_downloader']);
      await sql.initialize();
      // after migration, expect no data is in sql storage
      expect(await sql.retrieveAllModifiedTasks(), isEmpty);
      expect(await sql.retrieveAllPausedTasks(), isEmpty);
      expect(await sql.retrieveAllResumeData(), isEmpty);
      expect(await sql.retrieveAllTaskRecords(), isEmpty);
      // clean up
      await (sql.db.close());
      await File(sql.db.path).delete();
      debugPrint('Finished migration not possible');
    });
  });
}

/// FlutterDownloader downloadCallBack (dummy)
@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {}
