import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sql;

import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'models.dart';
import 'persistent_storage.dart';

/// [PersistentStorage] to back the database in the downloader, using
/// an SQLite database as its own backend
///
/// Uses the sqflite package, so is limited to platforms supported by that
/// package.
///
/// Data is stored in simple tables, one for each data type, with each table
/// having a 'taskId' column, and a 'objectJsonMap' column where the object of
/// that data type is stored in JSON string format.
///
/// The [SqlitePersistentStorage] can be constructed with a list of migration
/// options, and an optional [PersistentStorageMigrator] to execute the
/// migration from one of those options to this object.
///
/// A constructed [SqlitePersistentStorage] can be passed to the
/// [FileDownloader] constructor to set the persistent storage to be used. It
/// must be set on the very first call to [FileDownloader] only.
class SqlitePersistentStorage implements PersistentStorage {
  final log = Logger('SqlitePersistentStorage');

  late final sql.Database db;
  final List<String> _migrationOptions;
  final PersistentStorageMigrator _persistentStorageMigrator;

  final taskRecordsTable = 'taskRecords';
  final modifiedTasksTable = 'modifiedTasksTable';
  final pausedTasksTable = 'pausedTasksTable';
  final resumeDataTable = 'resumeDataTable';

  final taskIdColumn = 'taskId';
  final objectColumn = 'objectJsonMap';
  final modifiedColumn = 'modified'; // in seconds since epoch

  /// Create [SqlitePersistentStorage] object with optional list of database
  /// backends to migrate from, using the [persistentStorageMigrator]
  ///
  /// The default [persistentStorageMigrator] supports the following migrations:
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
  SqlitePersistentStorage(
      {List<String>? migrationOptions,
      PersistentStorageMigrator? persistentStorageMigrator})
      : _migrationOptions = migrationOptions ?? [],
        _persistentStorageMigrator =
            persistentStorageMigrator ?? PersistentStorageMigrator();

  @override
  (String, int) get currentDatabaseVersion => ('Sqlite', 1);

  @override
  Future<void> initialize() async {
    final databasesPath = await (Platform.isIOS || Platform.isMacOS
        ? getLibraryDirectory()
        : getApplicationSupportDirectory());
    final dbPath =
        path.join(databasesPath.path, 'bgd_persistent_storage.sqlite');
    bool createdDatabase = false;
    db = await sql.openDatabase(dbPath, version: 1,
        onCreate: (sql.Database dbase, int version) async {
      // When creating the db, create the table
      await dbase.execute(
          'CREATE TABLE $taskRecordsTable (taskId TEXT PRIMARY KEY, url TEXT, filename TEXT, '
          '"group" TEXT, metaData TEXT, creationTime INTEGER, status INTEGER, '
          'progress REAL, $objectColumn TEXT)');
      await dbase.execute(
          'CREATE TABLE $pausedTasksTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT, '
          '$modifiedColumn INTEGER)');
      await dbase.execute(
          'CREATE TABLE $modifiedTasksTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT, '
          '$modifiedColumn INTEGER)');
      await dbase.execute(
          'CREATE TABLE $resumeDataTable ($taskIdColumn TEXT PRIMARY KEY, $objectColumn TEXT, '
          '$modifiedColumn INTEGER)');
      createdDatabase = true; // newly created database
    });
    // upon first creation, attempt database migrations
    if (createdDatabase && _migrationOptions.isNotEmpty) {
      final migratedFrom =
          await _persistentStorageMigrator.migrate(_migrationOptions, this);
      if (migratedFrom != null) {
        log.fine('Migrated database from $migratedFrom');
      }
    }
    await purgeOldRecords();
    log.finest('Initialized SqlitePersistentStorage database at ${db.path}');
  }

  /// Purges records in [modifiedTasksTable], [pausedTasksTable] and
  /// [resumeDataTable] that were modified more than [age] ago.
  Future<void> purgeOldRecords(
      {Duration age = const Duration(days: 30)}) async {
    final cutOff =
        (DateTime.now().subtract(age).millisecondsSinceEpoch / 1000).floor();
    for (final table in [
      modifiedTasksTable,
      pausedTasksTable,
      resumeDataTable
    ]) {
      await db.delete(table, where: '$modifiedColumn < ?', whereArgs: [cutOff]);
    }
  }

  /// Remove the row with [taskId] from the [table]. If [taskId] is null,
  /// removes all rows from the [table]
  Future<void> _remove(String table, String? taskId) async {
    if (taskId == null) {
      await db.delete(table, where: null);
    } else {
      await db.delete(table, where: '$taskIdColumn = ?', whereArgs: [taskId]);
    }
  }

