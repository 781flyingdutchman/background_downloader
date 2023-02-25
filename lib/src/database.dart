import 'package:localstore/localstore.dart';

import 'models.dart';

/// Persistent database used for tracking task status and progress.
///
/// Stores [TaskRecord] objects.
///
/// This object is accessed by the [Downloader] and [BaseDownloader]
class Database {
  static final Database _singleton = Database._internal();
  final db = Localstore.instance;
  static const tasksPath = 'taskCollection';

  factory Database() => _singleton;

  Database._internal();

  /// Update or insert the record in the database
  Future<void> updateRecord(TaskRecord record) async {
    await db.collection(tasksPath).doc(record.taskId).set(record.toJsonMap());
  }

  /// Returns all records in this [group]
  Future<List<TaskRecord>> allRecords(String group) async {
    final allJsonRecords = await db.collection(tasksPath).get();
    return allJsonRecords?.values
            .map((e) => TaskRecord.fromJsonMap(e))
            .where((element) => element.group == group)
            .toList() ??
        [];
  }

  /// Return database record for this [taskId]
  Future<TaskRecord?> recordForId(String taskId) async {
    final jsonMap = await db.collection(tasksPath).doc(taskId).get();
    return jsonMap != null ? TaskRecord.fromJsonMap(jsonMap) : null;
  }

  /// Delete all records
  Future<void> deleteRecords() => db.collection(tasksPath).delete();

  /// Delete records with these [taskIds]
  Future<void> deleteRecordsWithIds(List<String> taskIds) async {
    for (var taskId in taskIds) {
      await db.collection(tasksPath).doc(taskId).delete();
    }
  }

  /// Delete record with this [taskId]
  Future<void> deleteRecordWithId(String taskId) =>
      deleteRecordsWithIds([taskId]);
}

/// Record containing task, task status and task progress.
///
/// [TaskRecord] represents the state of the task as recorded in persistent
/// storage if [trackTasks] has been called to activate this.
class TaskRecord {
  final Task task;
  final TaskStatus status;
  final double progress;

  TaskRecord(this.task, this.status, this.progress);

  /// Returns the group collection this record is stored under
  String get group => task.group;

  /// Returns the record id
  String get taskId => task.taskId;

  /// Create [TaskRecord] from a JSON map
  TaskRecord.fromJsonMap(Map<String, dynamic> jsonMap)
      : task = Task.createFromJsonMap(jsonMap),
        status = TaskStatus.values[jsonMap['status'] as int],
        progress = jsonMap['progress'];

  /// Returns JSON map representation of this [TaskRecord]
  Map<String, dynamic> toJsonMap() {
    final jsonMap = task.toJsonMap();
    jsonMap['status'] = status.index;
    jsonMap['progress'] = progress;
    return jsonMap;
  }

  /// Copy with optional replacements
  TaskRecord copyWith({Task? task, TaskStatus? status, double? progress}) =>
      TaskRecord(
          task ?? this.task, status ?? this.status, progress ?? this.progress);

  @override
  String toString() {
    return 'DatabaseRecord{task: $task, status: $status, progress: $progress}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskRecord &&
          runtimeType == other.runtimeType &&
          task == other.task &&
          status == other.status &&
          progress == other.progress;

  @override
  int get hashCode => task.hashCode ^ status.hashCode ^ progress.hashCode;
}
