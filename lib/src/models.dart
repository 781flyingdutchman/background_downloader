import 'dart:math';
import 'dart:typed_data';

/// Defines a set of possible states which a [Task] can be in.
enum TaskStatus {
  /// Task is enqueued on the native platform and waiting to start
  ///
  /// It may wait for resources, or for an appropriate network to become
  /// available before starting the actual download and changing state to
  /// `running`.
  enqueued,

  /// Task is running, i.e. actively downloading
  running,

  /// Task has completed successfully
  ///
  /// This is a final state
  complete,

  /// Task has completed because the url was not found (Http status code 404)
  ///
  /// This is a final state
  notFound,

  /// Task has failed due to an error
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
      case TaskStatus.complete:
      case TaskStatus.notFound:
      case TaskStatus.failed:
      case TaskStatus.canceled:
        return true;

      case TaskStatus.enqueued:
      case TaskStatus.running:
      case TaskStatus.waitingToRetry:
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

/// Type of updates requested for a task or group of tasks
enum Updates {
  /// no status change or progress updates
  none,

  /// only status changes
  status,

  /// only progress updates while downloading, no status change updates
  progress,

  /// Status change updates and progress updates while downloading
  statusAndProgress,
}

/// Signature for a function you can register to be called
/// when the state of a [task] changes.
typedef TaskStatusCallback = void Function(Task task, TaskStatus status);

/// Signature for a function you can register to be called
/// for every progress change of a [task].
///
/// A successfully completed task will always finish with progress 1.0
/// [TaskStatus.failed] results in progress -1.0
/// [TaskStatus.canceled] results in progress -2.0
/// [TaskStatus.notFound] results in progress -3.0
/// [TaskStatus.waitingToRetry] results in progress -4.0
/// These constants are available as [progressFailed] etc
typedef TaskProgressCallback = void Function(Task task, double progress);

/// A server Request
///
/// An equality test on a [Request] is an equality test on the [url]
class Request {
  /// String representation of the url, urlEncoded
  final String url;

  /// potential additional headers to send with the request
  final Map<String, String> headers;

  /// Set [post] to make the request using POST instead of GET.
  /// In the constructor, [post] must be one of the following:
  /// - a String: POST request with [post] as the body, encoded in utf8
  /// - a List of bytes: POST request with [post] as the body
  ///
  /// The field [post] will be a UInt8List representing the bytes, or the String
  final String? post;

  /// Maximum number of retries the downloader should attempt
  ///
  /// Defaults to 0, meaning no retry will be attempted
  final int retries;

  /// Number of retries remaining
  int retriesRemaining;

  /// Creates a [Request]
  ///
  /// [url] must not be encoded and can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url]
  /// [headers] an optional map of HTTP request headers
  /// [post] if set, uses POST instead of GET. Post must be one of the
  /// following:
  /// - a String: POST request with [post] as the body, encoded in utf8
  /// - a List of bytes: POST request with [post] as the body
  ///
  /// [retries] if >0 will retry a failed download this many times
  Request(
      {required String url,
      Map<String, String>? urlQueryParameters,
      this.headers = const {},
      post,
      this.retries = 0})
      : retriesRemaining = retries,
        url = _urlWithQueryParameters(url, urlQueryParameters),
        post = post is Uint8List ? String.fromCharCodes(post) : post {
    if (retries < 0 || retries > 10) {
      throw ArgumentError('Number of retries must be in range 1 through 10');
    }
  }

  /// Creates object from JsonMap
  Request.fromJsonMap(Map<String, dynamic> jsonMap)
      : url = jsonMap['url'],
        headers = Map<String, String>.from(jsonMap['headers']),
        post = jsonMap['post'],
        retries = jsonMap['retries'],
        retriesRemaining = jsonMap['retriesRemaining'];

  /// Creates JSON map of this object
  Map toJsonMap() => {
        'url': url,
        'headers': headers,
        'post': post,
        'retries': retries,
        'retriesRemaining': retriesRemaining,
      };

