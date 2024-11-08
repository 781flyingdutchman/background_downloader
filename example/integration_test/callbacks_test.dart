// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

const defaultFilename = 'get_result.txt';
const getTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_get_data';
const refreshTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_refresh';

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
/// callback was called once, we therefore test (on iOS and Android):
///   expect(mainIsolateCallbackCounter,
///     equals(mainIsolateCallbackCounterAtStartOfTest + 1))
///
/// On desktop, each download runs in its own isolate, so the callback is
/// called from a 'fresh' isolate, and therefore we set the
/// mainIsolateCallbackCounterAtStartOfTest to 0 in setUp on desktop
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

Future<Task?> onAuthCallbackNoChange(Task original) async {
  callbackCounter++;
  print('In onAuthCallbackNoChange. Callback counter is now $callbackCounter');
  _sendCounterToMainIsolate();
  return null;
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
    mainIsolateCallbackCounterAtStartOfTest =
        (Platform.isAndroid || Platform.isIOS) ? mainIsolateCallbackCounter : 0;
    mainIsolateCallbackCounter = mainIsolateCallbackCounterAtStartOfTest;
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

  group('onAuth callbacks', () {
    late Auth auth;

    setUp(() {
      auth = Auth(
        accessToken: 'initialAccessToken',
        accessQueryParams: {'auth': '{accessToken}'},
        accessHeaders: {'Authorization': 'Bearer {accessToken}'},
        refreshToken: 'initialRefreshToken',
        refreshHeaders: {
          'Authorization': 'Bearer {accessToken}',
          'Refresh': 'Bearer {refreshToken}'
        },
        refreshUrl: refreshTestUrl,
        accessTokenExpiryTime: DateTime.now()
            .subtract(const Duration(seconds: 10)), // expired token
      );
    });

    test('refresh request', () async {
      final result = await http.post(Uri.parse(refreshTestUrl),
          headers: {'Auth': 'Bearer abcd', 'Content-type': 'application/json'},
          body: jsonEncode({'refresh_token': 'myRefreshToken'}));
      final json = jsonDecode(result.body);
      expect(json['headers']['Auth'], equals('Bearer abcd'));
      expect(json['access_token'], equals('new_access_token'));
      expect(json['expires_in'], equals(3600));
      expect(json['post_body']['refresh_token'], equals('myRefreshToken'));
    });

    test('default handler with unexpired token -> no callback', () async {
      // no callback makes no change to the original task, so only
      // the known arguments and headers should be present, as well as the
      // original auth argument and header (because no refresh took place)
      auth.onAuthCallback = onAuthCallbackNoChange;
      auth.accessTokenExpiryTime =
          DateTime.now().add(const Duration(minutes: 1));
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true'},
          headers: {'H1': 'value1'},
          filename: defaultFilename,
          options: TaskOptions(auth: auth));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var resultAsString = await File(path).readAsString();
      print(resultAsString);
      var result = jsonDecode(resultAsString);
      expect(result['args']['json'], equals('true'));
      expect(result['args']['auth'], equals('initialAccessToken'));
      expect(result['headers']['H1'], equals('value1'));
      expect(result['headers']['Authorization'],
          equals('Bearer initialAccessToken'));
      expect(mainIsolateCallbackCounter,
          equals(mainIsolateCallbackCounterAtStartOfTest)); // no callback
      await File(path).delete();
    });

    test('default handler with null auth callback', () async {
      // null auth callback makes no change to the original task, so only
      // the known arguments and headers should be present, as well as the
      // original auth argument and header (because no refresh took place)
      auth.onAuthCallback = onAuthCallbackNoChange; // returns null
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true'},
          headers: {'H1': 'value1'},
          filename: defaultFilename,
          options: TaskOptions(auth: auth));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var resultAsString = await File(path).readAsString();
      print(resultAsString);
      var result = jsonDecode(resultAsString);
      expect(result['args']['json'], equals('true'));
      expect(result['args']['auth'], equals('initialAccessToken')); // not added
      expect(result['headers']['H1'], equals('value1'));
      expect(result['headers']['Authorization'],
          equals('Bearer initialAccessToken'));
      expect(mainIsolateCallbackCounter,
          equals(mainIsolateCallbackCounterAtStartOfTest + 1)); // called once
      await File(path).delete();
    });

    test('default handler with refresh auth callback', () async {
      // refresh auth callback changes the original task, so only
      // the known arguments and headers should be present, as well as the
      // original auth argument and header (because no refresh took place)
      auth.onAuthCallback = defaultOnAuth;
      final task = DownloadTask(
          url: getTestUrl,
          urlQueryParameters: {'json': 'true'},
          headers: {'H1': 'value1'},
          filename: defaultFilename,
          options: TaskOptions(auth: auth));
      final path =
          join((await getApplicationDocumentsDirectory()).path, task.filename);
      expect((await FileDownloader().download(task)).status,
          equals(TaskStatus.complete));
      var resultAsString = await File(path).readAsString();
      print(resultAsString);
      var result = jsonDecode(resultAsString);
      expect(result['args']['json'], equals('true'));
      expect(result['args']['auth'], equals('new_access_token')); // not added
      expect(result['headers']['H1'], equals('value1'));
      expect(result['headers']['Authorization'],
          equals('Bearer new_access_token'));
      await File(path).delete();
    });
  });
}
