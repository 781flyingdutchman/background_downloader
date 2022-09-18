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

/// Information related to a download
class BackgroundDownloadTask {
  final String taskId;
  final String url;
  final String filename;
  final String directory;
  final BaseDirectory baseDirectory;

  BackgroundDownloadTask(
      {String? taskId,
      required this.url,
      required this.filename,
      this.directory = "",
      this.baseDirectory = BaseDirectory.applicationDocuments})
      : taskId = taskId ?? Random().nextInt(1 << 32).toString();

  /// Creates JSON map of this object
  Map toJson() => {
        'taskId': taskId,
        'url': url,
        'filename': filename,
        'directory': directory,
        'baseDirectory': baseDirectory.index // stored as int
      };
}
