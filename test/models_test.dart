import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

final task = DownloadTask(
    taskId: 'taskId',
    url: 'url',
    urlQueryParameters: {'a': 'b'},
    filename: 'filename',
    headers: {'c': 'd'},
    httpRequestMethod: 'GET',
    baseDirectory: BaseDirectory.temporary,
    directory: 'dir',
    group: 'group',
    updates: Updates.statusAndProgress,
    requiresWiFi: true,
    retries: 5,
    allowPause: true,
    metaData: 'metaData',
    creationTime: DateTime.fromMillisecondsSinceEpoch(1000));
const downloadTaskJsonString =
    '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5,"retriesRemaining":5,"creationTime":1000,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask"}';
const downloadTaskJsonStringDoubles =
    '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5.0,"retriesRemaining":5.0,"creationTime":1000.0,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1.0,"group":"group","updates":3.0,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask"}';

final uploadTask = UploadTask(
    taskId: 'taskId',
    url: 'url',
    urlQueryParameters: {'a': 'b'},
    filename: 'filename',
    headers: {'c': 'd'},
    httpRequestMethod: 'PUT',
    fileField: 'fileField',
    fields: {'e': 'f'},
    baseDirectory: BaseDirectory.temporary,
    directory: 'dir',
    group: 'group',
    updates: Updates.statusAndProgress,
    requiresWiFi: true,
    retries: 5,
    metaData: 'metaData',
    creationTime: DateTime.fromMillisecondsSinceEpoch(1000));
const uploadTaskJsonString =
    '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"PUT","post":null,"retries":5,"retriesRemaining":5,"creationTime":1000,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":false,"metaData":"metaData","fileField":"fileField","mimeType":"application/octet-stream","fields":{"e":"f"},"taskType":"UploadTask"}';
const uploadTaskJsonStringDoubles =
    '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"PUT","post":null,"retries":5.0,"retriesRemaining":5.0,"creationTime":1000.0,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1.0,"group":"group","updates":3.0,"requiresWiFi":true,"allowPause":false,"metaData":"metaData","fileField":"fileField","mimeType":"application/octet-stream","fields":{"e":"f"},"taskType":"UploadTask"}';

void main() {
  group('JSON conversion', () {
    test('DownloadTask', () {
      final task2 = Task.createFromJsonMap(jsonDecode(downloadTaskJsonString));
      expect(task2, equals(task));
      expect(jsonEncode(task2.toJsonMap()), equals(downloadTaskJsonString));
      final task3 =
          Task.createFromJsonMap(jsonDecode(downloadTaskJsonStringDoubles));
      expect(jsonEncode(task3.toJsonMap()), equals(downloadTaskJsonString));
    });

    test('UploadTask', () {
      final task2 = Task.createFromJsonMap(jsonDecode(uploadTaskJsonString));
      expect(jsonEncode(task2.toJsonMap()), equals(uploadTaskJsonString));
      final task3 =
          Task.createFromJsonMap(jsonDecode(uploadTaskJsonStringDoubles));
      expect(jsonEncode(task3.toJsonMap()), equals(uploadTaskJsonString));
    });

    test('TaskStatusUpdate', () {
      final statusUpdate = TaskStatusUpdate(
          task, TaskStatus.failed, TaskConnectionException('test'));
      const expected =
          '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5,"retriesRemaining":5,"creationTime":1000,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask","taskStatus":4,"exception":{"type":"TaskConnectionException","description":"test"}}';
      expect(jsonEncode(statusUpdate.toJsonMap()), equals(expected));
      final update2 = TaskStatusUpdate.fromJsonMap(jsonDecode(expected));
      expect(update2.task, equals(statusUpdate.task));
      expect(update2.status, equals(TaskStatus.failed));
      expect(update2.exception?.description, equals('test'));
      expect(update2.exception is TaskConnectionException, isTrue);
      const withDoubles =
          '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5.0,"retriesRemaining":5.0,"creationTime":1000.0,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1.0,"group":"group","updates":3.0,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask","taskStatus":4.0,"exception":{"type":"TaskConnectionException","description":"test"}}';
      expect(
          jsonEncode(TaskStatusUpdate.fromJsonMap(jsonDecode(withDoubles))
              .toJsonMap()),
          equals(expected));
    });

    test('TaskProgressUpdate', () {
      final progressUpdate = TaskProgressUpdate(task, 1);
      const expected =
          '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5,"retriesRemaining":5,"creationTime":1000,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask","progress":1.0}';
      expect(jsonEncode(progressUpdate.toJsonMap()), equals(expected));
      final update2 = TaskProgressUpdate.fromJsonMap(jsonDecode(expected));
      expect(update2.task, equals(progressUpdate.task));
      expect(update2.progress, equals(1));
      const withDoubles =
          '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5.0,"retriesRemaining":5.0,"creationTime":1000.0,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1.0,"group":"group","updates":3.0,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask","progress":1,"expectedFileSize":123.0}';
      expect(
          jsonEncode(TaskProgressUpdate.fromJsonMap(jsonDecode(withDoubles))
              .toJsonMap()),
          equals(expected));
    });

    test('TaskRecord', () {
      final taskRecord =
          TaskRecord(task, TaskStatus.failed, 1, TaskUrlException('test'));
      const expected =
          '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5,"retriesRemaining":5,"creationTime":1000,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask","status":4,"progress":1.0,"expectedFileSize":123,"exception":{"type":"TaskUrlException","description":"test"}}';
      expect(jsonEncode(taskRecord.toJsonMap()), equals(expected));
      final update2 = TaskRecord.fromJsonMap(jsonDecode(expected));
      expect(update2.task, equals(taskRecord.task));
      expect(update2.status, equals(TaskStatus.failed));
      expect(update2.exception?.description, equals('test'));
      expect(update2.exception is TaskUrlException, isTrue);
      expect(update2.progress, equals(1));
      const withDoubles =
          '{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5.0,"retriesRemaining":5.0,"creationTime":1000.0,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask","status":4.0,"progress":1,"expectedFileSize":123.0,"exception":{"type":"TaskUrlException","description":"test"}}';
      expect(
          jsonEncode(
              TaskRecord.fromJsonMap(jsonDecode(withDoubles)).toJsonMap()),
          equals(expected));
    });

    test('ResumeData', () {
      final resumeData = ResumeData(task, 'data', 123);
      const expected =
          '{"task":{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5,"retriesRemaining":5,"creationTime":1000,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1,"group":"group","updates":3,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask"},"data":"data","requiredStartByte":123}';
      expect(jsonEncode(resumeData.toJsonMap()), equals(expected));
      final update2 = ResumeData.fromJsonMap(jsonDecode(expected));
      expect(update2.task, equals(resumeData.task));
      expect(update2.data, equals('data'));
      expect(update2.requiredStartByte, equals(123));
      const withDoubles =
          '{"task":{"url":"url?a=b","headers":{"c":"d"},"httpRequestMethod":"GET","post":null,"retries":5.0,"retriesRemaining":5.0,"creationTime":1000.0,"taskId":"taskId","filename":"filename","directory":"dir","baseDirectory":1.0,"group":"group","updates":3.0,"requiresWiFi":true,"allowPause":true,"metaData":"metaData","taskType":"DownloadTask"},"data":"data","requiredStartByte":123.0}';
      expect(
          jsonEncode(
              ResumeData.fromJsonMap(jsonDecode(withDoubles)).toJsonMap()),
          equals(expected));
    });
  });
}
