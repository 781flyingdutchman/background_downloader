import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test_utils.dart';

void main() {
  setUp(defaultSetup);

  tearDown(defaultTearDown);

  group('Binary uploads', () {
    test('enqueue binary file using Android content URI', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      // move file to shared storage and obtain the URI
      final dummy = DownloadTask(url: uploadTestUrl, filename: uploadFilename);
      final uriString = await FileDownloader().moveFileToSharedStorage(
          await dummy.filePath(), SharedStorage.downloads,
          asAndroidUri: true); //TODO make this work for any file URI
      print('URI: $uriString');
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: Uri.parse(uriString!), post: 'binary');
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
    }, skip: !Platform.isAndroid);

    test('upload binary file using incorrect Android content URI', () async {
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl,
          uri: Uri.parse('content://some/invalid/path'));
      final result = await FileDownloader().upload(task);
      print(result.exception?.description);
      expect(result.status, equals(TaskStatus.failed));
      expect(
          result.exception?.exceptionType, equals('TaskFileSystemException'));
    }, skip: !Platform.isAndroid);

    test('upload binary file using file URI', () async {
      final filePath = await uploadTask.filePath();
      final fileUri = Uri.file(filePath);
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: fileUri, post: 'binary');
      expect(task.usesUri, isTrue);
      expect(task.fileUri, equals(fileUri));
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      final fileName = result.task.filename;
      expect(fileName.startsWith('file://'), isTrue);
      expect(fileName.endsWith(uploadFilename), isTrue);
    });
  });

  group('Multipart uploads', () {
    test('enqueue multipart file using Android content URI', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      // move file to shared storage and obtain the URI
      final dummy = DownloadTask(url: uploadTestUrl, filename: uploadFilename);
      final uriString = await FileDownloader().moveFileToSharedStorage(
          await dummy.filePath(), SharedStorage.downloads,
          asAndroidUri: true);
      print('URI: $uriString');
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: Uri.parse(uriString!));
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
    }, skip: !Platform.isAndroid);
  });

  group('Downloads with file URI', () {
    test('download file without filename', () async {
      final directory = await getApplicationDocumentsDirectory();
      final directoryUri = Uri.file(directory.path);
      task = DownloadTask.fromUri(url: workingUrl, directoryUri: directoryUri);
      expect(task.usesUri, isTrue);
      expect(
          allDigitsRegex.hasMatch(task.filename), isTrue); // filename omitted
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      print('filename=$filename');
      print('uri=$uri');
      expect(filename, equals(task.filename));
      expect(uri!.scheme, equals('file'));
      expect(uri.path, contains(filename));
      expect(uri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uriUtils.deleteFile(uri), isTrue);
    });

    test('download file with suggested filename', () async {
      final directory = await getApplicationDocumentsDirectory();
      final directoryUri = Uri.file(directory.path);
      task = DownloadTask.fromUri(
          url: urlWithContentLength,
          directoryUri: directoryUri,
          filename: DownloadTask.suggestedFilename);
      expect(task.usesUri, isTrue);
      expect(task.filename,
          equals(DownloadTask.suggestedFilename)); // filename omitted
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      print('filename=$filename');
      print('uri=$uri');
      expect(filename, equals('5MB-test.ZIP'));
      expect(uri!.scheme, equals('file'));
      expect(uri.path, contains(filename));
      expect(uri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uriUtils.deleteFile(uri), isTrue);
    });
  });

  group('Downloads via picker', () {
    test('download file using Android content URI', () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uriUtils.pickDirectory();
      expect(directoryUri, isNotNull);
      task = DownloadTask.fromUri(url: workingUrl, directoryUri: directoryUri!);
      expect(task.usesUri, isTrue);
      expect(
          allDigitsRegex.hasMatch(task.filename), isTrue); // filename omitted
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      expect(filename, equals(task.filename));
      expect(uri!.scheme, equals('content'));
      expect(uri.path, contains(filename));
      expect(uri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uriUtils.deleteFile(uri), isTrue);
    }, skip: !Platform.isAndroid);

    test('download file with suggested filename using Android content URI',
        () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uriUtils.pickDirectory();
      expect(directoryUri, isNotNull);
      task = DownloadTask.fromUri(
          url: urlWithContentLength,
          directoryUri: directoryUri!,
          filename: DownloadTask.suggestedFilename);
      expect(task.usesUri, isTrue);
      expect(task.filename, equals(DownloadTask.suggestedFilename));
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      expect(filename, equals('5MB-test.ZIP'));
      expect(uri!.scheme, equals('content'));
      expect(uri.path, contains(filename));
      expect(uri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uriUtils.deleteFile(uri), isTrue);
    }, skip: !Platform.isAndroid);
  });
}
