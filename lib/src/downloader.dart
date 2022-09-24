import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:file_downloader/file_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'models.dart';

/// Signature for a function you can register to be called
/// when the download state of a [task] changes.
typedef DownloadStatusCallback = void Function(
    BackgroundDownloadTask task, DownloadTaskStatus status);

/// Signature for a function you can register to be called
/// for every download progress change of a [task].
typedef DownloadProgressCallback = void Function(
    BackgroundDownloadTask task, double progress);

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static final log = Logger('FileDownloader');
  static const defaultGroup = 'default';
  static const _channel = MethodChannel('com.bbflight.file_downloader');
  static const _backgroundChannel =
  MethodChannel('com.bbflight.file_downloader.background');
  static bool _initialized = false;
  static final statusCallbacks = <String, DownloadStatusCallback>{};
  static final progressCallbacks = <String, DownloadProgressCallback>{};

  static bool get initialized => _initialized;

  /// Initialize the downloader and potentially register callbacks to
  /// handle status and progress updates
  static void initialize({String group = defaultGroup,
    DownloadStatusCallback? downloadStatusCallback,
    DownloadProgressCallback? downloadProgressCallback}) {
    WidgetsFlutterBinding.ensureInitialized();
    // Incoming calls from the native code will be on the backgroundChannel,
    // so this isolate listener moves it from background to foreground
    const portName = 'file_downloader_send_port';
    // create simple listener Isolate to receive download updates in the
    // main isolate
    final receivePort = ReceivePort();
    if (!IsolateNameServer.registerPortWithName(
        receivePort.sendPort, portName)) {
      IsolateNameServer.removePortNameMapping(portName);
      IsolateNameServer.registerPortWithName(receivePort.sendPort, portName);
    }
    receivePort.listen((dynamic data) {
      final taskAsJsonMapString = data[1] as String;
      final task =
      BackgroundDownloadTask.fromJsonMap(jsonDecode(taskAsJsonMapString));
      switch (data[0] as String) {
        case 'statusUpdate':
          final downloadStatusCallback = statusCallbacks[task.group];
          if (downloadStatusCallback != null) {
            var downloadTaskStatus = DownloadTaskStatus.values[data[2] as int];
            if (task.providesProgressUpdates) {
              // Send a 100% progress update for complete and not found,
              // and a -1 or -2 for failed and canceled
              // if those updates are requested
              final progressUpdateCallback = progressCallbacks[task.group];
              print('checking for progressupdateCallback');
              if (progressUpdateCallback != null) {
                print('found progressupdateCallback with status $downloadTaskStatus');
                switch (downloadTaskStatus) {

                  case DownloadTaskStatus.undefined:
                  case DownloadTaskStatus.enqueued:
                  case DownloadTaskStatus.running:
                    break;
                  case DownloadTaskStatus.complete:
                  case DownloadTaskStatus.notFound:
                  print('sending progressupdateCallback');
                    progressUpdateCallback(task, 1);
                    break;
                  case DownloadTaskStatus.failed:
                    progressUpdateCallback(task, -1);
                    break;
                  case DownloadTaskStatus.canceled:
                    progressUpdateCallback(task, -2);
                    break;
                }
              } else {
                log.warning(
                    'Requested progress updates for task ${task
                        .taskId} in group ${task
                        .group} but no progressUpdateCallback was registered');
              }
            }
            downloadStatusCallback(task, downloadTaskStatus);
          } else {
            if (task.progressUpdates != DownloadTaskProgressUpdates.none) {
              log.warning(
                  'Requested status updates for task ${task
                      .taskId} in group ${task
                      .group} but no downloadStatusCallback was registered');
            }
          }
          break;

        case 'progressUpdate':
          final progressUpdateCallback = progressCallbacks[task.group];
          if (progressUpdateCallback != null) {
            progressUpdateCallback(task, data[2] as double);
          } else {
            log.warning(
                'Requested progress updates for task ${task
                    .taskId} in group ${task
                    .group} but no progressUpdateCallback was registered');
          }
          break;

        default:
          throw UnimplementedError(
              'Isolate received call ${data[0]} which is not supported');
      }
    });
    // listen to the background channel and pass messages to main isolate
    _backgroundChannel.setMethodCallHandler((call) async {
      // send the update to the main isolate, where it will be passed
      // on to the registered callback

      final args = call.arguments as List<dynamic>;
      final sendPort = IsolateNameServer.lookupPortByName(portName);
      final taskAsJsonMapString = args.first as String;
      switch (call.method) {
        case 'statusUpdate':
          final status = args.last as int;
          sendPort?.send([call.method, taskAsJsonMapString, status]);
          break;

        case 'progressUpdate':
          final progress = args.last as double;
          sendPort?.send([call.method, taskAsJsonMapString, progress]);
          break;

        default:
          throw UnimplementedError(
              'Background channel method call ${call.method} not supported');
      }
    });
    // register any callbacks provided with initialization
    _initialized = true;
    if (downloadStatusCallback != null || downloadProgressCallback != null) {
      registerCallbacks(
          group: group,
          downloadStatusCallback: downloadStatusCallback,
          downloadProgressCallback: downloadProgressCallback);
    }
  }

  /// Register status or progress callbacks to monitor download progress.
  ///
  /// Different callbacks can be set for different groups, and the group
  /// can be passed on with the [BackgroundDownloadTask] to ensure the
  /// appropriate callbacks are called for that group.
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  /// If progress updates are requested, a status update is also requested.
  static void registerCallbacks({String group = defaultGroup,
    DownloadStatusCallback? downloadStatusCallback,
    DownloadProgressCallback? downloadProgressCallback}) {
    assert(_initialized, 'FileDownloader must be initialized before use');
    assert(downloadStatusCallback != null || (downloadProgressCallback != null),
    'Must provide a status update callback or a progress update callback, or both');
    if (downloadStatusCallback != null) {
      statusCallbacks[group] = downloadStatusCallback;
    }
    if (downloadProgressCallback != null) {
      progressCallbacks[group] = downloadProgressCallback;
    }
  }


  /// Start a new download task
  ///
  /// Returns true if successfully enqueued. A new task will also generate
  /// a [DownloadTaskStatus.running] update to the registered callback
  static Future<bool> enqueue(BackgroundDownloadTask task) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    return await _channel.invokeMethod<bool>(
        'enqueueDownload', [jsonEncode(task.toJsonMap())]) ??
        false;
  }


  /// Resets the downloader by cancelling all ongoing download tasks within
  /// the provided group
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [DownloadTaskStatus.canceled] update to the registered callback, if
  /// configured
  static Future<int> reset({String? group = defaultGroup}) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    return await _channel.invokeMethod<int>('reset', group) ?? -1;
  }

  /// Returns a list of taskIds of all tasks currently running
  static Future<List<String>> allTaskIds({String? group = defaultGroup}) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    final result = await _channel.invokeMethod<List<Object?>>('allTasks', group) ?? [];
    return result.map((e) => e as String).toList();
  }

  /// Delete all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [DownloadTaskStatus.canceled] update to
  /// the registered callback
  static Future<bool> cancelTasksWithIds(List<String> taskIds) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    return await _channel.invokeMethod<bool>('cancelTasksWithIds', taskIds) ?? false;
  }

  /// Destroy the [FileDownloader]. Subsequent use requires initialization
  static void destroy() {
    _initialized = false;
    statusCallbacks.clear();
    progressCallbacks.clear();
  }
}
