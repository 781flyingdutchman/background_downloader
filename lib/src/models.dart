import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'desktop_downloader.dart';
import 'exceptions.dart';
import 'file_downloader.dart';

final _log = Logger('FileDownloader');

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

  /// Task has failed due to an exception
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
  waitingToRetry,

  /// Task is in paused state and may be able to resume
  ///
  /// To resume a paused Task, call [resumeTaskWithId]. If the resume is
  /// possible, status will change to [TaskStatus.running] and continue from
  /// there. If resume fails (e.g. because the temp file with the partial
  /// download has been deleted by the operating system) status will switch
  /// to [TaskStatus.failed]
  paused;

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
      case TaskStatus.paused:
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

  /// As returned by getApplicationSupportDirectory()
  applicationSupport,

  /// As returned by getApplicationLibrary() on iOS. For other platforms
  /// this resolves to the subdirectory 'Library' created in the directory
  /// returned by getApplicationSupportDirectory()
  applicationLibrary
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
/// when the status of a [task] changes.
typedef TaskStatusCallback = void Function(TaskStatusUpdate update);

/// Signature for a function you can register to be called
/// for every progress change of a [task].
///
/// A successfully completed task will always finish with progress 1.0
/// [TaskStatus.failed] results in progress -1.0
/// [TaskStatus.canceled] results in progress -2.0
/// [TaskStatus.notFound] results in progress -3.0
/// [TaskStatus.waitingToRetry] results in progress -4.0
/// These constants are available as [progressFailed] etc
typedef TaskProgressCallback = void Function(TaskProgressUpdate update);

/// Signature for function you can register to be called when a notification
/// is tapped by the user
typedef TaskNotificationTapCallback = void Function(
    Task task, NotificationType notificationType);

