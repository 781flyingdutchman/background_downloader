import 'dart:io';
import 'dart:math';

/// Defines a set of possible states which a [DownloadTask] can be in.
enum DownloadTaskStatus {
  /// Unknown state
  undefined,

  /// Task is being handled by the native platform
  running,

  /// Task has completed successfully and the file is available
  ///
  /// This is a final state
  complete,

  /// Task has completed because the url was not found (Http status code 404)
  ///
  /// This is a final state
  notFound,

  /// Task has failed to download due to an error
  ///
  /// This is a final state
  failed,

  /// Task has been canceled by the user or the system
  ///
  /// This is a final state
  canceled;

  /// True if this state is one of the 'final' states, meaning no more
  /// state changes are possible
  bool get isFinalState {
    switch (this) {
      case DownloadTaskStatus.complete:
      case DownloadTaskStatus.notFound:
      case DownloadTaskStatus.failed:
      case DownloadTaskStatus.canceled:
        return true;

      case DownloadTaskStatus.undefined:
      case DownloadTaskStatus.running:
        return false;
    }
  }

  /// True if this state is not a 'final' state, meaning more
  /// state changes are possible
  bool get isNotFinalState => !isFinalState;
}

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum BaseDirectory {
  /// As returned by getApplicationDocumentsDirectory()
  applicationDocuments,

  /// As returned by getTemporaryDirectory()
  temporary,

  /// As returned by getApplicationSupportDirectory() - iOS only
  applicationSupport
}

/// Type of download updates requested for a group of downloads
enum DownloadTaskProgressUpdates {
  /// no status change or progress updates
  none,

  /// only status changes
  statusChange,

  /// only progress updates while downloading, no status change updates
  progressUpdates,

  /// Status change updates and progress updates while downloading
  statusChangeAndProgressUpdates,
}

/// Information related to a download
///
/// An equality test on a [BackgroundDownloadTask] is a test on the [taskId]
/// only - all other fields are ignored in that test
class BackgroundDownloadTask {
  /// Identifier for the task - auto generated if omitted
  final String taskId;

  /// String representation of the url from which to download
  final String url;

  /// Filename of the file to store
  final String filename;

  /// potential additional headers to send with the request
  final Map<String, String> headers;

  /// Optional directory, relative to the base directory
  final String directory;

  /// Base directory
  final BaseDirectory baseDirectory;

  /// Group that this task belongs to
  final String group;

  /// Type of progress updates desired
  final DownloadTaskProgressUpdates progressUpdates;

  /// User-defined metadata
  final String metaData;

  BackgroundDownloadTask(
      {String? taskId,
      required this.url,
      required this.filename,
      this.headers = const {},
      this.directory = '',
      this.baseDirectory = BaseDirectory.applicationDocuments,
      this.group = 'default',
      this.progressUpdates = DownloadTaskProgressUpdates.statusChange,
      this.metaData = ''})
      : taskId = taskId ?? Random().nextInt(1 << 32).toString() {
    if (filename.isEmpty) {
      throw ArgumentError('Filename cannot be empty');
    }
    if (filename.contains(Platform.pathSeparator)) {
      throw ArgumentError('Filename cannot contain path separators');
    }
    if (directory.startsWith(Platform.pathSeparator)) {
      throw ArgumentError(
          'Directory must be relative to the baseDirectory specified in the baseDirectory argument');
    }
  }

  /// Returns a copy of the [BackgroundDownloadTask] with optional changes to
  /// specific fields
  BackgroundDownloadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          DownloadTaskProgressUpdates? progressUpdates,
          String? metaData}) =>
      BackgroundDownloadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          progressUpdates: progressUpdates ?? this.progressUpdates,
          metaData: metaData ?? this.metaData);

  /// Creates object from JsonMap
  BackgroundDownloadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : taskId = jsonMap['taskId'],
        url = jsonMap['url'],
        filename = jsonMap['filename'],
        headers = Map<String, String>.from(jsonMap['headers']),
        directory = jsonMap['directory'],
        baseDirectory = BaseDirectory.values[jsonMap['baseDirectory']],
        group = jsonMap['group'],
        progressUpdates =
            DownloadTaskProgressUpdates.values[jsonMap['progressUpdates']],
        metaData = jsonMap['metaData'];

  /// Creates JSON map of this object
  Map toJsonMap() => {
        'taskId': taskId,
        'url': url,
        'filename': filename,
        'headers': headers,
        'directory': directory,
        'baseDirectory': baseDirectory.index, // stored as int
        'group': group,
        'progressUpdates': progressUpdates.index,
        'metaData': metaData
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundDownloadTask &&
          runtimeType == other.runtimeType &&
          taskId == other.taskId;

  @override
  int get hashCode => taskId.hashCode;

  @override
  String toString() {
    return 'BackgroundDownloadTask{taskId: $taskId, url: $url, filename: $filename, headers: $headers, directory: $directory, baseDirectory: $baseDirectory, group: $group, progressUpdates: $progressUpdates, metaData: $metaData}';
  }
}

/// Signature for a function you can provide to the [downloadBatch] method
/// that will be called upon completion of each file download in the batch.
///
/// [succeeded] will count the number of successful downloads, and
/// [failed] counts the number of failed downloads (for any reason).
typedef BatchDownloadProgressCallback = void Function(
    int succeeded, int failed);

/// Contains tasks and results related to a batch of downloads
class BackgroundDownloadBatch {
  final List<BackgroundDownloadTask> tasks;
  final BatchDownloadProgressCallback? batchDownloadProgressCallback;
  final results = <BackgroundDownloadTask, DownloadTaskStatus>{};

  BackgroundDownloadBatch(this.tasks, this.batchDownloadProgressCallback);

  /// Returns an Iterable with successful downloads in this batch
  Iterable<BackgroundDownloadTask> get succeeded => results.entries
      .where((entry) => entry.value == DownloadTaskStatus.complete)
      .map((e) => e.key);

  /// Returns the number of successful downloads in this batch
  int get numSucceeded => results.values
      .where((result) => result == DownloadTaskStatus.complete)
      .length;

  /// Returns an Iterable with failed downloads in this batch
  Iterable<BackgroundDownloadTask> get failed => results.entries
      .where((entry) => entry.value != DownloadTaskStatus.complete)
      .map((e) => e.key);

  /// Returns the number of failed downloads in this batch
  int get numFailed => results.values.length - numSucceeded;
}

/// Base class for events related to [task]. Actual events are
/// either a status update or a progress update.
///
/// When receiving an event, test if the event is a
/// [BackgroundDownloadStatusEvent] or a [BackgroundDownloadProgressEvent]
/// and treat the event accordingly
class BackgroundDownloadEvent {
  final BackgroundDownloadTask task;

  BackgroundDownloadEvent(this.task);
}

/// A status update event
class BackgroundDownloadStatusEvent extends BackgroundDownloadEvent {
  final DownloadTaskStatus status;

  BackgroundDownloadStatusEvent(super.task, this.status);
}

/// A progress update event
///
/// A successfully downloaded task will always finish with progress 1.0
/// [DownloadTaskStatus.failed] results in progress -1.0
/// [DownloadTaskStatus.canceled] results in progress -2.0
/// [DownloadTaskStatus.notFound] results in progress -3.0
class BackgroundDownloadProgressEvent extends BackgroundDownloadEvent {
  final double progress;

  BackgroundDownloadProgressEvent(super.task, this.progress);
}
