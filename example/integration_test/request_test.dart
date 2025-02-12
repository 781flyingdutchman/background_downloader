import 'dart:io';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

// Helper function to get a temporary directory for file operations.
Future<Directory> getTempDir() async {
  final dir = await getTemporaryDirectory();
  return Directory('${dir.path}/bgdl_test');
}

//Helper function to get the task ID from the httpbin response
String? getTaskId(Map<String, dynamic> response) {
  if (response.containsKey('args') && response['args'].containsKey('taskId')) {
    return response['args']['taskId'];
  }
  return null;
}

void main() {
  // Run tests in a group for better organization
  group('Background Downloader Integration Tests (httpbin.org)', () {
    late Directory tempDir;
    late FileDownloader downloader;

    // Set up before each test.
    setUp(() async {
      tempDir = await getTempDir();
      if (!tempDir.existsSync()) {
        tempDir.createSync(recursive: true);
      }
      downloader = FileDownloader();
    });

    // Tear down after each test.
    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('GET request with FileDownloader().request', () async {
      const taskId = 'get-request-test';
      final request = Request(
        url: 'https://httpbin.org/get?taskId=$taskId',
        httpRequestMethod: 'GET',
      );
      final result = await downloader.request(request);
      expect(result.statusCode, 200);
      expect(result.headers.containsKey('content-type'), true);
      expect(
          result.headers['content-type']!.contains('application/json'), true);

      // Parse the JSON response and check for our taskId.
      final Map<String, dynamic> data = jsonDecode(result.body);
      expect(getTaskId(data), taskId);
    });

    test('POST request with FileDownloader().request', () async {
      const taskId = 'post-request-test';
      final request = Request(
          url: 'https://httpbin.org/post?taskId=$taskId',
          httpRequestMethod: 'POST',
          post: '{"testKey": "testValue"}');
      final result = await downloader.request(request);
      expect(result.statusCode, 200);
      expect(result.headers.containsKey('content-type'), true);
      expect(
          result.headers['content-type']!.contains('application/json'), true);

      final Map<String, dynamic> data = jsonDecode(result.body);
      expect(getTaskId(data), taskId);
      expect(data['json']['testKey'], 'testValue'); // Verify post data
    });

    test('PUT request with FileDownloader().request', () async {
      const taskId = 'put-request-test';
      final request = Request(
          url: 'https://httpbin.org/put?taskId=$taskId',
          httpRequestMethod: 'PUT',
          post: '{"testKey": "putValue"}');
      final result = await downloader.request(request);
      expect(result.statusCode, 200);
      expect(
          result.headers['content-type']!.contains('application/json'), true);

      final Map<String, dynamic> data = jsonDecode(result.body);
      expect(getTaskId(data), taskId);
      expect(data['json']['testKey'], 'putValue'); // Verify post data.
    });

    test('PATCH request with FileDownloader().request', () async {
      const taskId = 'patch-request-test';
      final request = Request(
          url: 'https://httpbin.org/patch?taskId=$taskId',
          httpRequestMethod: 'PATCH',
          post: '{"testKey": "patchValue"}');
      final result = await downloader.request(request);
      expect(result.statusCode, 200);
      expect(
          result.headers['content-type']!.contains('application/json'), true);

      final Map<String, dynamic> data = jsonDecode(result.body);
      expect(getTaskId(data), taskId);
      expect(data['json']['testKey'], 'patchValue'); // Verify post data.
    });

    test('DELETE request with FileDownloader().request', () async {
      const taskId = 'delete-request-test';
      final task = Request(
          url: 'https://httpbin.org/delete?taskId=$taskId',
          httpRequestMethod: 'DELETE');
      final result = await downloader.request(task);
      expect(result.statusCode, 200);
      expect(
          result.headers['content-type']!.contains('application/json'), true);

      final Map<String, dynamic> data = jsonDecode(result.body);
      expect(getTaskId(data), taskId);
    });

    test('HEAD request with FileDownloader().request', () async {
      const taskId = 'head-request-test';
      final request = Request(
          url: 'https://httpbin.org/get?taskId=$taskId',
          // Use GET endpoint for HEAD
          httpRequestMethod: 'HEAD');

      final result = await downloader.request(request);
      expect(result.statusCode, 200);
      expect(result.headers.containsKey('content-type'), true);
      expect(
          result.body.isEmpty, isTrue); // Important: HEAD should have no body
    });

    test('POST request with custom headers via FileDownloader().request',
        () async {
      const taskId = 'post-request-headers-test';
      final customHeaders = {
        'X-Custom-Header': 'CustomValue',
        'Authorization': 'Bearer mytoken',
      };
      final request = Request(
          url: 'https://httpbin.org/post?taskId=$taskId',
          httpRequestMethod: 'POST',
          headers: customHeaders,
          post: '{"testKey": "testValue"}');
      final result = await downloader.request(request);
      expect(result.statusCode, 200);

      final Map<String, dynamic> data = jsonDecode(result.body);
      expect(getTaskId(data), taskId);
      expect(data['headers']['X-Custom-Header'],
          'CustomValue'); // Verify custom header
      expect(data['headers']['Authorization'],
          'Bearer mytoken'); // Verify auth header
    });
  });

  group(
      'Background Downloader Integration Tests (httpbin.org) - Download Method',
      () {
    late Directory tempDir;
    late FileDownloader downloader;

    setUp(() async {
      tempDir = await getTempDir();
      if (!tempDir.existsSync()) {
        tempDir.createSync(recursive: true);
      }
      downloader = FileDownloader();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('GET request with FileDownloader().download', () async {
      const taskId = 'get-download-test';
      final task = DownloadTask(
          url: 'https://httpbin.org/get?taskId=$taskId',
          httpRequestMethod: 'GET',
          taskId: taskId);
      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);
      expect(file.existsSync(), isTrue);

      final Map<String, dynamic> data = jsonDecode(await file.readAsString());
      expect(getTaskId(data), taskId);
      file.deleteSync();
    });

    test('POST request with FileDownloader().download', () async {
      const taskId = 'post-download-test';
      final task = DownloadTask(
        url: 'https://httpbin.org/post?taskId=$taskId',
        httpRequestMethod: 'POST',
        headers: {'Content-type': 'text/plain'},
        taskId: taskId,
        post: 'TestPost',
      );
      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);
      expect(file.existsSync(), isTrue);

      final Map<String, dynamic> data = jsonDecode(await file.readAsString());
      expect(getTaskId(data), taskId);
      expect(data['data'], 'TestPost');
      file.deleteSync();
    });

    test('PUT request with FileDownloader().download', () async {
      const taskId = 'put-download-test';
      final task = DownloadTask(
        url: 'https://httpbin.org/put?taskId=$taskId',
        httpRequestMethod: 'PUT',
        headers: {'Content-type': 'text/plain'},
        taskId: taskId,
        post: 'TestPost',
      );
      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);
      expect(file.existsSync(), isTrue);

      final Map<String, dynamic> data = jsonDecode(await file.readAsString());
      expect(getTaskId(data), taskId);
      expect(data['data'], 'TestPost');
      file.deleteSync();
    });

    test('PATCH request with FileDownloader().download', () async {
      const taskId = 'patch-download-test';
      final task = DownloadTask(
        url: 'https://httpbin.org/patch?taskId=$taskId',
        httpRequestMethod: 'PATCH',
        headers: {'Content-type': 'text/plain'},
        taskId: taskId,
        post: 'TestPost',
      );
      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);
      expect(file.existsSync(), isTrue);

      final Map<String, dynamic> data = jsonDecode(await file.readAsString());
      expect(getTaskId(data), taskId);
      expect(data['data'], 'TestPost');
      file.deleteSync();
    });

    test('DELETE request with FileDownloader().download', () async {
      const taskId = 'delete-download-test';
      final task = DownloadTask(
          url: 'https://httpbin.org/delete?taskId=$taskId',
          httpRequestMethod: 'DELETE',
          taskId: taskId);
      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);
      expect(file.existsSync(), isTrue);

      final Map<String, dynamic> data = jsonDecode(await file.readAsString());
      expect(getTaskId(data), taskId);
      file.deleteSync();
    });

    test('HEAD request with FileDownloader().download', () async {
      const taskId = 'head-download-test';
      final task = DownloadTask(
          url: 'https://httpbin.org/get?taskId=$taskId', //Use get for HEAD
          httpRequestMethod: 'HEAD',
          taskId: taskId);
      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);

      // For a HEAD request, we don't expect content, but we DO expect the file
      // to be created of 0 length
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), equals(0));
      file.deleteSync();
    });

    test('POST with custom headers using FileDownloader().download', () async {
      const taskId = 'post-download-headers-test';
      final customHeaders = {
        'X-Custom-Header': 'CustomValue',
        'Authorization': 'Bearer mytoken',
      };
      final task = DownloadTask(
          url: 'https://httpbin.org/post?taskId=$taskId',
          httpRequestMethod: 'POST',
          headers: {'Content-type': 'text/plain', ...customHeaders},
          post: 'TestPost',
          taskId: taskId);

      final result = await downloader.download(task);
      expect(result.status, TaskStatus.complete);

      final filePath = await task.filePath();
      final file = File(filePath);
      expect(file.existsSync(), isTrue);

      final Map<String, dynamic> data = jsonDecode(await file.readAsString());
      expect(getTaskId(data), taskId);
      expect(data['headers']['X-Custom-Header'], 'CustomValue');
      expect(data['headers']['Authorization'], 'Bearer mytoken');
      expect(data['data'], 'TestPost');
      file.deleteSync();
    });
  });
}
