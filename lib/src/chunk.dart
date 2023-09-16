import 'dart:convert';

import 'base_downloader.dart';
import 'file_downloader.dart';
import 'models.dart';

/// Class representing a chunk of a download and its status
class Chunk {
  // key parameters
  final String parentTaskId;
  final String url;
  final String filename;
  final int from; // start byte
  final int to; // end byte
  final DownloadTask task; // task to download this chunk

  // state parameters
  late TaskStatusUpdate statusUpdate;
  late TaskProgressUpdate progressUpdate;

  /// Define a chunk by its key parameters, in default state
  ///
  /// This also generates the [task] to download this chunk, and that
  /// task contains the [parentTaskId] and [to] and [from] values of the
  /// chunk in its [Task.metaData] field as a JSON encoded map
  Chunk({required Task parentTask,
    required this.url,
    required this.filename,
    required this.from,
    required this.to})
      : parentTaskId = parentTask.taskId,
        task = DownloadTask(
            url: url,
            filename: filename,
            headers: {...parentTask.headers, 'Range': 'bytes=$from-$to'},
            baseDirectory: BaseDirectory.temporary,
            group: BaseDownloader.chunkGroup,
            updates: parentTask.updates,
            retries: parentTask.retries,
            allowPause: parentTask.allowPause,
            requiresWiFi: parentTask.requiresWiFi,
            metaData: jsonEncode(
                {'parentTaskId': parentTask.taskId, 'from': from, 'to': to})) {
    statusUpdate = TaskStatusUpdate(task, TaskStatus.enqueued);
    progressUpdate = TaskProgressUpdate(task, 0);
  }

  /// Size of this chunk in bytes
  int get size => to - from;

  /// Creates object from JsonMap
  Chunk.fromJsonMap(Map<String, dynamic> jsonMap)
      : parentTaskId = jsonMap['parentTaskId'],
        url = jsonMap['url'],
        filename = jsonMap['filename'],
        from = (jsonMap['from'] as num).toInt(),
        to = (jsonMap['to'] as num).toInt(),
        task = Task.createFromJsonMap(jsonMap['task']) as DownloadTask,
        statusUpdate = TaskStatusUpdate.fromJsonMap(jsonMap['statusUpdate']),
        progressUpdate =
        TaskProgressUpdate.fromJsonMap(jsonMap['progressUpdate']);

  /// Revive Chunk or List<Chunk> from a JSON map in a jsonDecode operation
  static Object? reviver(Object? key, Object? value) =>
      key is int ? Chunk.fromJsonMap(jsonDecode(value as String)) : value;

  /// Creates JSON map of this object
  Map<String, dynamic> toJsonMap() =>
      {
        'parentTaskId': parentTaskId,
        'url': url,
        'filename': filename,
        'from': from,
        'to': to,
        'task': task.toJsonMap(),
        'statusUpdate': statusUpdate.toJsonMap(),
        'progressUpdate': progressUpdate.toJsonMap()
      };

  /// Creates JSON String of this object
  String toJson() => jsonEncode(toJsonMap());

  /// Return the parentTaskId embedded in the metaData of a chunkTask
  static String getParentTaskId(Task task) =>
      jsonDecode(task.metaData)['parentTaskId'] as String;
}

/// Resume all chunk tasks associated with this [task], and
/// return true if successful, otherwise cancels this [task]
/// which will also cancel all chunk tasks
Future<bool> resumeChunkTasks(ParallelDownloadTask task,
    ResumeData resumeData) async {
  final List<Chunk> chunks = List.from(jsonDecode(resumeData.data,
      reviver: Chunk.reviver));
  final results = await Future.wait(
      chunks.map((chunk) => FileDownloader().resume(chunk.task)));
  if (results.any((result) => result == false)) {
    // cancel [ParallelDownloadTask] if any resume did not succeed.
    // this will also cancel all chunk tasks
    await FileDownloader().cancelTaskWithId(task.taskId);
    return false;
  }
  return true;
}
