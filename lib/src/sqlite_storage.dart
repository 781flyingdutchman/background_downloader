import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart' as sql;

import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'models.dart';
import 'persistent_storage.dart';

class SqlitePersistentStorage implements PersistentStorage {
  final log = Logger('SqlitePersistentStorage');
  final List<String> migrationList;
  late final sql.Database db;

  final taskRecordsTable = 'taskRecords';
  final modifiedTasksTable = 'modifiedTasksTable';
  final pausedTasksTable = 'pausedTasksTable';
  final resumeDataTable = 'resumeDataTable';

  final taskIdColumn = 'taskId';
  final objectColumn = 'objectJsonMap';

  /// Create [SqlitePersistentStorage] object with optional list of database
  /// backends to migrate from
  /// 
  /// Currently supported databases we can migrate from are:
  /// * local_store (the default implementation of the database in 
  ///   background_downloader). Migration from local_store to
  ///   [SqlitePersistentStorage] is complete, i.e. all state is transferred.
  /// * flutter_downloader (a popular but now deprecated package for
  ///   downloading files). Migration from flutter_downloader is partial: only
  ///   tasks that were complete, failed or canceled are transferred, and
  ///   if the location of a file cannot be determined as a combination of
  ///   [BaseDirectory] and [directory] then the task's baseDirectory field
  ///   will be set to [BaseDirectory.applicationDocuments] and its
  ///   directory field will be set to the 'savedDir' field of the database
  ///   used by flutter_downloader. You will have to determine what that 
  ///   directory resolves to (likely an external directory on Android)
  SqlitePersistentStorage([List<String>? migrateFrom])
      : migrationList = migrateFrom ?? [];

  @override
  (String, int) get currentDatabaseVersion => ('Sqlite', 1);

  @override
  Future<void> initialize() async {
    final databasesPath = await (Platform.isIOS || Platform.isMacOS
        ? getLibraryDirectory()
        : getApplicationSupportDirectory());
    final path = join(databasesPath.path, 'background_downloader.sqlite');

    db = await sql.openDatabase(path, version: 1,
        onCreate: (sql.Database dbase, int version) async {
      // When creating the db, create the table
      await dbase.execute(
          'CREATE TABLE $taskRecordsTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT)');
      await dbase.execute(
          'CREATE TABLE $pausedTasksTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT)');
      await dbase.execute(
          'CREATE TABLE $modifiedTasksTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT)');
      await dbase.execute(
          'CREATE TABLE $resumeDataTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT)');
      // upon first creation, do database migrations
      for (var persistentStorageName in migrationList) {
        if (await _migrateFrom(persistentStorageName)) {
          break;
        }
      }
    });
  }

  /// Attempt to migrate data from [persistentStorageName] to our database
  ///
  /// Returns true if the migration was successfully executed, false if it
  /// was not a viable migration
  Future<bool> _migrateFrom(String persistentStorageName) =>
      switch (persistentStorageName.toLowerCase()) {
        'localstore' || 'local_store' => _migrateFromLocalStore(),
        'flutterdownloader' ||
        'flutter_downloader' =>
          _migrateFromFlutterDownloader(),
        _ => Future.value(false)
      };

  /// Migrate from a persistent storage to our database
  ///
  /// Returns true if this migration took place
  Future<bool> _migrateFromPersistentStorage(PersistentStorage storage) async {
    bool migratedSomething = false;
    await storage.initialize();
    for (final pausedTask in await storage.retrieveAllPausedTasks()) {
      await storePausedTask(pausedTask);
      migratedSomething = true;
    }
    for (final modifiedTask in await storage.retrieveAllModifiedTasks()) {
      await storeModifiedTask(modifiedTask);
      migratedSomething = true;
    }
    for (final resumeData in await storage.retrieveAllResumeData()) {
      await storeResumeData(resumeData);
      migratedSomething = true;
    }
    for (final taskRecord in await storage.retrieveAllTaskRecords()) {
      await storeTaskRecord(taskRecord);
      migratedSomething = true;
    }
    return migratedSomething;
  }