  @override
  Future<void> removeModifiedTask(String? taskId) =>
      _remove(modifiedTasksTable, taskId);

  @override
  Future<void> removePausedTask(String? taskId) =>
      _remove(pausedTasksTable, taskId);

  @override
  Future<void> removeResumeData(String? taskId) =>
      _remove(resumeDataTable, taskId);

  @override
  Future<void> removeTaskRecord(String? taskId) =>
      _remove(taskRecordsTable, taskId);

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
    final result = await retrieveTaskRecords('$taskIdColumn = ?', [taskId]);
    return result.firstOrNull;
  }

  /// Returns a list of [TaskRecord] objects matching the condition defined
  /// by the SQLite [where] and [whereArgs] arguments.
  ///
  /// Example:
  ///   final records = retrieveTaskRecords(where: 'status = ? AND timeCreated < ?',
  ///       whereArgs: [TaskStatus.complete.index,
  ///         DateTime.now().subtract(const Duration(days: 5)).millisecondsSinceEpoch]);
  ///   // This returns records that have completed more than 5 days ago
  ///
  /// The database fields that can be used in this query are:
  ///   taskId, url, filename, group, metaData, creationTime, status and progress,
  ///   where creationTime is in secondsSinceEpoch and status is the index of
  ///   the [TaskStatus] enum
  Future<List<TaskRecord>> retrieveTaskRecords(
      String where, List<Object?>? whereArgs) async {
    final result = await db.query(taskRecordsTable,
        columns: [objectColumn], where: where, whereArgs: whereArgs);
    return result
        .map((e) =>
            TaskRecord.fromJsonMap(jsonDecode(e[objectColumn] as String)))
        .toList(growable: false);
  }

  /// Convenience method to store a jsonMap under the [objectColumn], keyed
  /// by [taskId], with 'modified' set to seconds since epoch.
  ///
  /// Inserts or updates
  Future<void> store(
          String table, String taskId, Map<String, dynamic> jsonMap) =>
      db.insert(
          table,
          {
            taskIdColumn: taskId,
            objectColumn: jsonEncode(jsonMap),
            modifiedColumn:
                (DateTime.now().millisecondsSinceEpoch / 1000).floor()
          },
          conflictAlgorithm: sql.ConflictAlgorithm.replace);

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
  Future<void> storeTaskRecord(TaskRecord record) async {
    final task = record.task;
    await db.insert(
        taskRecordsTable,
        {
          taskIdColumn: task.taskId,
          'url': task.url,
          'filename': task.filename,
          'group': task.group,
          'metaData': task.metaData,
          'creationTime': (task.creationTime.millisecondsSinceEpoch / 1000).floor(),
          'status': record.status.index,
          'progress': record.progress,
          objectColumn: jsonEncode(record.toJsonMap())
        },
        conflictAlgorithm: sql.ConflictAlgorithm.replace);
  }

  @override
  Future<(String, int)> get storedDatabaseVersion async {
    return ('Sqlite', await db.getVersion());
  }
}

/// Partial implementation used to extract the data stored in a
/// FlutterDownloader SQLite database
///
/// Only the [initialize] and retrieveAll... methods are implemented,
/// as they are called from the migration methods in [PersistentStorageMigrator]
///
/// This is an abstract class, implemented for Android and iOS below
abstract class FlutterDownloaderPersistentStorage implements PersistentStorage {
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
          : Directory(path.join(supportDir.path, 'Library'));
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
    final result = await _db!.query('task',
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
      final Map<String, String> headers =
          (fdlTask['headers'] as String? ?? '').isEmpty
              ? {}
              : Map.castFrom(jsonDecode(fdlTask['headers'] as String));
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

class FlutterDownloaderPersistentStorageAndroid
    extends FlutterDownloaderPersistentStorage {
  @override
  Future<String> getDatabasePath() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbDir =
        RegExp(r'^.*?(?=app_flutter)').firstMatch(docsDir.path)?.group(0);
    return path.join(dbDir!, 'databases', 'download_tasks.db');
  }
}

class FlutterDownloaderPersistentStorageIOS
    extends FlutterDownloaderPersistentStorage {
  @override
  Future<String> getDatabasePath() async {
    final supportDir = await getApplicationSupportDirectory();
    return path.join(supportDir.path, 'download_tasks.sql');
  }
}
