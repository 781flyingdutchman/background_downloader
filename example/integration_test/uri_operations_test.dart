// ignore_for_file: avoid_print, empty_catches

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'test_utils.dart';

void main() {
  setUp(defaultSetup);

  tearDown(defaultTearDown);

  group('Binary uploads', () {
    test('enqueue binary file using URI', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      // move file to shared storage and obtain the URI
      final dummy = DownloadTask(url: uploadTestUrl, filename: uploadFilename);
      final uri = await FileDownloader()
          .uri
          .moveToSharedStorage(dummy, SharedStorage.downloads);
      print('URI: $uri');
      final task = UploadTask.fromUri(
          url: uploadBinaryTestUrl, uri: uri!, post: 'binary');
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
    });

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

    test('upload with fileUrl', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      Directory directory = await getApplicationDocumentsDirectory();
      final uploadPath = p.join(directory.path, uploadFilename);
      final task = UploadTask.fromUri(
          uri: Uri.file(uploadPath),
          url: uploadBinaryTestUrl,
          post: 'binary',
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(progressComplete));
      final (:filename, :uri) = UriUtils.unpack(lastTaskWithStatus!.filename);
      print('filename=$filename, uri=$uri');
      expect(filename, equals(uploadFilename));
      expect(uri!.scheme, equals('file'));
      expect(lastTaskWithStatus!.fileUri!.scheme, equals('file'));
      expect(lastTaskWithStatus!.uriFilename, equals(uploadFilename));
      print('Finished upload with fileUrl');
    });

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
      final uri = await FileDownloader()
          .uri
          .moveToSharedStorage(dummy, SharedStorage.downloads);
      print('URI: $uri');
      final task = UploadTask.fromUri(url: uploadBinaryTestUrl, uri: uri!);
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
      final uri = await FileDownloader()
          .uri
          .moveToSharedStorage(dummy, SharedStorage.downloads);
      // move second file to shared storage and obtain the URI
      final dummy2 =
          DownloadTask(url: uploadTestUrl, filename: uploadFilename2);
      final uri2 = await FileDownloader()
          .uri
          .moveToSharedStorage(dummy2, SharedStorage.downloads);
      final task = MultiUploadTask(
          url: uploadMultiTestUrl,
          files: [('f1', uri), ('f2', uri2)],
          fields: {'key': 'value'});
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
      expect(task.filename, equals(DownloadTask.suggestedFilename));
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

    test('Download and pause/resume file with suggested filename', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final directory = await getApplicationDocumentsDirectory();
      final directoryUri = Uri.file(directory.path);
      task = DownloadTask.fromUri(
          url: urlWithContentLength,
          directoryUri: directoryUri,
          filename: DownloadTask.suggestedFilename,
          allowPause: true,
          updates: Updates.statusAndProgress);
      expect(task.usesUri, isTrue);
      expect(task.filename, equals(DownloadTask.suggestedFilename));
      expect(task.directoryUri, equals(directoryUri));
      expect(await FileDownloader().enqueue(task), isTrue);
      await someProgressCompleter.future;
      expect(await FileDownloader().pause(task), isTrue);
      if (!Platform.isAndroid) {
        // on Android the pause will not happen in URI mode,
        // so the following test is only for non-Android
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));
        print("paused");
        await Future.delayed(const Duration(seconds: 2));
        // resume
        expect(await FileDownloader().resume(task), isTrue);
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.complete));
        expect(lastTaskWithStatus, isNotNull);
        var file = File(await lastTaskWithStatus!.filePath());
        print('File path: ${file.path}');
        expect(await fileEqualsLargeTestFile(file), isTrue);
        await file.delete();
      } else {
        // on Android, the task will fail when attempting to pause, using URI
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.failed));
      }
    });
  });

  group('Downloads via picker', () {
    test('download file using URI', () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uri.pickDirectory();
      print('directoryUri=$directoryUri');
      expect(directoryUri, isNotNull);
      task = DownloadTask.fromUri(url: workingUrl, directoryUri: directoryUri!);
      expect(task.usesUri, isTrue);
      expect(
          allDigitsRegex.hasMatch(task.filename), isTrue); // filename omitted
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      print('Raw filename: ${result.task.filename}');
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      print('Resulting file uri: $uri');
      expect(filename, equals(task.filename));
      if (Platform.isAndroid) {
        expect(uri!.scheme, equals('content'));
      } else {
        expect(uri!.scheme, equals('file'));
      }
      expect(uri.path, contains(filename));
      expect(uri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uri.deleteFile(uri), isTrue);
    });

    test('download file with suggested filename using URI', () async {
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
      print('Raw filename: ${result.task.filename}');
      expect(result.status, equals(TaskStatus.complete));
      var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      print('Resulting file uri: $uri');
      expect(filename, equals('5MB-test.ZIP'));
      if (Platform.isAndroid) {
        expect(uri!.scheme, equals('content'));
      } else {
        expect(uri!.scheme, equals('file'));
      }
      expect(uri.path, contains(filename));
      expect(uri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uri.deleteFile(uri), isTrue);
    });
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
      // final result = await FileDownloader().upload(task);
      // expect(result.status, equals(TaskStatus.complete));
      // var (:filename, :uri) = UriUtils.unpack(result.task.filename);
      // print('filename=$filename');
      // print('uri=$uri');
      // expect(filename, isNotNull);
      // expect(uri!.scheme, equals('content'));
      // expect(uri.toString().contains(fileUri.first.toString()), isTrue);
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

  group('Other utils', () {
    testWidgets('open file from URI', (widgetTester) async {
      // move file to shared storage and obtain the URI
      final dummy = DownloadTask(url: uploadTestUrl, filename: uploadFilename);
      final uri = await FileDownloader()
          .uri
          .moveToSharedStorage(dummy, SharedStorage.downloads);
      print('URI: $uri');
      final result =
          await FileDownloader().uri.openFile(uri!, mimeType: 'text/plain');
      expect(result, isTrue);
      await Future.delayed(const Duration(seconds: 2));
    });
  });

  test('move task to shared storage with file URI', () async {
    // note: moved file is not deleted in this test
    var filePath = await task.filePath();
    await FileDownloader().download(task);
    expect(File(filePath).existsSync(), isTrue);
    final fileUri = Uri.file(filePath);
    final uri = await FileDownloader()
        .uri
        .moveFileToSharedStorage(fileUri, SharedStorage.downloads);
    print('Uri is $uri');
    expect(uri, isNotNull);
    if (Platform.isAndroid) {
      expect(uri!.scheme, equals('content'));
    } else {
      expect(uri!.scheme, equals('file'));
    }
    expect(File(filePath).existsSync(), isFalse);
  });

  testWidgets('path in shared storage with file URI',
      //TODO not sure this test works properly
      // note: moved file is not deleted in this test
      (widgetTester) async {
    await FileDownloader().download(task);
    final uri = await FileDownloader()
        .uri
        .moveToSharedStorage(task, SharedStorage.downloads);
    print('Uri is $uri');
    expect(uri, isNotNull);
    if (uri!.scheme == 'file') {
      expect(uri.toFile().existsSync(), isTrue);

      final uri2 = await FileDownloader()
          .uri
          .pathInSharedStorage(uri, SharedStorage.downloads);
      print('Uri is $uri');
      expect(uri2, isNotNull);
      expect(uri2?.scheme, equals('content'));
    }
  });
}