/// A server Request
///
/// An equality test on a [Request] is an equality test on the [url]
base class Request {
  final validHttpMethods = ['GET', 'POST', 'HEAD', 'PUT', 'DELETE', 'PATCH'];

  /// String representation of the url, urlEncoded
  final String url;

  /// potential additional headers to send with the request
  final Map<String, String> headers;

  /// HTTP request method to use
  final String httpRequestMethod;

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

  /// Time at which this request was first created
  final DateTime creationTime;

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
      String? httpRequestMethod,
      post,
      this.retries = 0,
      DateTime? creationTime})
      : url = _urlWithQueryParameters(url, urlQueryParameters),
        httpRequestMethod =
            httpRequestMethod?.toUpperCase() ?? (post == null ? 'GET' : 'POST'),
        post = post is Uint8List ? String.fromCharCodes(post) : post,
        retriesRemaining = retries,
        creationTime = creationTime ?? DateTime.now() {
    if (retries < 0 || retries > 10) {
      throw ArgumentError('Number of retries must be in range 1 through 10');
    }
    if (!validHttpMethods.contains(this.httpRequestMethod)) {
      throw ArgumentError(
          'Invalid httpRequestMethod "${this.httpRequestMethod}": Must be one of ${validHttpMethods.join(', ')}');
    }
  }

  /// Creates object from JsonMap
  Request.fromJsonMap(Map<String, dynamic> jsonMap)
      : url = jsonMap['url'] ?? '',
        headers = Map<String, String>.from(jsonMap['headers'] ?? {}),
        httpRequestMethod = jsonMap['httpRequestMethod'] as String? ??
            (jsonMap['post'] == null ? 'GET' : 'POST'),
        post = jsonMap['post'] as String?,
        retries = (jsonMap['retries'] as num?)?.toInt() ?? 0,
        retriesRemaining = (jsonMap['retriesRemaining'] as num?)?.toInt() ?? 0,
        creationTime = DateTime.fromMillisecondsSinceEpoch(
            (jsonMap['creationTime'] as num?)?.toInt() ?? 0);

  /// Creates JSON map of this object
  Map<String, dynamic> toJsonMap() => {
        'url': url,
        'headers': headers,
        'httpRequestMethod': httpRequestMethod,
        'post': post,
        'retries': retries,
        'retriesRemaining': retriesRemaining,
        'creationTime': creationTime.millisecondsSinceEpoch
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
    return 'Request{url: $url, headers: $headers, httpRequestMethod: '
        '$httpRequestMethod, post: ${post == null ? "null" : "not null"}, '
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
sealed class Task extends Request {
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

  /// If true, task will pause if the task fails partly through the execution,
  /// when some but not all bytes have transferred, provided the server supports
  /// partial transfers. Such failures are typically temporary, eg due to
  /// connectivity issues, and may be resumed when connectivity returns.
  /// If false, task fails on any issue, and task cannot be paused
  final bool allowPause;

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
  /// [httpRequestMethod] the HTTP request method used (e.g. GET, POST)
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
  /// [allowPause]
  /// If true, task will pause if the task fails partly through the execution,
  /// when some but not all bytes have transferred, provided the server supports
  /// partial transfers. Such failures are typically temporary, eg due to
  /// connectivity issues, and may be resumed when connectivity returns
  /// [metaData] user data
  /// [creationTime] time of task creation, 'now' by default.
  Task(
      {String? taskId,
      required super.url,
      super.urlQueryParameters,
      String? filename,
      super.headers,
      super.httpRequestMethod,
      super.post,
      this.directory = '',
      this.baseDirectory = BaseDirectory.applicationDocuments,
      this.group = 'default',
      this.updates = Updates.status,
      this.requiresWiFi = false,
      super.retries,
      this.metaData = '',
      this.allowPause = false,
      super.creationTime})
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
    if (allowPause && post != null) {
      throw ArgumentError('Tasks that can pause must be GET requests');
    }
  }

  /// Create a new [Task] subclass from the provided [jsonMap]
  factory Task.createFromJsonMap(Map<String, dynamic> jsonMap) =>
      jsonMap['taskType'] == 'UploadTask'
          ? UploadTask.fromJsonMap(jsonMap)
          : DownloadTask.fromJsonMap(jsonMap);

  /// Returns the absolute path to the file represented by this task
  Future<String> filePath() async {
    final Directory baseDir = await switch (baseDirectory) {
      BaseDirectory.applicationDocuments => getApplicationDocumentsDirectory(),
      BaseDirectory.temporary => getTemporaryDirectory(),
      BaseDirectory.applicationSupport => getApplicationSupportDirectory(),
      BaseDirectory.applicationLibrary
          when Platform.isMacOS || Platform.isIOS =>
        getLibraryDirectory(),
      BaseDirectory.applicationLibrary => Future.value(Directory(
          path.join((await getApplicationSupportDirectory()).path, 'Library')))
    };
    return path.join(baseDir.path, directory, filename);
  }

  /// Returns a copy of the [Task] with optional changes to specific fields
  Task copyWith(
      {String? taskId,
      String? url,
      String? filename,
      Map<String, String>? headers,
      String? httpRequestMethod,
      Object? post,
      String? directory,
      BaseDirectory? baseDirectory,
      String? group,
      Updates? updates,
      bool? requiresWiFi,
      int? retries,
      int? retriesRemaining,
      bool? allowPause,
      String? metaData,
      DateTime? creationTime});

  /// Creates [Task] object from JsonMap
  ///
  /// Only used by subclasses. Use [createFromJsonMap] to create a properly
  /// subclassed [Task] from the [jsonMap]
  Task.fromJsonMap(Map<String, dynamic> jsonMap)
      : taskId = jsonMap['taskId'] ?? '',
        filename = jsonMap['filename'] ?? '',
        directory = jsonMap['directory'] ?? '',
        baseDirectory = BaseDirectory
            .values[(jsonMap['baseDirectory'] as num?)?.toInt() ?? 0],
        group = jsonMap['group'] ?? FileDownloader.defaultGroup,
        updates = Updates.values[(jsonMap['updates'] as num?)?.toInt() ?? 0],
        requiresWiFi = jsonMap['requiresWiFi'] ?? false,
        allowPause = jsonMap['allowPause'] ?? false,
        metaData = jsonMap['metaData'] ?? '',
        super.fromJsonMap(jsonMap);

  /// Creates JSON map of this object
  @override
  Map<String, dynamic> toJsonMap() => {
        ...super.toJsonMap(),
        'taskId': taskId,
        'filename': filename,
        'directory': directory,
        'baseDirectory': baseDirectory.index, // stored as int
        'group': group,
        'updates': updates.index, // stored as int
        'requiresWiFi': requiresWiFi,
        'allowPause': allowPause,
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
    return 'Task{taskId: $taskId, url: $url, filename: $filename, headers: '
        '$headers, httpRequestMethod: $httpRequestMethod, post: ${post == null ? "null" : "not null"}, directory: $directory, baseDirectory: $baseDirectory, group: $group, updates: $updates, requiresWiFi: $requiresWiFi, retries: $retries, retriesRemaining: $retriesRemaining, metaData: $metaData}';
  }
}