  /// Decrease [retriesRemaining] by one
  void decreaseRetriesRemaining() => retriesRemaining--;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Request && runtimeType == other.runtimeType && url == other.url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() {
    return 'Request{url: $url, headers: $headers, post: ${post == null ? "null" : "not null"}, '
        'retries: $retries, retriesRemaining: $retriesRemaining}';
  }
}

/// RegEx to match a path separator
final _pathSeparator = RegExp(r'[/\\]');
final _startsWithPathSeparator = RegExp(r'^[/\\]');


/// Information related to a [Task]
///
/// A [Task] is the base class for [DownloadTask] and
/// [UploadTask]
///
/// An equality test on a [Task] is a test on the [taskId]
/// only - all other fields are ignored in that test
abstract class Task extends Request {
  /// Identifier for the task - auto generated if omitted
  final String taskId;

  /// Filename of the file to store
  final String filename;

  /// Optional directory, relative to the base directory
  final String directory;

  /// Base directory
  final BaseDirectory baseDirectory;

  /// Group that this task belongs to
  final String group;

  /// Type of progress updates desired
  final Updates updates;

  /// If true, will not download over cellular (metered) network
  final bool requiresWiFi;

  /// User-defined metadata
  final String metaData;

  /// Creates a [Task]
  ///
  /// [taskId] must be unique. A unique id will be generated if omitted
  /// [url] properly encoded if necessary, can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url], must
  ///   be properly encoded if necessary
  /// [filename] of the file to save. If omitted, a random filename will be
  /// generated
  /// [headers] an optional map of HTTP request headers
  /// [post] if set, uses POST instead of GET. Post must be one of the
  /// following:
  /// - a String: POST request with [post] as the body, encoded in utf8
  /// - a List of bytes: POST request with [post] as the body
  /// [directory] optional directory name, precedes [filename]
  /// [baseDirectory] one of the base directories, precedes [directory]
  /// [group] if set allows different callbacks or processing for different
  /// groups
  /// [updates] the kind of progress updates requested
  /// [requiresWiFi] if set, will not start download until WiFi is available.
  /// If not set may start download over cellular network
  /// [retries] if >0 will retry a failed download this many times
  /// [metaData] user data
  Task(
      {String? taskId,
      required super.url,
      super.urlQueryParameters,
      String? filename,
      super.headers,
      super.post,
      this.directory = '',
      this.baseDirectory = BaseDirectory.applicationDocuments,
      this.group = 'default',
      this.updates = Updates.status,
      this.requiresWiFi = false,
      super.retries,
      this.metaData = ''})
      : taskId = taskId ?? Random().nextInt(1 << 32).toString(),
        filename = filename ?? Random().nextInt(1 << 32).toString() {
    if (filename?.isEmpty == true) {
      throw ArgumentError('Filename cannot be empty');
    }
    if (_pathSeparator.hasMatch(this.filename)) {
      throw ArgumentError('Filename cannot contain path separators');
    }
    if (_startsWithPathSeparator.hasMatch(directory)) {
      throw ArgumentError(
          'Directory must be relative to the baseDirectory specified in the baseDirectory argument');
    }
  }

  /// Create a new [Task] subclass from the provided [jsonMap]
  factory Task.createFromJsonMap(Map<String, dynamic> jsonMap) =>
      jsonMap['taskType'] == 'UploadTask'
          ? UploadTask.fromJsonMap(jsonMap)
          : DownloadTask.fromJsonMap(jsonMap);

  /// Returns a copy of the [Task] with optional changes to specific fields
  Task copyWith(
      {String? taskId,
      String? url,
      String? filename,
      Map<String, String>? headers,
      Object? post,
      String? directory,
      BaseDirectory? baseDirectory,
      String? group,
      Updates? updates,
      bool? requiresWiFi,
      int? retries,
      int? retriesRemaining,
      String? metaData});

  /// Creates [Task] object from JsonMap
  ///
  /// Only used by subclasses. Use [createFromJsonMap] to create a properly
  /// subclassed [Task] from the [jsonMap]
  Task.fromJsonMap(Map<String, dynamic> jsonMap)
      : taskId = jsonMap['taskId'],
        filename = jsonMap['filename'],
        directory = jsonMap['directory'],
        baseDirectory = BaseDirectory.values[jsonMap['baseDirectory']],
        group = jsonMap['group'],
        updates = Updates.values[jsonMap['updates']],
        requiresWiFi = jsonMap['requiresWiFi'],
        metaData = jsonMap['metaData'],
        super.fromJsonMap(jsonMap);

