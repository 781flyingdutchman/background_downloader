import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

const defaultFilename = 'get_result.txt';
const getTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_get_data';

var callbackCounter = 0;

Future<Task?> onTaskStartCallbackNoChange(Task original) async {
  callbackCounter++;
  return null;
}

Future<Task?> onTaskStartCallbackUrlChange(Task original) async {
  callbackCounter++;
  return original.copyWith(url: '$getTestUrl?json=true&param1=changed');
}

Future<Task?> onTaskStartCallbackHeaderChange(Task original) async {
  callbackCounter++;
  return original.copyWith(headers: {'Auth': 'newBearer'});
}

Future<void> onTaskFinishedCallback(TaskStatusUpdate statusUpdate) async {
  expect(statusUpdate.status, equals(TaskStatus.complete));
  expect(statusUpdate.responseStatusCode, equals(200));
  callbackCounter++;
}

void main() {
  setUp(() async {
    callbackCounter = 0;
  });

  group('onStartCallback', () {
    test('no-change callback', () async {
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true', 'param1': 'original'},
          filename: defaultFilename,
          options: TaskOptions(onTaskStart: onTaskStartCallbackNoChange));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var result = jsonDecode(await File(path).readAsString());
      expect(result['args']['param1'], equals('original'));
      expect(callbackCounter, equals(1));
      await File(path).delete();
    });

    test('url-change callback', () async {
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true', 'param1': 'original'},
          filename: defaultFilename,
          options: TaskOptions(onTaskStart: onTaskStartCallbackUrlChange));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var result = jsonDecode(await File(path).readAsString());
      expect(result['args']['param1'], equals('changed'));
      expect(callbackCounter, equals(1));
      await File(path).delete();
    });

    test('header-change callback', () async {
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true'},
          headers: {'Original': 'header'},
          filename: defaultFilename,
          options: TaskOptions(onTaskStart: onTaskStartCallbackHeaderChange));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var result = jsonDecode(await File(path).readAsString());
      expect(result['headers']['Auth'], equals('newBearer'));
      expect(callbackCounter, equals(1));
      await File(path).delete();
    });
  });

  group('onFinishedCallback', () {
    test('onFinishedCallback', () async {
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true', 'param1': 'original'},
          filename: defaultFilename,
          options: TaskOptions(onTaskFinished: onTaskFinishedCallback));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var result = jsonDecode(await File(path).readAsString());
      expect(result['args']['param1'], equals('original'));
      expect(callbackCounter, equals(1));
      await File(path).delete();
    });
  });
}
