import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

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
          taskId == other.taskId &&
          url == other.url &&
          filename == other.filename &&
          mapEquals(headers, other.headers) &&
          directory == other.directory &&
          baseDirectory == other.baseDirectory &&
          group == other.group &&
          progressUpdates == other.progressUpdates &&
          metaData == other.metaData;

  @override
  int get hashCode =>
      taskId.hashCode ^
      url.hashCode ^
      filename.hashCode ^
      headers.hashCode ^
      directory.hashCode ^
      baseDirectory.hashCode ^
      group.hashCode ^
      progressUpdates.hashCode ^
      metaData.hashCode;

  @override
  String toString() {
    return 'BackgroundDownloadTask{taskId: $taskId, url: $url, filename: $filename, headers: $headers, directory: $directory, baseDirectory: $baseDirectory, group: $group, progressUpdates: $progressUpdates, metaData: $metaData}';
  }
}

/// Event related to [task] is either a [DownloadTaskStatus] update or
/// a [double] progress update.
///
/// When receiving an event, test [isStatusUpdate] or [isProgressUpdate]
/// and treat the event accordingly.
class BackgroundDownloadEvent {
  final BackgroundDownloadTask task;
  // ignore: prefer_typing_uninitialized_variables
  final statusOrProgress;

  /// Create [BackgroundDownloadEvent]
  ///
  /// Parameter [statusOrProgress] must be a [DownloadTaskStatus] or [double]
  BackgroundDownloadEvent(this.task, this.statusOrProgress) {
    assert(statusOrProgress is DownloadTaskStatus || statusOrProgress is double);
  }

  /// True if this event is a status update.
  ///
  /// [statusOrProgress] is of type [DownloadTaskStatus]
  bool get isStatusUpdate => statusOrProgress is DownloadTaskStatus;

  /// True if this event is a progress update.
  ///
  /// [statusOrProgress] is of type [double]
  bool get isProgressUpdate => !isStatusUpdate;
}