  /// Creates JSON map of this object
  @override
  Map toJsonMap() => {
        ...super.toJsonMap(),
        'taskId': taskId,
        'filename': filename,
        'directory': directory,
        'baseDirectory': baseDirectory.index, // stored as int
        'group': group,
        'updates': updates.index, // stored as int
        'requiresWiFi': requiresWiFi,
        'metaData': metaData
      };

  /// If true, task expects progress updates
  bool get providesProgressUpdates =>
      updates == Updates.progress || updates == Updates.statusAndProgress;

  /// If true, task expects status updates
  bool get providesStatusUpdates =>
      updates == Updates.status || updates == Updates.statusAndProgress;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Task &&
          runtimeType == other.runtimeType &&
          taskId == other.taskId;

  @override
  int get hashCode => taskId.hashCode;

  @override
  String toString() {
    return 'Task{taskId: $taskId, url: $url, filename: $filename, headers: $headers, post: ${post == null ? "null" : "not null"}, directory: $directory, baseDirectory: $baseDirectory, group: $group, updates: $updates, requiresWiFi: $requiresWiFi, retries: $retries, retriesRemaining: $retriesRemaining, metaData: $metaData}';
  }
}

class DownloadTask extends Task {
  /// Creates a [DownloadTask]
  ///
  /// [taskId] must be unique. A unique id will be generated if omitted
  /// [url] properly encoded if necessary, can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url], must
  ///   be properly encoded if necessary
  /// [filename] of the file to save. If omitted, a random filename will be
  /// generated
  /// [headers] an optional map of HTTP request headers
  /// [post] if set, uses POST instead of GET. Post must be one of the
  /// following:
  /// - true: POST request without a body
  /// - a String: POST request with [post] as the body, encoded in utf8 and
  ///   content-type 'text/plain'
  /// - a List of bytes: POST request with [post] as the body
  /// - a Map: POST request with [post] as form fields, encoded in utf8 and
  ///   content-type 'application/x-www-form-urlencoded'
  ///
  /// [directory] optional directory name, precedes [filename]
  /// [baseDirectory] one of the base directories, precedes [directory]
  /// [group] if set allows different callbacks or processing for different
  /// groups
  /// [updates] the kind of progress updates requested
  /// [requiresWiFi] if set, will not start download until WiFi is available.
  /// If not set may start download over cellular network
  /// [retries] if >0 will retry a failed download this many times
  /// [metaData] user data
  DownloadTask(
      {String? taskId,
      required super.url,
      super.urlQueryParameters,
      String? filename,
      super.headers,
      super.post,
      super.directory,
      super.baseDirectory,
      super.group,
      super.updates,
      super.requiresWiFi,
      super.retries,
      super.metaData})
      : super(taskId: taskId, filename: filename);

  /// Creates [DownloadTask] object from JsonMap
  DownloadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : assert(
            jsonMap['taskType'] == 'DownloadTask',
            'The provided JSON map is not'
            ' a DownloadTask, because key "taskType" is not "DownloadTask".'),
        super.fromJsonMap(jsonMap);

  @override
  Map toJsonMap() => {...super.toJsonMap(), 'taskType': 'DownloadTask'};

  @override
  DownloadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          Object? post,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          Updates? updates,
          bool? requiresWiFi,
          int? retries,
          int? retriesRemaining,
          String? metaData}) =>
      DownloadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          post: post ?? this.post,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          updates: updates ?? this.updates,
          requiresWiFi: requiresWiFi ?? this.requiresWiFi,
          retries: retries ?? this.retries,
          metaData: metaData ?? this.metaData)
        ..retriesRemaining = retriesRemaining ?? this.retriesRemaining;

  @override
  String toString() => 'Download${super.toString()}';
}

/// Information related to an upload task
///
/// An equality test on a [UploadTask] is a test on the [taskId]
/// only - all other fields are ignored in that test
class UploadTask extends Task {
  /// Creates [UploadTask]
  ///
  /// [taskId] must be unique. A unique id will be generated if omitted
  /// [url] properly encoded if necessary, can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url], must
  ///   be properly encoded if necessary
  /// [filename] of the file to upload
  /// [headers] an optional map of HTTP request headers
  /// [directory] optional directory name, precedes [filename]
  /// [baseDirectory] one of the base directories, precedes [directory]
  /// [group] if set allows different callbacks or processing for different
  /// groups
  /// [updates] the kind of progress updates requested
  /// [requiresWiFi] if set, will not start upload until WiFi is available.
  /// If not set may start upload over cellular network
  /// [retries] if >0 will retry a failed upload this many times
  /// [metaData] user data
  UploadTask(
      {String? taskId,
      required super.url,
      super.urlQueryParameters,
      required String filename,
      super.headers,
      String? post,
      super.directory,
      super.baseDirectory,
      super.group,
      super.updates,
      super.requiresWiFi,
      super.retries,
      super.metaData})
      : assert(filename.isNotEmpty, 'A filename is required'),
        assert(post == null || post == 'binary',
            'post field must be null, or "binary" for binary file upload'),
        super(taskId: taskId, filename: filename, post: post);