/// Information related to a download task
final class DownloadTask extends Task {
  /// Creates a [DownloadTask]
  ///
  /// [taskId] must be unique. A unique id will be generated if omitted
  /// [url] properly encoded if necessary, can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url], must
  ///   be properly encoded if necessary
  /// [filename] of the file to save. If omitted, a random filename will be
  /// generated
  /// [headers] an optional map of HTTP request headers
  /// [httpRequestMethod] the HTTP request method used (e.g. GET, POST)
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
      super.httpRequestMethod,
      super.post,
      super.directory,
      super.baseDirectory,
      super.group,
      super.updates,
      super.requiresWiFi,
      super.retries,
      super.allowPause,
      super.metaData,
      super.creationTime})
      : super(taskId: taskId, filename: filename);

  /// Creates [DownloadTask] object from JsonMap
  DownloadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : assert(
            jsonMap['taskType'] == 'DownloadTask',
            'The provided JSON map is not'
            ' a DownloadTask, because key "taskType" is not "DownloadTask".'),
        super.fromJsonMap(jsonMap);

  @override
  Map<String, dynamic> toJsonMap() =>
      {...super.toJsonMap(), 'taskType': 'DownloadTask'};

  @override
  DownloadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          String? httpRequestMethod,
          Object? post,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          Updates? updates,
          bool? requiresWiFi,
          int? retries,
          int? retriesRemaining,
          bool? allowPause,
          String? metaData,
          DateTime? creationTime}) =>
      DownloadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          httpRequestMethod: httpRequestMethod ?? this.httpRequestMethod,
          post: post ?? this.post,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          updates: updates ?? this.updates,
          requiresWiFi: requiresWiFi ?? this.requiresWiFi,
          retries: retries ?? this.retries,
          allowPause: allowPause ?? this.allowPause,
          metaData: metaData ?? this.metaData,
          creationTime: creationTime ?? this.creationTime)
        ..retriesRemaining = retriesRemaining ?? this.retriesRemaining;

  /// Returns a copy of the task with the [Task.filename] property changed
  /// to the filename suggested by the server, or derived from the url, or
  /// unchanged.
  ///
  /// If [unique] is true, the filename is guaranteed not to already exist. This
  /// is accomplished by adding a suffix to the suggested filename with a number,
  /// e.g. "data (2).txt"
  ///
  /// The suggested filename is obtained by making a HEAD request to the url
  /// represented by the [DownloadTask], including urlQueryParameters and headers
  Future<DownloadTask> withSuggestedFilename({unique = false}) async {
    /// Returns [DownloadTask] with a filename similar to the one
    /// supplied, but unused.
    ///
    /// If [unique], filename will sequence up in "filename (8).txt" format,
    /// otherwise returns the [task]
    Future<DownloadTask> uniqueFilename(DownloadTask task, bool unique) async {
      if (!unique) {
        return task;
      }
      final sequenceRegEx = RegExp(r'\((\d+)\)\.?[^.]*$');
      final extensionRegEx = RegExp(r'\.[^.]*$');
      var newTask = task;
      var filePath = await newTask.filePath();
      var exists = await File(filePath).exists();
      while (exists) {
        final extension =
            extensionRegEx.firstMatch(newTask.filename)?.group(0) ?? '';
        final match = sequenceRegEx.firstMatch(newTask.filename);
        final newSequence = int.parse(match?.group(1) ?? "0") + 1;
        final newFilename = match == null
            ? '${path.basenameWithoutExtension(newTask.filename)} ($newSequence)$extension'
            : '${newTask.filename.substring(0, match.start - 1)} ($newSequence)$extension';
        newTask = newTask.copyWith(filename: newFilename);
        filePath = await newTask.filePath();
        exists = await File(filePath).exists();
      }
      return newTask;
    }

    try {
      final response = await DesktopDownloader.httpClient
          .head(Uri.parse(url), headers: headers);
      if ([200, 201, 202, 203, 204, 205, 206].contains(response.statusCode)) {
        final disposition = response.headers.entries
            .firstWhere(
                (element) => element.key.toLowerCase() == 'content-disposition')
            .value;
        // Try filename="filename"
        final plainFilenameRegEx =
            RegExp(r'filename="?([^"]+)"?.*$', caseSensitive: false);
        var match = plainFilenameRegEx.firstMatch(disposition);
        if (match != null && match.group(1)?.isNotEmpty == true) {
          return uniqueFilename(copyWith(filename: match.group(1)), unique);
        }
        // Try filename*=UTF-8'language'"encodedFilename"
        final encodedFilenameRegEx = RegExp(
            'filename\\*=([^\']+)\'([^\']*)\'"?([^"]+)"?',
            caseSensitive: false);
        match = encodedFilenameRegEx.firstMatch(disposition);
        if (match != null &&
            match.group(1)?.isNotEmpty == true &&
            match.group(3)?.isNotEmpty == true) {
          try {
            final suggestedFilename = match.group(1) == 'UTF-8'
                ? Uri.decodeComponent(match.group(3)!)
                : match.group(3)!;
            return uniqueFilename(copyWith(filename: suggestedFilename), true);
          } on ArgumentError {
            _log.finer(
                'Could not interpret suggested filename (UTF-8 url encoded) ${match.group(3)}');
          }
        }
      }
    } catch (e) {
      _log.finer('Could not determine suggested filename from server');
    }
    // Try filename derived from last path segment of the url
    try {
      final suggestedFilename = Uri.parse(url).pathSegments.last;
      return uniqueFilename(copyWith(filename: suggestedFilename), unique);
    } catch (e) {
      _log.finer('Could not parse URL pathSegment for suggested filename: $e');
    }
    // if everything fails, return the task with unchanged filename
    // except for possibly making it unique
    return uniqueFilename(this, unique);
  }

  /// Return the expected file size for this task, or -1 if unknown
  ///
  /// The expected file size is obtained by making a HEAD request to the url
  /// represented by the [DownloadTask], including urlQueryParameters and headers
  Future<int> expectedFileSize() async {
    try {
      final response = await DesktopDownloader.httpClient
          .head(Uri.parse(url), headers: headers);
      if ([200, 201, 202, 203, 204, 205, 206].contains(response.statusCode)) {
        return int.parse(response.headers.entries
            .firstWhere(
                (element) => element.key.toLowerCase() == 'content-length')
            .value);
      }
    } catch (e) {
      // no content length available
    }
    return -1;
  }

  @override
  String toString() => 'Download${super.toString()}';
}

