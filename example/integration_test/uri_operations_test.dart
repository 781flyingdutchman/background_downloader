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
      print('fileUri: $uri');
      final task = UriUploadTask(
          url: uploadBinaryTestUrl, fileUri: uri!, post: 'binary');
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      final resultTask = lastTaskWithStatus as UriUploadTask;
      expect(resultTask.fileUri, equals(uri));
      // match filename on first characters only, given unique numbering
      expect(resultTask.filename.substring(0, 6),
          equals(uploadFilename.substring(0, 6)));
    });

    test('upload binary file using incorrect Android content URI', () async {
      final task = UriUploadTask(
          url: uploadBinaryTestUrl,
          fileUri: Uri.parse('content://some/invalid/path'),
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
      final task = UriUploadTask(
          fileUri: Uri.file(uploadPath),
          url: uploadBinaryTestUrl,
          post: 'binary',
          updates: Updates.statusAndProgress);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
      expect(progressCallbackCounter, greaterThan(1));
      expect(lastProgress, equals(progressComplete));
      expect((lastTaskWithStatus as UriUploadTask).fileUri!.scheme,
          equals('file'));
      expect(lastTaskWithStatus!.filename, equals(uploadFilename));
      print('Finished upload with fileUrl');
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
      final task = UriUploadTask(url: uploadTestUrl, fileUri: uri!);
      expect(await FileDownloader().enqueue(task), isTrue);
      await statusCallbackCompleter.future;
      expect(statusCallbackCounter, equals(3));
      expect(lastStatus, equals(TaskStatus.complete));
    }, skip: !Platform.isAndroid);

    test('upload multipart file using incorrect Android content URI', () async {
      final task = UriUploadTask(
          url: uploadMultiTestUrl,
          fileUri: Uri.parse('content://some/invalid/path'));
      final result = await FileDownloader().upload(task);
      print(result.exception?.description);
      expect(result.status, equals(TaskStatus.failed));
      expect(
          result.exception?.exceptionType, equals('TaskFileSystemException'));
    }, skip: !Platform.isAndroid);

    test('upload single multipart file using file URI', () async {
      final filePath = await uploadTask.filePath();
      final fileUri = Uri.file(filePath);
      final task = UriUploadTask(url: uploadTestUrl, fileUri: fileUri);
      expect(task.fileUri, equals(fileUri));
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      var resultTask = result.task as UriUploadTask;
      expect((resultTask).fileUri, equals(fileUri));
      expect(resultTask.filename, equals(uploadTask.filename));
      expect((resultTask).directoryUri, isNull);
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

    test('multiUpload using file uris', () async {
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
      final task = UriDownloadTask(url: workingUrl, directoryUri: directoryUri);
      expect(
          allDigitsRegex.hasMatch(task.filename), isTrue); // filename omitted
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      final resultTask = result.task as UriDownloadTask;
      print('filename=${resultTask.filename}');
      var fileUri = resultTask.fileUri!;
      print('uri=$fileUri');
      expect(resultTask.filename, equals(task.filename));
      expect(fileUri.scheme, equals('file'));
      expect(fileUri.path, contains(resultTask.filename));
      expect(fileUri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uri.deleteFile(fileUri), isTrue);
    });

    test('download file with suggested filename', () async {
      final directory = await getApplicationDocumentsDirectory();
      final directoryUri = Uri.file(directory.path);
      final task = UriDownloadTask(
          url: urlWithContentLength,
          directoryUri: directoryUri,
          filename: DownloadTask.suggestedFilename);
      expect(task.filename, equals(DownloadTask.suggestedFilename));
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      final resultTask = result.task as UriDownloadTask;
      final filename = resultTask.filename;
      final fileUri = resultTask.fileUri!;
      print('uri=$fileUri');
      print('filename=$filename');
      expect(filename, equals('5MB-test.ZIP'));
      expect(fileUri.scheme, equals('file'));
      expect(fileUri.path, contains(filename));
      expect(fileUri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uri.deleteFile(fileUri), isTrue);
    });

    test('Download and pause/resume file with suggested filename', () async {
      FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback);
      final directory = await getApplicationDocumentsDirectory();
      final directoryUri = Uri.file(directory.path);
      final task = UriDownloadTask(
          url: urlWithContentLength,
          directoryUri: directoryUri,
          filename: DownloadTask.suggestedFilename,
          allowPause: true,
          updates: Updates.statusAndProgress);
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

  group('File utils', () {
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
        print('Uri2 is $uri2');
        expect(uri2, isNotNull);
        expect(uri2?.scheme, equals('file'));
      } else {
        // for content Uri, the function should throw an AssertionError
        expect(uri.scheme == 'content', isTrue); // Android
        expect(
            () async => await FileDownloader()
                .uri
                .pathInSharedStorage(uri, SharedStorage.downloads),
            throwsAssertionError);
      }
    });

    test('createDirectory', () async {
      const testDir = 'testDir';
      const testSubDir = 'testSubDir';
      const multiLevelDirName = 'test/Dir';

      // Test creating a directory in the temporary directory
      final tempDir = await getTemporaryDirectory();
      final tempDirUri = tempDir.uri;

      // Ensure directories are deleted before starting the test
      final testDirPath = p.join(tempDir.path, testDir);
      final testDirDirectory = Directory(testDirPath);
      if (testDirDirectory.existsSync()) {
        testDirDirectory.deleteSync(recursive: true);
      }

      final multiLevelDirPath = p.join(tempDir.path, 'test');
      final multiLevelDir = Directory(multiLevelDirPath);
      if (multiLevelDir.existsSync()) {
        multiLevelDir.deleteSync(recursive: true);
      }

      final newDirUri =
          await FileDownloader().uri.createDirectory(tempDirUri, testDir);
      print('newDirUri: $newDirUri');
      expect(newDirUri, isNotNull);
      expect(newDirUri.scheme, 'file'); // Expect file scheme now
      expect(Directory.fromUri(newDirUri).existsSync(), isTrue);

      // Test creating a subdirectory within the newly created directory
      final newSubDirUri =
          await FileDownloader().uri.createDirectory(newDirUri, testSubDir);

      expect(newSubDirUri, isNotNull);
      expect(newSubDirUri.scheme, 'file'); // Expect file scheme
      expect(Directory.fromUri(newSubDirUri).existsSync(), isTrue);

      // Test creating a multi-level directory
      final multiLevelDirUri = await FileDownloader()
          .uri
          .createDirectory(tempDirUri, multiLevelDirName);
      expect(multiLevelDirUri, isNotNull);
      expect(multiLevelDirUri.scheme, 'file'); // Expect file scheme

      // Verify that both directories in the path were created
      final multiLevelDirCreated = Directory.fromUri(multiLevelDirUri);
      expect(multiLevelDirCreated.existsSync(), isTrue);
      expect(Directory(p.join(tempDir.path, 'test')).existsSync(), isTrue);

      // Ensure directories are deleted after test is complete
      if (testDirDirectory.existsSync()) {
        testDirDirectory.deleteSync(recursive: true);
      }
      if (multiLevelDir.existsSync()) {
        multiLevelDir.deleteSync(recursive: true);
      }
    });

    test('getFileBytes with file URI', () async {
      // Create a dummy file
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, 'testFile.txt'));
      await file.writeAsString('Test file content');
      // Get file bytes using the file URI
      final fileUri = file.uri;
      final bytes = await FileDownloader().uri.getFileBytes(fileUri);
      expect(bytes, isNotNull);
      expect(String.fromCharCodes(bytes!), 'Test file content');
      // Clean up
      await file.delete();
    });

    test('deleteFile with file URI', () async {
      // Create a dummy file
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, 'testFile.txt'));
      await file.writeAsString('Test file content');
      // Delete the file using the file URI
      final fileUri = file.uri;
      final success = await FileDownloader().uri.deleteFile(fileUri);
      expect(success, isTrue);
      expect(file.existsSync(), isFalse);
    });
  });
}
