import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'models.dart';

/// Signature for a function which is called when the download state of a task
/// with [id] changes.
typedef DownloadCallback = void Function(
    String id,
    DownloadTaskStatus status,
    int progress,
    );

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  static const _channel = MethodChannel('com.bbflight.file_downloader');
  static const _backgroundChannel = MethodChannel(
      'com.bbflight.file_downloader.background');

  static bool _initialized = false;

  /// Whether the plugin is initialized. The plugin must be initialized before
  /// use.
  static bool get initialized => _initialized;


  static void initialize() {
    _backgroundChannel.setMethodCallHandler((call) async {
      print("Received backgroudn callback wiht argumens ${call.arguments}");
      return null;
    });
    _initialized = true;
  }

  static Future<void> resetDownloadWorker() async {
    print('invoking resetDownloadWorker');
    await _channel.invokeMethod<String>('reset');
  }

  static Future<bool?> enqueueSomeTasks() async {
    assert(_initialized, 'plugin flutter_downloader is not initialized');
    for (var n = 0; n < 5; n++) {
      final backgroundDownloadTask = BackgroundDownloadTask(
          'taskId$n', "https://google.com", "filename$n", "directory", 0);
      final arg = jsonEncode(backgroundDownloadTask,
          toEncodable: (Object? value) =>
          value is BackgroundDownloadTask ? value
              .toJson() : null);
      print('invoking enqueueDownload');
      await _channel.invokeMethod<bool>(
          'enqueueDownload', arg);
    }
    print('invoked enqueueDownload');
    return true;
  }

  static Future<Map<String, List<Object?>>> moveToBackground() async {
    assert(_initialized, 'plugin flutter_downloader is not initialized');
    print('invoking moveToBackground');
    var rawResult = await _channel.invokeMethod<Map<Object?, Object?>>('moveToBackground');
    var interimResult = Map<String, List<Object?>>.from(rawResult!);
    var finalResult = {
      'success': List<String>.from(interimResult['success']!),
      'failure': List<String>.from(interimResult['failure']!),
    };
    print(finalResult['success']);
    print('');
    print(finalResult['failure']);
    print('invoked moveToBackground');
    return finalResult;
  }

  static Future<Map<String, List<Object?>>> moveToForeground() async {
    assert(_initialized, 'plugin flutter_downloader is not initialized');
    print('invoking moveToForeground');
    var rawResult = await _channel.invokeMethod<Map<Object?, Object?>>('moveToForeground');
    var interimResult = Map<String, List<Object?>>.from(rawResult!);
    var finalResult = {
      'success': List<String>.from(interimResult['success']!),
      'failure': List<String>.from(interimResult['failure']!),
    };
    print(finalResult['success']);
    print('');
    print(finalResult['failure']);
    print('invoked moveToForeground');
    return finalResult;
  }


}
