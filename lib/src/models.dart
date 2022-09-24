import 'dart:math';

/// Defines a set of possible states which a [DownloadTask] can be in.
enum DownloadTaskStatus {
  undefined,
  enqueued,
  running,
  complete,
  notFound,
  failed,
  canceled;
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

/// Type of download updates requested for a group of downloads
enum DownloadTaskProgressUpdates {
  none, // no status or progress updates
  statusChange, // only calls upon change in DownloadTaskStatus
  progressUpdates, // only progress updates
  statusChangeAndProgressUpdates, // calls also for progress along the way
}

/// Information related to a download
class BackgroundDownloadTask {
  final String taskId;
  final String url;
  final String filename;
  final String directory;
  final BaseDirectory baseDirectory;
  final String group;
  final DownloadTaskProgressUpdates progressUpdates;

  BackgroundDownloadTask(
      {String? taskId,
      required this.url,
      required this.filename,
      this.directory = '',
      this.baseDirectory = BaseDirectory.applicationDocuments,
      this.group = 'default',
      this.progressUpdates = DownloadTaskProgressUpdates.statusChange})
      : taskId = taskId ?? Random().nextInt(1 << 32).toString();

  /// Creates object from JsonMap
  BackgroundDownloadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : taskId = jsonMap['taskId'],
        url = jsonMap['url'],
        filename = jsonMap['filename'],
        directory = jsonMap['directory'],
        baseDirectory = BaseDirectory.values[jsonMap['baseDirectory']],
        group = jsonMap['group'],
        progressUpdates =
            DownloadTaskProgressUpdates.values[jsonMap['progressUpdates']];

  /// Creates JSON map of this object
  Map toJsonMap() => {
        'taskId': taskId,
        'url': url,
        'filename': filename,
        'directory': directory,
        'baseDirectory': baseDirectory.index, // stored as int
        'group': group,
        'progressUpdates': progressUpdates.index
      };

  /// If true, task expects progress updates
  bool get providesProgressUpdates =>
      progressUpdates == DownloadTaskProgressUpdates.progressUpdates ||
      progressUpdates ==
          DownloadTaskProgressUpdates.statusChangeAndProgressUpdates;

  /// If true, task expects status updates
  bool get providesStatusUpdates =>
      progressUpdates == DownloadTaskProgressUpdates.statusChange ||
          progressUpdates ==
              DownloadTaskProgressUpdates.statusChangeAndProgressUpdates;

  @override
  String toString() {
    return 'BackgroundDownloadTask{taskId: $taskId, url: $url, filename: $filename, directory: $directory, baseDirectory: $baseDirectory, group: $group, progressUpdates: $progressUpdates}';
  }
}
