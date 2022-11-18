import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

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
///
/// A successfully downloaded task will always finish with progress 1.0
/// [DownloadTaskStatus.failed] results in progress -1.0
/// [DownloadTaskStatus.canceled] results in progress -2.0
/// [DownloadTaskStatus.notFound] results in progress -3.0
typedef DownloadProgressCallback = void Function(
    BackgroundDownloadTask task, double progress);

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static final _log = Logger('FileDownloader');
  static const defaultGroup = 'default';
  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.background_downloader.background');
  static bool _initialized = false;

  /// Registered [DownloadStatusCallback] for each group
  static final statusCallbacks = <String, DownloadStatusCallback>{};

  /// Registered [DownloadProgressCallback] for each group
  static final progressCallbacks = <String, DownloadProgressCallback>{};

  /// StreamController for [BackgroundDownloadEvent] updates
  static final _updates = StreamController<BackgroundDownloadEvent>();

  /// Stream of [BackgroundDownloadEvent] updates for downloads that do
  /// not have a registered callback
  static Stream<BackgroundDownloadEvent> get updates => _updates.stream;

  /// True if [FileDownloader] was initialized
  static bool get initialized => _initialized;

  /// Initialize the downloader and potentially register callbacks to
  /// handle status and progress updates
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Note that callbacks will be called based on a task's [progressUpdates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [DownloadProgressCallback] and
  /// set the task's [progressUpdates] property to .progressUpdates or
  /// .statusChangeAndProgressUpdates
  static void initialize(
      {String group = defaultGroup,
      DownloadStatusCallback? downloadStatusCallback,
      DownloadProgressCallback? downloadProgressCallback}) {
    WidgetsFlutterBinding.ensureInitialized();
    // Incoming calls from the native code will be on the backgroundChannel,
    // so this isolate listener moves it from background to foreground
    const portName = 'background_downloader_send_port';
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
          if (task.providesStatusUpdates) {
            final downloadTaskStatus =
                DownloadTaskStatus.values[data[2] as int];
            final downloadStatusCallback = statusCallbacks[task.group];
            if (downloadStatusCallback != null) {
              downloadStatusCallback(task, downloadTaskStatus);
            } else {
              if (_updates.hasListener) {
                _updates.add(BackgroundDownloadEvent(task, downloadTaskStatus));
              } else {
                _log.warning(
                    'Requested status updates for task ${task.taskId} in '
                    'group ${task.group} but no downloadStatusCallback '
                    'was registered, and there is no listener to the '
                    'updates stream');
              }
            }
          }
          break;

        case 'progressUpdate':
          if (task.providesProgressUpdates) {
            final progressUpdateCallback = progressCallbacks[task.group];
            if (progressUpdateCallback != null) {
              progressUpdateCallback(task, data[2] as double);
            } else if (_updates.hasListener) {
              _updates.add(BackgroundDownloadEvent(task, data[2] as double));
            } else {
              _log.warning(
                  'Requested progress updates for task ${task.taskId} in '
                  'group ${task.group} but no progressUpdateCallback '
                  'was registered, and there is no listener to the '
                  'updates stream');
            }
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
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Different callbacks can be set for different groups, and the group
  /// can be passed on with the [BackgroundDownloadTask] to ensure the
  /// appropriate callbacks are called for that group.
  ///
  /// Note that callbacks will be called based on a task's [progressUpdates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [DownloadProgressCallback] and
  /// set the task's [progressUpdates] property to .progressUpdates or
  /// .statusChangeAndProgressUpdates
  static void registerCallbacks(
      {String group = defaultGroup,
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
  /// a [DownloadTaskStatus.running] update to the registered callback,
  /// if requested by its [progressUpdates] property
  static Future<bool> enqueue(BackgroundDownloadTask task) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    return await _channel
            .invokeMethod<bool>('enqueue', [jsonEncode(task.toJsonMap())]) ??
        false;
  }

  /// Resets the downloader by cancelling all ongoing download tasks within
  /// the provided group
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [DownloadTaskStatus.canceled] update to the registered callback, if
  /// requested
  static Future<int> reset({String? group = defaultGroup}) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    return await _channel.invokeMethod<int>('reset', group) ?? -1;
  }

  /// Returns a list of taskIds of all tasks currently running in this group
  static Future<List<String>> allTaskIds({String? group = defaultGroup}) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    final result =
        await _channel.invokeMethod<List<Object?>>('allTaskIds', group) ?? [];
    return result.map((e) => e as String).toList();
  }

  /// Delete all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [DownloadTaskStatus.canceled] update to
  /// the registered callback, if requested
  static Future<bool> cancelTasksWithIds(List<String> taskIds) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    return await _channel.invokeMethod<bool>('cancelTasksWithIds', taskIds) ??
        false;
  }

  /// Return [BackgroundDownloadTask] for the given [taskId], or null
  /// if not found.
  ///
  /// Only running tasks are guaranteed to be returned, but returning a task
  /// does not guarantee that the task is still running. To keep track of
  /// the status of tasks, use a [DownloadStatusCallback]
  static Future<BackgroundDownloadTask?> taskForId(String taskId) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    final jsonString = await _channel.invokeMethod<String>('taskForId', taskId);
    if (jsonString != null) {
      return BackgroundDownloadTask.fromJsonMap(jsonDecode(jsonString));
    }
    return null;
  }

  /// Destroy the [FileDownloader]. Subsequent use requires initialization
  static void destroy() {
    _initialized = false;
    statusCallbacks.clear();
    progressCallbacks.clear();
  }
}
