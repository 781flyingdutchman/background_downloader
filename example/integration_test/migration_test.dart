import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/cupertino.dart';

// import 'package:flutter_downloader/flutter_downloader.dart' hide DownloadTask;
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
final resumeData = ResumeData(task, 'data', 100, 'tag');
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

    // test 'migrate from Flutter Downloader' requires the flutter_downloader package and
    // this causes issues on iOS, so we have commented out all references to this here,
    // and in the example app's pubspec.yaml

    testWidgets('migrate from FDL with docsDir', (widgetTester) async {
      final dir = await getApplicationDocumentsDirectory();
      await _migrateWithDir(dir);
      debugPrint('Finished migrate from Flutter Downloader');
    });

    testWidgets('migrate from FDL with tempDir', (widgetTester) async {
      final dir = await getTemporaryDirectory();
      await _migrateWithDir(dir);
      debugPrint('Finished migrate from Flutter Downloader');
    });

    testWidgets('migrate from FDL with SupportDir', (widgetTester) async {
      final dir = await getApplicationSupportDirectory();
      await _migrateWithDir(dir);
      debugPrint('Finished migrate from Flutter Downloader');
    });

    testWidgets('migrate from FDL with LibraryDir', (widgetTester) async {
      final dir = Platform.isIOS
          ? await getLibraryDirectory()
          : Directory(path.join(
              (await getApplicationSupportDirectory()).path, 'Library'));
      await _migrateWithDir(dir);
      debugPrint('Finished migrate from Flutter Downloader');
    });

    testWidgets('migrate from FDL with tempDir and subdir',
        (widgetTester) async {
      final dir = await getTemporaryDirectory();
      final subdir = Directory(path.join(dir.path, 'downloads'));
      if (!subdir.existsSync()) {
        subdir.createSync(recursive: true);
      }
      await _migrateWithDir(subdir);
      subdir.deleteSync(recursive: true);
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

  group('Unit tests', () {
    testWidgets('directories test', (widgetTester) async {
      final fdl = Platform.isAndroid
          ? FlutterDownloaderPersistentStorageAndroid()
          : FlutterDownloaderPersistentStorageIOS();
      await fdl.initialize();
      final docDir = await getApplicationDocumentsDirectory();
      var testPath = docDir.path;
      _testDirs(fdl, testPath, BaseDirectory.applicationDocuments, '');
      _testDirs(
          fdl, '$testPath/myDir', BaseDirectory.applicationDocuments, 'myDir');
      _testDirs(
          fdl, '$testPath/myDir/', BaseDirectory.applicationDocuments, 'myDir');
      _testDirs(fdl, '$testPath/myDir/subDir',
          BaseDirectory.applicationDocuments, 'myDir/subDir');
      final tempDir = await getTemporaryDirectory();
      testPath = tempDir.path;
      _testDirs(fdl, testPath, BaseDirectory.temporary, '');
      _testDirs(fdl, '$testPath/myDir', BaseDirectory.temporary, 'myDir');
      _testDirs(fdl, '$testPath/myDir/', BaseDirectory.temporary, 'myDir');
      _testDirs(fdl, '$testPath/myDir/subDir', BaseDirectory.temporary,
          'myDir/subDir');
      final supportDir = await getApplicationSupportDirectory();
      testPath = supportDir.path;
      _testDirs(fdl, testPath, BaseDirectory.applicationSupport, '');
      _testDirs(
          fdl, '$testPath/myDir', BaseDirectory.applicationSupport, 'myDir');
      _testDirs(
          fdl, '$testPath/myDir/', BaseDirectory.applicationSupport, 'myDir');
      _testDirs(fdl, '$testPath/myDir/subDir', BaseDirectory.applicationSupport,
          'myDir/subDir');
      final libraryDir = Platform.isIOS
          ? await getLibraryDirectory()
          : Directory(path.join(supportDir.path, 'Library'));
      testPath = libraryDir.path;
      _testDirs(fdl, testPath, BaseDirectory.applicationLibrary, '');
      _testDirs(
          fdl, '$testPath/myDir', BaseDirectory.applicationLibrary, 'myDir');
      _testDirs(
          fdl, '$testPath/myDir/', BaseDirectory.applicationLibrary, 'myDir');
      _testDirs(fdl, '$testPath/myDir/subDir', BaseDirectory.applicationLibrary,
          'myDir/subDir');
    });

    testWidgets('directory that does not match', (widgetTester) async {
      final fdl = Platform.isAndroid
          ? FlutterDownloaderPersistentStorageAndroid()
          : FlutterDownloaderPersistentStorageIOS();
      await fdl.initialize();
      var testPath = '/path/that/does/not/match';
      _testDirs(fdl, testPath, BaseDirectory.applicationDocuments, null);
    });

    testWidgets('iOS directory that matches prior Application identifier',
        (widgetTester) async {
      if (Platform.isIOS) {
        final fdl = FlutterDownloaderPersistentStorageIOS();
        await fdl.initialize();
        for (final (testDir, expectedBaseDir) in [
          (
            await getApplicationDocumentsDirectory(),
            BaseDirectory.applicationDocuments
          ),
          (await getTemporaryDirectory(), BaseDirectory.temporary),
          (
            await getApplicationSupportDirectory(),
            BaseDirectory.applicationSupport
          ),
          (await getLibraryDirectory(), BaseDirectory.applicationLibrary),
        ]) {
          _testAppIdentifierReplacement(testDir, fdl, expectedBaseDir);
        }
      }
    });

    testWidgets('iOS directory that is a subdir of docsDir',
        (widgetTester) async {
      if (Platform.isIOS) {
        final fdl = FlutterDownloaderPersistentStorageIOS();
        await fdl.initialize();
        _testDirs(fdl, 'subdir/something', BaseDirectory.applicationDocuments,
            'subdir/something');
        _testDirs(
            fdl, '/subdir/something', BaseDirectory.applicationDocuments, null);
      }
    });
  });
}

void _testAppIdentifierReplacement(Directory testDir,
    FlutterDownloaderPersistentStorage fdl, BaseDirectory expectedBaseDir) {
  final currentAppIdentifierMatch =
      RegExp('Application/(.*?)/').firstMatch(testDir.path);
  expect(currentAppIdentifierMatch, isNotNull);
  if (currentAppIdentifierMatch != null) {
    // replace the savedDirAppIdentifier with the current one and try again
    final testPath =
        '${testDir.path.replaceRange(currentAppIdentifierMatch.start, currentAppIdentifierMatch.end, 'Application/another-identifier/')}/subdir';
    _testDirs(fdl, testPath, expectedBaseDir, 'subdir');
  }
}

Future<void> _testDirs(FlutterDownloaderPersistentStorage fdl, String testPath,
    BaseDirectory expectedBaseDir, String? expectedDir) async {
  var (baseDir, dir) = await fdl.getDirectories(testPath);
  debugPrint('$testPath: $baseDir, $dir');
  expect(baseDir, equals(expectedBaseDir));
  expect(dir, equals(expectedDir));
}

Future<void> _migrateWithDir(Directory dir) async {
  debugPrint(
      'Skipping _migrateWithDir test, as FDL is not imported and uncommented');
  // final fdl = Platform.isAndroid
  //     ? FlutterDownloaderPersistentStorageAndroid()
  //     : FlutterDownloaderPersistentStorageIOS();
  // final dbPath = await fdl.getDatabasePath();
  // if (File(dbPath).existsSync()) {
  //   await File(dbPath).delete();
  // }
  // await FlutterDownloader.initialize(debug: true);
  // FlutterDownloader.registerCallback(downloadCallback);
  // debugPrint('Testing migration from directory $dir');
  // final destPath = path.join(dir.path, defaultFilename);
  // if (File(destPath).existsSync()) {
  //   File(destPath).deleteSync();
  // }
  // final fdlTaskId = await FlutterDownloader.enqueue(
  //     url: workingUrl,
  //     fileName: defaultFilename,
  //     headers: {'key': 'value'},
  //     savedDir: dir.path,
  //     showNotification: false,
  //     openFileFromNotification: false);
  // await Future.delayed(const Duration(seconds: 2));
  // expect(File(destPath).existsSync(), isTrue);
  // expect(File(dbPath).existsSync(), isTrue);
  // debugPrint('Loaded file, file exists, database exists');
  // final fdlTask = (await FlutterDownloader.loadTasks())!.first;
  // expect(fdlTask.taskId, equals(fdlTaskId));
  // debugPrint(
  //     'FDL SQLite database contains the task with status ${fdlTask.status}');
  // // delete sql database
  // final tempSql = SqlitePersistentStorage();
  // await tempSql.initialize();
  // await tempSql.db.close();
  // await File(tempSql.db.path).delete();
  // // now migrate
  // final sql = SqlitePersistentStorage(migrationOptions: ['flutter_downloader']);
  // await sql.initialize();
  // // after migration, expect data is in sql storage
  // expect(await sql.retrieveAllModifiedTasks(), isEmpty);
  // expect(await sql.retrieveAllPausedTasks(), isEmpty);
  // expect(await sql.retrieveAllResumeData(), isEmpty);
  // final newRecord = (await sql.retrieveAllTaskRecords()).first;
  // expect(newRecord.taskId, equals(fdlTaskId));
  // expect(newRecord.task.url, equals(workingUrl));
  // expect(newRecord.task.filename, equals(defaultFilename));
  // expect(newRecord.task.headers, equals({'key': 'value'}));
  // expect(newRecord.task.creationTime.difference(DateTime.now()).inSeconds.abs(),
  //     lessThan(5));
  // expect(newRecord.status, equals(TaskStatus.complete));
  // expect(newRecord.progress, equals(1.0));
  // expect(newRecord.expectedFileSize, equals(-1));
  // final task = newRecord.task;
  // expect(task.taskId, equals(fdlTaskId));
  // expect(task.filename, equals(fdlTask.filename));
  // final filePath = await task.filePath();
  // expect(filePath, equals(destPath));
  // expect(File(filePath).existsSync(), isTrue);
  // // and expect original data is gone
  // expect(File(dbPath).existsSync(), isFalse);
  // // clean up
  // await (sql.db.close());
  // await File(sql.db.path).delete();
}

/// FlutterDownloader downloadCallBack (dummy)
@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {}
