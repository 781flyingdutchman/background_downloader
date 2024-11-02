import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

const defaultFilename = 'get_result.txt';
const getTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_get_data';

var callbackCounter = 0;
var mainIsolateCallbackCounter = 0;
var mainIsolateCallbackCounterAtStartOfTest = 0;
ReceivePort? receivePort;

/// Send the counter value in [callbackCounter] to the main isolate via the
/// send port registered under name 'callbackPort'
///
/// This complicated setup is required because the callbacks are call on a
/// background isolate and therefore do not change variables held at the
/// main isolate: [callbackCounter] will not change where the tests run when
/// it is changed in the callback.
/// In the test [setUp] we therefore create an isolate [ReceivePort], register
/// its [SendPort] under 'callbackPort' so it can be found by the background
/// isolate, then start listening to the receive port and update the
/// [mainIsolateCallbackCounter] with the value received.
/// When running multiple tests we do not create a new isolate for every test,
/// and because we cannot set a value in the background isolate we maintain
/// a variable [mainIsolateCallbackCounterAtStartOfTest] that holds the value
/// of [mainIsolateCallbackCounter] when the test starts. To confirm the
/// callback was called once, we therefore test:
///   expect(mainIsolateCallbackCounter,
///     equals(mainIsolateCallbackCounterAtStartOfTest + 1))
void _sendCounterToMainIsolate() {
  final sendPort = IsolateNameServer.lookupPortByName('callbackPort');
  sendPort?.send(callbackCounter);
}

Future<Task?> onTaskStartCallbackNoChange(Task original) async {
  callbackCounter++;
  print(
      'In onTaskStartCallbackNoChange. Callback counter is now $callbackCounter');
  _sendCounterToMainIsolate();
  return null;
}

Future<Task?> onTaskStartCallbackUrlChange(Task original) async {
  callbackCounter++;
  print(
      'In onTaskStartCallbackUrlChange. Callback counter is now $callbackCounter');
  _sendCounterToMainIsolate();
  return original.copyWith(url: '$getTestUrl?json=true&param1=changed');
}

Future<Task?> onTaskStartCallbackHeaderChange(Task original) async {
  callbackCounter++;
  print(
      'In onTaskStartCallbackHeaderChange. Callback counter is now $callbackCounter');
  _sendCounterToMainIsolate();
  return original.copyWith(headers: {'Auth': 'newBearer'});
}

Future<void> onTaskFinishedCallback(TaskStatusUpdate statusUpdate) async {
  if (statusUpdate.status == TaskStatus.complete &&
      statusUpdate.responseStatusCode == 200) {
    callbackCounter++;
  } else {
    print('Status not complete or code not 200: $statusUpdate');
  }
  print('In onTaskFinishedCallback. Callback counter is now $callbackCounter');
  _sendCounterToMainIsolate();
}

void main() {
  setUp(() async {
    if (receivePort == null) {
      receivePort = ReceivePort();
      final sendPort = receivePort!.sendPort;
      IsolateNameServer.registerPortWithName(sendPort, 'callbackPort');
      print('Registered callbackPort');
      receivePort!.listen((value) {
        print('Main isolate received value $value');
        mainIsolateCallbackCounter = value as int;
      });
    }
    mainIsolateCallbackCounterAtStartOfTest = mainIsolateCallbackCounter;
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
      expect(mainIsolateCallbackCounter,
          equals(mainIsolateCallbackCounterAtStartOfTest + 1));
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
      expect(mainIsolateCallbackCounter,
          equals(mainIsolateCallbackCounterAtStartOfTest + 1));

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
      expect(mainIsolateCallbackCounter,
          equals(mainIsolateCallbackCounterAtStartOfTest + 1));

      await File(path).delete();
    });
  });

  group('onFinishedCallback', () {
    test('no change', () async {
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
      await Future.delayed(const Duration(milliseconds: 100));
      expect(mainIsolateCallbackCounter,
          equals(mainIsolateCallbackCounterAtStartOfTest + 1));
      await File(path).delete();
    });
  });
}