  /// Creates [UploadTask] object from JsonMap
  UploadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : assert(
            jsonMap['taskType'] == 'UploadTask',
            'The provided JSON map is not'
            ' an UploadTask, because key "taskType" is not "UploadTask".'),
        super.fromJsonMap(jsonMap);

  @override
  Map toJsonMap() => {...super.toJsonMap(), 'taskType': 'UploadTask'};

  @override
  UploadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          Object? post,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          Updates? updates,
          bool? requiresWiFi,
          int? retries,
          int? retriesRemaining,
          String? metaData}) =>
      UploadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          post: post as String? ?? this.post,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          updates: updates ?? this.updates,
          requiresWiFi: requiresWiFi ?? this.requiresWiFi,
          retries: retries ?? this.retries,
          metaData: metaData ?? this.metaData)
        ..retriesRemaining = retriesRemaining ?? this.retriesRemaining;

  @override
  String toString() => 'Upload${super.toString()}';
}

/// Return url String composed of the [url] and the
/// [urlQueryParameters], if given
String _urlWithQueryParameters(
    String url, Map<String, String>? urlQueryParameters) {
  if (urlQueryParameters == null || urlQueryParameters.isEmpty) {
    return url;
  }
  final separator = url.contains('?') ? '&' : '?';
  return '$url$separator${urlQueryParameters.entries.map((e) => '${e.key}=${e.value}').join('&')}';
}

/// Signature for a function you can provide to the [downloadBatch] or
/// [uploadBatch] that will be called upon completion of each task
/// in the batch.
///
/// [succeeded] will count the number of successful downloads, and
/// [failed] counts the number of failed downloads (for any reason).
typedef BatchProgressCallback = void Function(int succeeded, int failed);

/// Contains tasks and results related to a batch of tasks
class Batch {
  final List<Task> tasks;
  final BatchProgressCallback? batchProgressCallback;
  final results = <Task, TaskStatus>{};

  Batch(this.tasks, this.batchProgressCallback);

  /// Returns an Iterable with successful tasks in this batch
  Iterable<Task> get succeeded => results.entries
      .where((entry) => entry.value == TaskStatus.complete)
      .map((e) => e.key);

  /// Returns the number of successful tasks in this batch
  int get numSucceeded =>
      results.values.where((result) => result == TaskStatus.complete).length;

  /// Returns an Iterable with failed tasks in this batch
  Iterable<Task> get failed => results.entries
      .where((entry) => entry.value != TaskStatus.complete)
      .map((e) => e.key);

  /// Returns the number of failed downloads in this batch
  int get numFailed => results.values.length - numSucceeded;
}

/// Base class for events related to [task]. Actual events are
/// either a status update or a progress update.
///
/// When receiving an update, test if the update is a
/// [TaskStatusUpdate] or a [TaskProgressUpdate]
/// and treat the update accordingly
class TaskUpdate {
  final Task task;

  TaskUpdate(this.task);
}

/// A status update event
class TaskStatusUpdate extends TaskUpdate {
  final TaskStatus status;

  TaskStatusUpdate(super.task, this.status);
}

/// A progress update event
///
/// A successfully downloaded task will always finish with progress 1.0
/// [TaskStatus.failed] results in progress -1.0
/// [TaskStatus.canceled] results in progress -2.0
/// [TaskStatus.notFound] results in progress -3.0
/// [TaskStatus.waitingToRetry] results in progress -4.0
class TaskProgressUpdate extends TaskUpdate {
  final double progress;

  TaskProgressUpdate(super.task, this.progress);
}

// Progress values representing a status
const progressComplete = 1.0;
const progressFailed = -1.0;
const progressCanceled = -2.0;
const progressNotFound = -3.0;
const progressWaitingToRetry = -4.0;