/// Information related to an upload task
///
/// An equality test on a [UploadTask] is a test on the [taskId]
/// only - all other fields are ignored in that test
final class UploadTask extends Task {
  /// Name of the field used for multi-part file upload
  final String fileField;

  /// mimeType of the file to upload
  final String mimeType;

  /// Map of name/value pairs to encode as form fields in a multi-part upload
  final Map<String, String> fields;

  /// Creates [UploadTask]
  ///
  /// [taskId] must be unique. A unique id will be generated if omitted
  /// [url] properly encoded if necessary, can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url], must
  ///   be properly encoded if necessary
  /// [filename] of the file to upload
  /// [headers] an optional map of HTTP request headers
  /// [httpRequestMethod] the HTTP request method used (e.g. GET, POST)
  /// [post] if set to 'binary' will upload as binary file, otherwise multi-part
  /// [fileField] for multi-part uploads, name of the file field or 'file' by
  /// default
  /// [mimeType] the mimeType of the file, or derived from filename extension
  /// by default
  /// [fields] for multi-part uploads, optional map of name/value pairs to upload
  ///   along with the file as form fields
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
      String? httpRequestMethod,
      String? post,
      this.fileField = 'file',
      String? mimeType,
      Map<String, String>? fields,
      super.directory,
      super.baseDirectory,
      super.group,
      super.updates,
      super.requiresWiFi,
      super.retries,
      super.allowPause,
      super.metaData,
      super.creationTime})
      : assert(filename.isNotEmpty, 'A filename is required'),
        assert(post == null || post == 'binary',
            'post field must be null, or "binary" for binary file upload'),
        assert(fields == null || fields.isEmpty || post != 'binary',
            'fields only allowed for multi-part uploads'),
        fields = fields ?? {},
        mimeType =
            mimeType ?? lookupMimeType(filename) ?? 'application/octet-stream',
        super(
            taskId: taskId,
            filename: filename,
            httpRequestMethod: httpRequestMethod ?? 'POST',
            post: post) {
    if (allowPause) {
      throw ArgumentError('Uploads cannot be paused-> Set `allowPause` to '
          'false');
    }
  }

  /// Creates [UploadTask] object from JsonMap
  UploadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : assert(
            jsonMap['taskType'] == 'UploadTask',
            'The provided JSON map is not'
            ' an UploadTask, because key "taskType" is not "UploadTask".'),
        fileField = jsonMap['fileField'] ?? 'file',
        mimeType = jsonMap['mimeType'] ?? 'application/octet-stream',
        fields = Map<String, String>.from(jsonMap['fields'] ?? {}),
        super.fromJsonMap(jsonMap);

  @override
  Map<String, dynamic> toJsonMap() => {
        ...super.toJsonMap(),
        'fileField': fileField,
        'mimeType': mimeType,
        'fields': fields,
        'taskType': 'UploadTask'
      };

  @override
  UploadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          String? httpRequestMethod,
          Object? post,
          String? fileField,
          String? mimeType,
          Map<String, String>? fields,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          Updates? updates,
          bool? requiresWiFi,
          int? retries,
          int? retriesRemaining,
          bool? allowPause,
          String? metaData,
          DateTime? creationTime}) =>
      UploadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          httpRequestMethod: httpRequestMethod ?? this.httpRequestMethod,
          post: post as String? ?? this.post,
          fileField: fileField ?? this.fileField,
          mimeType: mimeType ?? this.mimeType,
          fields: fields ?? this.fields,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          updates: updates ?? this.updates,
          requiresWiFi: requiresWiFi ?? this.requiresWiFi,
          retries: retries ?? this.retries,
          allowPause: allowPause ?? this.allowPause,
          metaData: metaData ?? this.metaData,
          creationTime: creationTime ?? this.creationTime)
        ..retriesRemaining = retriesRemaining ?? this.retriesRemaining;

  @override
  String toString() => 'Upload${super.toString()} and fileField $fileField, '
      'mimeType $mimeType and fields $fields';
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

