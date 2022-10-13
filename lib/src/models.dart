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
