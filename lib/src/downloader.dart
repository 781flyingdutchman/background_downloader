import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:file_downloader/file_downloader.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// Signature for a function you can register to be called
/// when the download state of a task with [id] changes.
typedef DownloadCallback = void Function(String taskId, DownloadTaskStatus status);

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static const _channel = MethodChannel('com.bbflight.file_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.file_downloader.background');
  static bool _initialized = false;

  bool get initialized => _initialized;

  /// Initialize the downloader and register a callback to handle status
  /// updates
  static void initialize({DownloadCallback? callback}) {
    // Incoming calls from the native code will be on the backgroundChannel,
    // so this isolate listener moves it from background to foreground
    const portName = 'file_downloader_send_port';
    if (callback != null) {
      // create simple listener Isolate to receive download updates in the
      // main isolate
      final receivePort = ReceivePort();
      if (!IsolateNameServer.registerPortWithName(
          receivePort.sendPort, portName)) {
        IsolateNameServer.removePortNameMapping(portName);
        IsolateNameServer.registerPortWithName(receivePort.sendPort, portName);
      }
      receivePort.listen((dynamic data) {
        final taskId = data[0] as String;
        final status = DownloadTaskStatus.values[data[1] as int];
        callback(taskId, status);
      });
    }
    _backgroundChannel.setMethodCallHandler((call) async {
      if (callback != null) {
        // send the update to the main isolate, where it will be passed
        // on to the registered callback
        final args = call.arguments as List<dynamic>;
        final taskId = args.first as String;
        final status = args.last as int;
        final sendPort = IsolateNameServer.lookupPortByName(portName);
        sendPort?.send([taskId, status]);
      }
    });
    _initialized = true;
  }

  /// Resets the downloader by cancelling all ongoing download tasks
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [DownloadTaskStatus.canceled] update to the registered callback
  static Future<void> reset() async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    await _channel.invokeMethod<int>('reset');
  }

  /// Start a new download task
  ///
  /// Returns true if successfully enqueued. A new task will also generate
  /// a [DownloadTaskStatus.running] update to the registered callback
  static Future<bool> enqueue(BackgroundDownloadTask task) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    final arg = jsonEncode(task,
        toEncodable: (Object? value) =>
            value is BackgroundDownloadTask ? value.toJson() : null);
    return await _channel.invokeMethod<bool>('enqueueDownload', arg) ?? false;
  }

  /// Returns a list of taskIds of all tasks currently running
  static Future<List<String>> allTaskIds() async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    final result = await _channel.invokeMethod<List<Object?>>('allTasks') ?? [];
    return result.map((e) => e as String).toList();
  }

  /// Delete all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [DownloadTaskStatus.canceled] update to
  /// the registered callback
  static Future<void> cancelTasksWithIds(List<String> taskIds) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    await _channel.invokeMethod<bool>('cancelTasksWithIds', taskIds);
  }
}
