import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/base_downloader.dart';
import 'package:localstore/localstore.dart';

/// Persistent database used for tracking task status and progress.
///
/// Stores [TaskRecord] objects.
///
/// This object is accessed by the [Downloader] and [BaseDownloader]
class Database {
  static final Database _instance = Database._internal();
  final _db = Localstore.instance;
  static const tasksPath = 'backgroundDownloaderTaskRecords';

  factory Database() => _instance;

  Database._internal();

  /// Returns all [TaskRecord]
  ///
  /// Optionally, specify a [group] to filter by
  Future<List<TaskRecord>> allRecords({String? group}) async {
    final allJsonRecords = await _db.collection(tasksPath).get();
    final allRecords =
        allJsonRecords?.values.map((e) => TaskRecord.fromJsonMap(e));
    return group == null
        ? allRecords?.toList() ?? []
        : allRecords?.where((element) => element.group == group).toList() ?? [];
  }

  /// Return [TaskRecord] for this [taskId]
  Future<TaskRecord?> recordForId(String taskId) async {
    final jsonMap = await _db.collection(tasksPath).doc(taskId).get();
    return jsonMap != null ? TaskRecord.fromJsonMap(jsonMap) : null;
  }

  /// Return list of [TaskRecord] corresponding to the [taskIds]
  ///
  /// Only records that can be found in the database will be included in the
  /// list. TaskIds that cannot be found will be ignored.
  Future<List<TaskRecord>> recordsForIds(Iterable<String> taskIds) async {
    final result = <TaskRecord>[];
    for (var taskId in taskIds) {
      final record = await recordForId(taskId);
      if (record != null) {
        result.add(record);
      }
    }
    return result;
  }

  /// Delete all records
  ///
  /// Optionally, specify a [group] to filter by
  Future<void> deleteAllRecords({String? group}) async {
    if (group == null) {
      return _db.collection(tasksPath).delete();
    }
    final allRecordsInGroup = await allRecords(group: group);
    await deleteRecordsWithIds(
        allRecordsInGroup.map((record) => record.taskId));
  }

  /// Delete record with this [taskId]
  Future<void> deleteRecordWithId(String taskId) =>
      deleteRecordsWithIds([taskId]);

  /// Delete records with these [taskIds]
  Future<void> deleteRecordsWithIds(Iterable<String> taskIds) async {
    for (var taskId in taskIds) {
      await _db.collection(tasksPath).doc(taskId).delete();
    }
  }

  /// Update or insert the record in the database
  ///
  /// This is used by the [FileDownloader] to track tasks, and should not
  /// normally be used by the user of this package
  Future<void> updateRecord(TaskRecord record) async {
    await _db.collection(tasksPath).doc(record.taskId).set(record.toJsonMap());
  }
}

/// Record containing task, task status and task progress.
///
/// [TaskRecord] represents the state of the task as recorded in persistent
/// storage if [trackTasks] has been called to activate this.
class TaskRecord {
  final Task task;
  final TaskStatus taskStatus;
  final double progress;

  TaskRecord(this.task, this.taskStatus, this.progress);

  /// Returns the group collection this record is stored under
  String get group => task.group;

  /// Returns the record id
  String get taskId => task.taskId;

  /// Create [TaskRecord] from a JSON map
  TaskRecord.fromJsonMap(Map<String, dynamic> jsonMap)
      : task = Task.createFromJsonMap(jsonMap),
        taskStatus = TaskStatus.values[jsonMap['status'] as int],
        progress = jsonMap['progress'];

  /// Returns JSON map representation of this [TaskRecord]
  Map<String, dynamic> toJsonMap() {
    final jsonMap = task.toJsonMap();
    jsonMap['status'] = taskStatus.index;
    jsonMap['progress'] = progress;
    return jsonMap;
  }

  /// Copy with optional replacements
  TaskRecord copyWith({Task? task, TaskStatus? taskStatus, double? progress}) =>
      TaskRecord(task ?? this.task, taskStatus ?? this.taskStatus,
          progress ?? this.progress);

  @override
  String toString() {
    return 'DatabaseRecord{task: $task, status: $taskStatus, progress: $progress}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskRecord &&
          runtimeType == other.runtimeType &&
          task == other.task &&
          taskStatus == other.taskStatus &&
          progress == other.progress;

  @override
  int get hashCode => task.hashCode ^ taskStatus.hashCode ^ progress.hashCode;
}
