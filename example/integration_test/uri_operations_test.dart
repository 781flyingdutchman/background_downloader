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
          uri: Uri.parse('content://some/invalid/path'),
          post: 'binary');
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

    test('upload multipart file using incorrect Android content URI', () async {
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl,
          uri: Uri.parse('content://some/invalid/path'));
      final result = await FileDownloader().upload(task);
      print(result.exception?.description);
      expect(result.status, equals(TaskStatus.failed));
      expect(
          result.exception?.exceptionType, equals('TaskFileSystemException'));
    }, skip: !Platform.isAndroid);

    test('upload multipart file using file URI', () async {
      final filePath = await uploadTask.filePath();
      final fileUri = Uri.file(filePath);
      final task = UploadTask.fromUri(url: uploadBinaryTestUrl, uri: fileUri);
      expect(task.usesUri, isTrue);
      expect(task.fileUri, equals(fileUri));
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      final fileName = result.task.filename;
      expect(fileName.startsWith('file://'), isTrue);
      expect(fileName.endsWith(uploadFilename), isTrue);
    });

    test('MultiUpload using URIs', () async {
      // move file to shared storage and obtain the URI
      final dummy = DownloadTask(url: uploadTestUrl, filename: uploadFilename);
      final uriString = await FileDownloader().moveFileToSharedStorage(
          await dummy.filePath(), SharedStorage.downloads,
          asAndroidUri: true);
      // move second file to shared storage and obtain the URI
      final dummy2 =
          DownloadTask(url: uploadTestUrl, filename: uploadFilename2);
      final uriString2 = await FileDownloader().moveFileToSharedStorage(
          await dummy2.filePath(), SharedStorage.downloads,
          asAndroidUri: true);
      final task = MultiUploadTask(url: uploadMultiTestUrl, files: [
        ('f1', Uri.parse(uriString!)),
        ('f2', Uri.parse(uriString2!))
      ], fields: {
        'key': 'value'
      });
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
    });

    test('multiUpload using file uri', () async {
      final dummy = DownloadTask(url: uploadTestUrl, filename: uploadFilename);
      final uri1 = Uri.file(await dummy.filePath());
      print('URI: $uri1');
      // move file to shared storage and obtain the URI
      final dummy2 =
          DownloadTask(url: uploadTestUrl, filename: uploadFilename2);
      final uri2 = Uri.file(await dummy2.filePath());
      print('URI: $uri2');
      final task = MultiUploadTask(
          url: uploadMultiTestUrl,
          files: [('f1', uri1), ('f2', uri2)],
          fields: {'key': 'value'});
      print(task.fileFields);
      print(task.filenames);
      print(task.mimeTypes);
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
    });
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
      expect(await FileDownloader().uri.deleteFile(uri), isTrue);
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
      expect(await FileDownloader().uri.deleteFile(uri), isTrue);
    });
  });

  group('Downloads via picker', () {
    test('download file using Android content URI', () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uri.pickDirectory();
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
      expect(await FileDownloader().uri.deleteFile(uri), isTrue);
    }, skip: !Platform.isAndroid);

    test('download file with suggested filename using Android content URI',
        () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uri.pickDirectory();
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
      expect(await FileDownloader().uri.deleteFile(uri), isTrue);
    }, skip: !Platform.isAndroid);
  });

  group('Uploads via picker', () {
    test('upload a photo', () async {
      print('Pick a photo to upload');
      final fileUri = await FileDownloader()
          .uri
          .pickFiles(startLocation: SharedStorage.images);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(1));
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl,
          uri: fileUri.first,
          post: 'binary',
          mimeType: 'image/jpeg');
      expect(task.usesUri, isTrue);
      expect(task.fileUri, equals(fileUri.first));
      expect(task.mimeType, equals('image/jpeg'));
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      print('filename=$filename');
      print('uri=$uri');
      expect(filename, isNotNull);
      expect(uri!.scheme, equals('content'));
      expect(uri.toString().contains(fileUri.first.toString()), isTrue);
    });

    test('pick multiple photos (no upload)', () async {
      print('Pick 2 photos');
      final fileUri = await FileDownloader().uri.pickFiles(
          startLocation: SharedStorage.images, multipleAllowed: true);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(2));
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: fileUri.first, post: 'binary');
      expect(task.usesUri, isTrue);
      expect(task.fileUri, equals(fileUri.first));
    });

    test('pick a video (no upload)', () async {
      print('Pick a video');
      final fileUri = await FileDownloader()
          .uri
          .pickFiles(startLocation: SharedStorage.video);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(1));
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: fileUri.first, post: 'binary');
      expect(task.usesUri, isTrue);
      expect(task.fileUri, equals(fileUri.first));
    });

    test('pick multiple videos (no upload)', () async {
      print('Pick 2 videos');
      final fileUri = await FileDownloader()
          .uri
          .pickFiles(startLocation: SharedStorage.video, multipleAllowed: true);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(2));
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: fileUri.first, post: 'binary');
      expect(task.usesUri, isTrue);
      expect(task.fileUri, equals(fileUri.first));
    });
  });
}
