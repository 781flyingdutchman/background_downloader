import 'dart:convert';

/// Defines a set of possible states which a [DownloadTask] can be in.
enum DownloadTaskStatus {
  undefined,
  enqueued,
  running,
  complete,
  failed,
  canceled,
  paused;
}

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum BaseDirectory {
  applicationDocuments, // getApplicationDocumentsDirectory()
  temporary, // getTemporaryDirectory()
  applicationSupport // getApplicationSupportDirectory()
}

/// Encapsulates all information of a single download task.
///
/// This is also the structure of the record saved in the SQLite database.
class DownloadTask {
  /// Creates a new [DownloadTask].
  DownloadTask(
      {required this.taskId,
      required this.status,
      required this.progress,
      required this.url,
      required this.filename,
      required this.savedDir,
      required this.timeCreated,
      this.baseDirectory = BaseDirectory.applicationDocuments});

  /// Unique identifier of this task.
  final String taskId;

  /// Status of this task.
  final DownloadTaskStatus status;

  /// Progress between 0 (inclusive) and 100 (inclusive).
  final int progress;

  /// URL from which the file is downloaded.
  final String url;

  /// Local file name of the downloaded file.
  final String? filename;

  /// Path to the directory where the downloaded file will saved, relative to
  /// the base directory
  final String savedDir;

  /// Timestamp when the task was created.
  final int timeCreated;

  /// Base directory in which downloaded files are stored
  final BaseDirectory baseDirectory;

  @override
  String toString() =>
      'DownloadTask(taskId: $taskId, status: $status, progress: $progress, url: $url, filename: $filename, savedDir: $savedDir, timeCreated: $timeCreated, baseDirectory $baseDirectory)';
}

/// Partial version of the Dart side DownloadTask, only used for background loading
class BackgroundDownloadTask {
  final String taskId;
  final String url;
  final String filename;
  final String savedDir;
  final int baseDirectory;

  BackgroundDownloadTask(
      this.taskId, this.url, this.filename, this.savedDir, this.baseDirectory);

  BackgroundDownloadTask.fromDownloadTask(DownloadTask task)
      : this(task.taskId, task.url, task.filename!, task.savedDir,
            task.baseDirectory.index);

  /// Creates JSON map of this object
  Map toJson() => {
        'taskId': taskId,
        'url': url,
        'filename': filename,
        'savedDir': savedDir,
        'baseDirectory': baseDirectory // stored as int
      };
}