  /// Attempt to migrate from [LocalStorePersistentStorage]
  Future<bool> _migrateFromLocalStore() async {
    final localStore = LocalStorePersistentStorage();
    if (await _migrateFromPersistentStorage(localStore)) {
      // delete all paths related to LocalStore
      final supportDir = await getApplicationSupportDirectory();
      for (String collectionPath in [
        LocalStorePersistentStorage.resumeDataPath,
        LocalStorePersistentStorage.pausedTasksPath,
        LocalStorePersistentStorage.modifiedTasksPath,
        LocalStorePersistentStorage.taskRecordsPath,
        LocalStorePersistentStorage.metaDataCollection
      ]) {
        try {
          final path = join(supportDir.path, collectionPath);
          if (await Directory(path).exists()) {
            log.finest('Removing directory $path for LocalStore');
            await Directory(path).delete(recursive: true);
          }
        } catch (e) {
          log.fine('Error deleting collection path $collectionPath: $e');
        }
      }
      return true; // we migrated a database
    }
    return false; // we did not migrate a database
  }

  /// Attempt to migrate from FlutterDownloader
  Future<bool> _migrateFromFlutterDownloader() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return false;
    }
    final fdl = Platform.isAndroid
        ? _FlutterDownloaderPersistentStorageAndroid()
        : _FlutterDownloaderPersistentStorageIOS();
    if (await _migrateFromPersistentStorage(fdl)) {
      await fdl.removeDatabase();
      return true; // we migrated a database
    }
    return false; // we did not migrate a database
  }

  Future<void> remove(String table, String? taskId) async {
    if (taskId == null) {
      await db.delete(table, where: null);
    } else {
      await db.delete(table, where: '$taskIdColumn = ?', whereArgs: [taskId]);
    }
  }

  @override
  Future<void> removeModifiedTask(String? taskId) =>
      remove(modifiedTasksTable, taskId);

  @override
  Future<void> removePausedTask(String? taskId) =>
      remove(pausedTasksTable, taskId);

  @override
  Future<void> removeResumeData(String? taskId) =>
      remove(resumeDataTable, taskId);

  @override
  Future<void> removeTaskRecord(String? taskId) =>
      remove(taskRecordsTable, taskId);

  @override
  Future<List<Task>> retrieveAllModifiedTasks() async {
    final result = await db.query(modifiedTasksTable,
        columns: [objectColumn], where: null);
    return result
        .map((e) =>
            Task.createFromJsonMap(jsonDecode(e[objectColumn] as String)))
        .toList(growable: false);
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() async {
    final result =
        await db.query(pausedTasksTable, columns: [objectColumn], where: null);
    return result
        .map((e) =>
            Task.createFromJsonMap(jsonDecode(e[objectColumn] as String)))
        .toList(growable: false);
  }

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async {
    final result =
        await db.query(resumeDataTable, columns: [objectColumn], where: null);
    return result
        .map((e) =>
            ResumeData.fromJsonMap(jsonDecode(e[objectColumn] as String)))
        .toList(growable: false);
  }

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async {
    final result =
        await db.query(taskRecordsTable, columns: [objectColumn], where: null);
    return result
        .map((e) =>
            TaskRecord.fromJsonMap(jsonDecode(e[objectColumn] as String)))
        .toList(growable: false);
  }

  @override
  Future<Task?> retrieveModifiedTask(String taskId) async {
    final result = await db.query(modifiedTasksTable,
        columns: [objectColumn],
        where: '$taskIdColumn = ?',
        whereArgs: [taskId]);
    if (result.isEmpty) {
      return null;
    }
    return Task.createFromJsonMap(
        jsonDecode(result.first[objectColumn] as String));
  }

  @override
  Future<Task?> retrievePausedTask(String taskId) async {
    final result = await db.query(pausedTasksTable,
        columns: [objectColumn],
        where: '$taskIdColumn = ?',
        whereArgs: [taskId]);
    if (result.isEmpty) {
      return null;
    }
    return Task.createFromJsonMap(
        jsonDecode(result.first[objectColumn] as String));
  }

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async {
    final result = await db.query(resumeDataTable,
        columns: [objectColumn],
        where: '$taskIdColumn = ?',
        whereArgs: [taskId]);
    if (result.isEmpty) {
      return null;
    }
    return ResumeData.fromJsonMap(
        jsonDecode(result.first[objectColumn] as String));
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async {
    final result = await db.query(taskRecordsTable,
        columns: [objectColumn],
        where: '$taskIdColumn = ?',
        whereArgs: [taskId]);
    if (result.isEmpty) {
      return null;
    }
    return TaskRecord.fromJsonMap(
        jsonDecode(result.first[objectColumn] as String));
  }

  Future<void> store(
      String table, String taskId, Map<String, dynamic> jsonMap) async {
    final existingRecord = await db.query(table,
        columns: [objectColumn],
        where: '$taskIdColumn = ?',
        whereArgs: [taskId]);
    if (existingRecord.isEmpty) {
      await db.insert(
          table, {taskIdColumn: taskId, objectColumn: jsonEncode(jsonMap)});
    } else {
      await db.update(taskRecordsTable, {objectColumn: jsonEncode(jsonMap)},
          where: '$taskIdColumn = ?', whereArgs: [taskId]);
    }
  }

  @override
  Future<void> storeModifiedTask(Task task) =>
      store(modifiedTasksTable, task.taskId, task.toJsonMap());

  @override
  Future<void> storePausedTask(Task task) =>
      store(pausedTasksTable, task.taskId, task.toJsonMap());

  @override
  Future<void> storeResumeData(ResumeData resumeData) =>
      store(resumeDataTable, resumeData.taskId, resumeData.toJsonMap());

  @override
  Future<void> storeTaskRecord(TaskRecord record) =>
      store(taskRecordsTable, record.taskId, record.toJsonMap());

  @override
  Future<(String, int)> get storedDatabaseVersion async {
    return ('Sqlite', await db.getVersion());
  }
}

/// Partial implementation used to extract the data stored in a
/// FlutterDownloader SQLite database
///
/// Only the [initialize] and retrieveAll... methods are implemented,
/// as they are called from the migration methods in [SQLitePersistentStorage]
///
/// This is an abstract class, implemented for Android and iOS below
abstract class _FlutterDownloaderPersistentStorage
    implements PersistentStorage {
  sql.Database? _db;
  late final Directory docsDir;
  late final Directory supportDir;
  late final Directory tempDir;
  late final Directory libraryDir;

  /// Return the path to the SQLite database
  Future<String> getDatabasePath();

  /// Close and remove the database file
  Future<void> removeDatabase() async {
    if (_db != null) {
      await _db?.close();
      final dbPath = await getDatabasePath();
      try {
        await File(dbPath).delete();
      } on FileSystemException {
        // ignored
      }
    }
  }

  /// Extract the BaseDirectory and subdirectory from the [savedDir] string
  Future<(BaseDirectory, String)> getDirectories(String savedDir) async {
    BaseDirectory? baseDirectory;
    final directories = [docsDir, tempDir, supportDir, libraryDir];
    for (final dir in directories) {
      final subDir = _subDir(dir, savedDir);
      if (subDir != null) {
        baseDirectory = BaseDirectory.values[directories.indexOf(dir)];
        return (
          baseDirectory,
          subDir.endsWith('/') ? subDir.substring(0, subDir.length - 1) : subDir
        );
      }
    }
    // if no match, savedDir points to somewhere outside the app space:
    // we return BaseDirectory.applicationDocuments and the entire savedDir
    return (BaseDirectory.applicationDocuments, savedDir);
  }

  /// Returns the subdirectory of the given [directory] within [savedDir] or null
  String? _subDir(Directory directory, String savedDir) =>
      RegExp('${docsDir.path}/(.*)').firstMatch(savedDir)?.group(1);

  // From here on down is PersistentStorage interface implementation

  @override
  (String, int) get currentDatabaseVersion => throw UnimplementedError();

  @override
  Future<void> initialize() async {
    final dbPath = await getDatabasePath();
    if (await File(dbPath).exists()) {
      // only open the database if it already exists - we don't create it
      _db = await sql.openDatabase(dbPath);
      // set directory fields once
      docsDir = await getApplicationDocumentsDirectory();
      supportDir = await getApplicationSupportDirectory();
      tempDir = await getTemporaryDirectory();
      libraryDir = Platform.isIOS
          ? await getLibraryDirectory()
          : Directory(join(supportDir.path, 'Library'));
    }
  }

  @override
  Future<List<Task>> retrieveAllModifiedTasks() => Future.value([]);

  @override
  Future<List<Task>> retrieveAllPausedTasks() => Future.value([]);

  @override
  Future<List<ResumeData>> retrieveAllResumeData() => Future.value([]);

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async {
    if (_db == null) {
      return [];
    }
    final result = await _db!.query('tasks',
        columns: [
          'task_id',
          'status',
          'url',
          'saved_dir',
          'file_name',
          'headers',
          'time_created'
        ],
        where: 'status = ? OR status = ? OR status = ?',
        whereArgs: [3, 4, 5]);
    final taskRecords = <TaskRecord>[];
    for (var fdlTask in result) {
      final headers = (fdlTask['headers'] as String? ?? '').isEmpty
          ? ''
          : jsonDecode(fdlTask['headers'] as String);
      var (baseDirectory, directory) =
          await getDirectories(fdlTask['savedDir'] as String? ?? '');
      final creationTime = DateTime.fromMillisecondsSinceEpoch(
          fdlTask['time_created'] as int? ?? 0);
      final task = DownloadTask(
          taskId: fdlTask['task_id'] as String?,
          url: fdlTask['url'] as String,
          filename: fdlTask['file_name'] as String,
          headers: headers,
          baseDirectory: baseDirectory,
          directory: directory,
          updates: Updates.statusAndProgress,
          creationTime: creationTime);
      final (status, progress) = switch (fdlTask['status'] as int? ?? 0) {
        3 => (TaskStatus.complete, progressComplete),
        4 => (TaskStatus.failed, progressFailed),
        5 => (TaskStatus.canceled, progressCanceled),
        _ => (TaskStatus.failed, progressFailed)
      };
      final record = TaskRecord(task, status, progress, -1);
      taskRecords.add(record);
    }
    return taskRecords;
  }

  // the rest of the interface is not implemented, as it is never called

  @override
  Future<void> removeModifiedTask(String? taskId) {
    throw UnimplementedError();
  }

  @override
  Future<void> removePausedTask(String? taskId) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeResumeData(String? taskId) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeTaskRecord(String? taskId) {
    throw UnimplementedError();
  }

  @override
  Future<Task?> retrieveModifiedTask(String taskId) {
    throw UnimplementedError();
  }

  @override
  Future<Task?> retrievePausedTask(String taskId) {
    throw UnimplementedError();
  }

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) {
    throw UnimplementedError();
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) {
    throw UnimplementedError();
  }

  @override
  Future<void> storeModifiedTask(Task task) {
    throw UnimplementedError();
  }

  @override
  Future<void> storePausedTask(Task task) {
    throw UnimplementedError();
  }

  @override
  Future<void> storeResumeData(ResumeData resumeData) {
    throw UnimplementedError();
  }

  @override
  Future<void> storeTaskRecord(TaskRecord record) {
    throw UnimplementedError();
  }

  @override
  Future<(String, int)> get storedDatabaseVersion => throw UnimplementedError();
}

class _FlutterDownloaderPersistentStorageAndroid
    extends _FlutterDownloaderPersistentStorage {
  @override
  Future<String> getDatabasePath() async {
    final docsDir = await getApplicationDocumentsDirectory();
    return join(docsDir.path, 'databases', 'download_tasks.db');
  }
}

class _FlutterDownloaderPersistentStorageIOS
    extends _FlutterDownloaderPersistentStorage {
  @override
  Future<String> getDatabasePath() async {
    final supportDir = await getApplicationSupportDirectory();
    return join(supportDir.path, 'download_tasks.sql');
  }
}