/// Base class for updates related to [task]. Actual updates are
/// either a status update or a progress update.
///
/// When receiving an update, test if the update is a
/// [TaskStatusUpdate] or a [TaskProgressUpdate]
/// and treat the update accordingly
sealed class TaskUpdate {
  final Task task;

  const TaskUpdate(this.task);

  /// Create object from JSON Map
  TaskUpdate.fromJsonMap(Map<String, dynamic> jsonMap)
      : task = Task.createFromJsonMap(jsonMap);

  /// Return JSON Map representing object
  Map<String, dynamic> toJsonMap() => task.toJsonMap();
}

/// A status update
///
/// Contains [TaskStatus] and, if [TaskStatus.failed] possibly a
/// [TaskException]
class TaskStatusUpdate extends TaskUpdate {
  final TaskStatus status;
  final TaskException? exception;

  const TaskStatusUpdate(super.task, this.status, [this.exception]);

  /// Create object from JSON Map
  TaskStatusUpdate.fromJsonMap(Map<String, dynamic> jsonMap)
      : status =
            TaskStatus.values[(jsonMap['taskStatus'] as num?)?.toInt() ?? 0],
        exception = jsonMap['exception'] != null
            ? TaskException.fromJsonMap(jsonMap['exception'])
            : null,
        super.fromJsonMap(jsonMap);

  /// Return JSON Map representing object
  @override
  Map<String, dynamic> toJsonMap() => {
        ...super.toJsonMap(),
        'taskStatus': status.index,
        'exception': exception?.toJsonMap()
      };
}

/// A progress update
///
/// A successfully downloaded task will always finish with progress 1.0
///
/// [TaskStatus.failed] results in progress -1.0
/// [TaskStatus.canceled] results in progress -2.0
/// [TaskStatus.notFound] results in progress -3.0
/// [TaskStatus.waitingToRetry] results in progress -4.0
///
/// [expectedFileSize] will only be representative if the 0 < [progress] < 1,
/// so NOT representative when progress == 0 or progress == 1, and
/// will be -1 if the file size is not provided by the server or otherwise
/// not known.
class TaskProgressUpdate extends TaskUpdate {
  final double progress;
  final int expectedFileSize;

