import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:file_downloader/file_downloader.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'models.dart';

/// Signature for a function you can register to be called
/// when the download state of a task with [id] changes.
typedef DownloadCallback = void Function(String taskId, bool success);

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static const _channel = MethodChannel('com.bbflight.file_downloader');
  static const _backgroundChannel =
      MethodChannel('com.bbflight.file_downloader.background');
  static bool _initialized = false;

  bool get initialized => _initialized;

  static void initialize({DownloadCallback? callback}) {
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
        print('Received $data');
        final taskId = data[0] as String;
        final success = data[1] as bool;
        callback(taskId, success);
      });
    }
    _backgroundChannel.setMethodCallHandler((call) async {
      print("Received background callback with arguments ${call.arguments}");
      if (callback != null) {
        // send the update to the main isolate, where it will be passed
        // on to the registered callback
        print("callback is not null");
        final args = call.arguments as List<dynamic>;
        final taskId = args.first as String;
        final success = args.last as bool;
        final sendPort = IsolateNameServer.lookupPortByName(portName);
        sendPort?.send([taskId, success]);
      }
    });
    _initialized = true;
  }

  static Future<void> resetDownloadWorker() async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    print('invoking resetDownloadWorker');
    await _channel.invokeMethod<String>('reset');
  }

  static Future<void> enqueue(BackgroundDownloadTask task) async {
    assert(_initialized, 'FileDownloader must be initialized before use');
    final arg = jsonEncode(task,
        toEncodable: (Object? value) =>
            value is BackgroundDownloadTask ? value.toJson() : null);
    print('invoking enqueueDownload');
    await _channel.invokeMethod<bool>('enqueueDownload', arg);
  }
}
