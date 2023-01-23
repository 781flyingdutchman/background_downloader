import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Defines a set of possible states which a [DownloadTask] can be in.
enum DownloadTaskStatus {
  /// Task is enqueued on the native platform and waiting to start
  ///
  /// It may wait for resources, or for an appropriate network to become
  /// available before starting the actual download and changing state to
  /// `running`.
  enqueued,

  /// Task is running, i.e. actively downloading
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
  canceled,

  /// Task failed, and is now waiting to retry
  ///
  /// The task is held in this state until the exponential backoff time for
  /// this retry has passed, and will then be rescheduled on the native
  /// platform, switching state to `enqueued` and then `running`
  waitingToRetry;

  /// True if this state is one of the 'final' states, meaning no more
  /// state changes are possible
  bool get isFinalState {
    switch (this) {
      case DownloadTaskStatus.complete:
      case DownloadTaskStatus.notFound:
      case DownloadTaskStatus.failed:
      case DownloadTaskStatus.canceled:
        return true;

      case DownloadTaskStatus.enqueued:
      case DownloadTaskStatus.running:
      case DownloadTaskStatus.waitingToRetry:
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
  ///
  /// If the url contains special characters it will be encoded, so ensure
  /// the url provided is not already encoded
  final String url;

  /// Filename of the file to store
  final String filename;

  /// potential additional headers to send with the request
  final Map<String, String> headers;

  /// For tasks used in serverRequest, set [post] to make the request using
  /// POST instead of GET. Post must be one of the following:
  /// true: POST request without a body
  /// a String: POST request with [post] as the body, encoded in utf8 and
  ///   content-type 'text/plain'
  /// a List of bytes: POST request with [post] as the body
  /// a Map: POST request with [post] as form fields, encoded in utf8 and
  ///   content-type 'application/x-www-form-urlencoded'
  final Object? post;

  /// Optional directory, relative to the base directory
  final String directory;

  /// Base directory
  final BaseDirectory baseDirectory;

  /// Group that this task belongs to
  final String group;

  /// Type of progress updates desired
  final DownloadTaskProgressUpdates progressUpdates;

  /// If true, will not download over cellular (metered) network
  final bool requiresWiFi;

  /// Maximum number of retries the downloader should attempt
  ///
  /// Defaults to 0, meaning no retry will be attempted
  final int retries;

  /// Number of retries remaining
  int _retriesRemaining;

  /// User-defined metadata
  final String metaData;

  BackgroundDownloadTask(
      {String? taskId,
      required String url,
      Map<String, String>? urlQueryParameters,
      String? filename,
      this.headers = const {},
      this.post,
      this.directory = '',
      this.baseDirectory = BaseDirectory.applicationDocuments,
      this.group = 'default',
      this.progressUpdates = DownloadTaskProgressUpdates.statusChange,
      this.requiresWiFi = false,
      this.retries = 0,
      this.metaData = ''})
      : taskId = taskId ?? Random().nextInt(1 << 32).toString(),
        _retriesRemaining = retries,
        url = _urlWithQueryParameters(url, urlQueryParameters),
        filename = filename ?? Random().nextInt(1 << 32).toString() {
    if (filename?.isEmpty == true) {
      throw ArgumentError('Filename cannot be empty');
    }
    if (filename?.contains(Platform.pathSeparator) == true) {
      throw ArgumentError('Filename cannot contain path separators');
    }
    if (directory.startsWith(Platform.pathSeparator)) {
      throw ArgumentError(
          'Directory must be relative to the baseDirectory specified in the baseDirectory argument');
    }
    if (retries < 0 || retries > 10) {
      throw ArgumentError('Number of retries must be in range 1 through 10');
    }
    if (!((post == null ||
        post == true) ||
        post is String ||
        post is Uint8List ||
        post is Map<String, String>)) {
      throw ArgumentError(
          'Field post must be null, true, a String, a Uint8List or'
          ' a Map<String, String>');
    }
  }

  /// Returns a copy of the [BackgroundDownloadTask] with optional changes to
  /// specific fields
  BackgroundDownloadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          Object? post,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          DownloadTaskProgressUpdates? progressUpdates,
          bool? requiresWiFi,
          int? retries,
          String? metaData}) =>
      BackgroundDownloadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          post: post ?? this.post,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          progressUpdates: progressUpdates ?? this.progressUpdates,
          requiresWiFi: requiresWiFi ?? this.requiresWiFi,
          retries: retries ?? this.retries,
          metaData: metaData ?? this.metaData);

  /// Creates object from JsonMap
  BackgroundDownloadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : taskId = jsonMap['taskId'],
        url = jsonMap['url'],
        filename = jsonMap['filename'],
        headers = Map<String, String>.from(jsonMap['headers']),
        post = jsonMap['post'],
        directory = jsonMap['directory'],
        baseDirectory = BaseDirectory.values[jsonMap['baseDirectory']],
        group = jsonMap['group'],
        progressUpdates =
            DownloadTaskProgressUpdates.values[jsonMap['progressUpdates']],
        requiresWiFi = jsonMap['requiresWiFi'],
        retries = jsonMap['retries'],
        _retriesRemaining = jsonMap['retriesRemaining'],
        metaData = jsonMap['metaData'];

  /// Creates JSON map of this object
  Map toJsonMap() => {
        'taskId': taskId,
        'url': url,
        'filename': filename,
        'headers': headers,
        'post': post,
        'directory': directory,
        'baseDirectory': baseDirectory.index, // stored as int
        'group': group,
        'progressUpdates': progressUpdates.index, // stored as int
        'requiresWiFi': requiresWiFi,
        'retries': retries,
        'retriesRemaining': _retriesRemaining,
        'metaData': metaData
      };

  /// Reduce count of retries remaining by 1
  ///
  /// Used by [FileDownloader]
  void reduceRetriesRemaining() => _retriesRemaining--;

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

  int get retriesRemaining => _retriesRemaining;

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
    return 'BackgroundDownloadTask{taskId: $taskId, url: $url, filename: $filename, headers: $headers, directory: $directory, baseDirectory: $baseDirectory, group: $group, progressUpdates: $progressUpdates, requiresWiFi: $requiresWiFi, retries: $retries, retriesRemaining: $retriesRemaining, metaData: $metaData}';
  }
}

/// Return fully encoded url String composed of the [url] and the
/// [urlQueryParameters], if given
///
/// Note the assumption is that the original [url] is not encoded
String _urlWithQueryParameters(
    String url, Map<String, String>? urlQueryParameters) {
  if (urlQueryParameters == null || urlQueryParameters.isEmpty) {
    return Uri.encodeFull(url);
  }
  final separator = url.contains('?') ? '&' : '?';
  return Uri.encodeFull(
      '$url$separator${urlQueryParameters.entries.map((e) => '${e.key}=${e.value}').join('&')}');
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
/// [DownloadTaskStatus.waitingToRetry] results in progress -4.0
class BackgroundDownloadProgressEvent extends BackgroundDownloadEvent {
  final double progress;

  BackgroundDownloadProgressEvent(super.task, this.progress);
}

// Progress values representing a status
const progressComplete = 1.0;
const progressFailed = -1.0;
const progressCanceled = -2.0;
const progressNotFound = -3.0;
const progressWaitingToRetry = -4.0;