  const TaskProgressUpdate(super.task, this.progress,
      [this.expectedFileSize = -1]);

  /// Create object from JSON Map
  TaskProgressUpdate.fromJsonMap(Map<String, dynamic> jsonMap)
      : progress = (jsonMap['progress'] as num?)?.toDouble() ?? progressFailed,
        expectedFileSize = (jsonMap['expectedFileSize'] as num?)?.toInt() ?? -1,
        super.fromJsonMap(jsonMap);

  /// Return JSON Map representing object
  @override
  Map<String, dynamic> toJsonMap() => {
        ...super.toJsonMap(),
        'progress': progress,
        'expectedFileSize': expectedFileSize
      };
}

// Progress values representing a status
const progressComplete = 1.0;
const progressFailed = -1.0;
const progressCanceled = -2.0;
const progressNotFound = -3.0;
const progressWaitingToRetry = -4.0;
const progressPaused = -5.0;

/// Holds data associated with a resume
class ResumeData {
  final Task task;
  final String data;
  final int requiredStartByte;

  const ResumeData(this.task, this.data, this.requiredStartByte);

  /// Create object from JSON Map
  ResumeData.fromJsonMap(Map<String, dynamic> jsonMap)
      : task = Task.createFromJsonMap(jsonMap['task']),
        data = jsonMap['data'] as String,
        requiredStartByte =
            (jsonMap['requiredStartByte'] as num?)?.toInt() ?? 0;

  /// Return JSON Map representing object
  Map<String, dynamic> toJsonMap() => {
        'task': task.toJsonMap(),
        'data': data,
        'requiredStartByte': requiredStartByte
      };

  String get taskId => task.taskId;
}

/// Types of undelivered data that can be requested
enum Undelivered { resumeData, statusUpdates, progressUpdates }

/// Notification types, as configured in [TaskNotificationConfig] and passed
/// on to [TaskNotificationTapCallback]
enum NotificationType { running, complete, error, paused }

/// Notification specification for a [Task]
///
/// [body] may contain special string {filename] to insert the filename
///   and/or special string {progress} to insert progress in %
///   and/or special trailing string {progressBar} to add a progress bar under
///   the body text in the notification
///
/// Actual appearance of notification is dependent on the platform, e.g.
/// on iOS {progress} and {progressBar} are not available and ignored
final class TaskNotification {
  final String title;
  final String body;

  const TaskNotification(this.title, this.body);

  /// Return JSON Map representing object
  Map<String, dynamic> toJsonMap() => {"title": title, "body": body};
}

/// Notification configuration object
///
/// Determines how a [taskOrGroup] or [group] of tasks needs to be notified
///
/// [running] is the notification used while the task is in progress
/// [complete] is the notification used when the task completed
/// [error] is the notification used when something went wrong,
/// including pause, failed and notFound status
final class TaskNotificationConfig {
  final dynamic taskOrGroup;
  final TaskNotification? running;
  final TaskNotification? complete;
  final TaskNotification? error;
  final TaskNotification? paused;
  final bool progressBar;
  final bool tapOpensFile;

  TaskNotificationConfig(
      {this.taskOrGroup,
      this.running,
      this.complete,
      this.error,
      this.paused,
      this.progressBar = false,
      this.tapOpensFile = false}) {
    assert(
        running != null || complete != null || error != null || paused != null,
        'At least one notification must be set');
  }

  /// Return JSON Map representing object, excluding the [taskOrGroup] field,
  /// as the JSON map is only required to pass along the config with a task
  Map<String, dynamic> toJsonMap() => {
        'running': running?.toJsonMap(),
        'complete': complete?.toJsonMap(),
        'error': error?.toJsonMap(),
        'paused': paused?.toJsonMap(),
        'progressBar': progressBar,
        'tapOpensFile': tapOpensFile
      };
}

/// Shared storage destinations
enum SharedStorage {
  /// The 'Downloads' directory
  downloads,

  /// The 'Photos' or 'Images' or 'Pictures' directory
  images,

  /// The 'Videos' or 'Movies' directory
  video,

  /// The 'Music' or 'Audio' directory
  audio,

  /// Android-only: the 'Files' directory
  files,

  /// Android-only: the 'external storage' directory
  external
}
