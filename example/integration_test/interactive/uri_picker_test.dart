// ignore_for_file: avoid_print, empty_catches

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_utils.dart';

void main() {
  setUp(defaultSetup);

  tearDown(defaultTearDown);

  group('Downloads via picker', () {
    test('download file using URI', () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uri.pickDirectory();
      print('directoryUri=$directoryUri');
      expect(directoryUri, isNotNull);
      final task =
          UriDownloadTask(url: workingUrl, directoryUri: directoryUri!);
      expect(
          allDigitsRegex.hasMatch(task.filename), isTrue); // filename omitted
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      expect(result.status, equals(TaskStatus.complete));
      final resultTask = result.task as UriDownloadTask;
      final filename = resultTask.filename;
      final fileUri = resultTask.fileUri!;
      print('Resulting filename: ${resultTask.filename}');
      print('Resulting file uri: $fileUri');
      expect(filename, equals(task.filename));
      if (Platform.isAndroid) {
        expect(fileUri.scheme, equals('content'));
      } else {
        expect(fileUri.scheme, equals('file'));
      }
      expect(fileUri.path, contains(filename));
      expect(fileUri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uri.deleteFile(fileUri), isTrue);
    });

    test('download file with suggested filename using URI', () async {
      print('Pick a directory to store a file to download');
      final directoryUri = await FileDownloader().uri.pickDirectory();
      expect(directoryUri, isNotNull);
      final task = UriDownloadTask(
          url: urlWithContentLength,
          directoryUri: directoryUri!,
          filename: DownloadTask.suggestedFilename);
      expect(task.filename, equals(DownloadTask.suggestedFilename));
      expect(task.directoryUri, equals(directoryUri));
      final result = await FileDownloader().download(task);
      print('Raw filename: ${result.task.filename}');
      expect(result.status, equals(TaskStatus.complete));
      final resultTask = result.task as UriDownloadTask;
      final filename = resultTask.filename;
      final fileUri = resultTask.fileUri!;
      print('Resulting filename: ${resultTask.filename}');
      print('Resulting file uri: $fileUri');
      expect(filename, equals('5MB-test.ZIP'));
      if (Platform.isAndroid) {
        expect(fileUri.scheme, equals('content'));
      } else {
        expect(fileUri.scheme, equals('file'));
      }
      expect(fileUri.path, contains(filename));
      expect(fileUri.toString().contains(directoryUri.toString()), isTrue);
      expect(await FileDownloader().uri.deleteFile(fileUri), isTrue);
    });
  });

  group('Uploads via photo/video picker', () {
    test('upload a photo', () async {
      print('Pick a photo to upload');
      final fileUri = await FileDownloader()
          .uri
          .pickFiles(startLocation: SharedStorage.images);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(1));
      print(fileUri.first);
      final task = UriUploadTask(
          url: uploadBinaryTestUrl,
          fileUri: fileUri.first,
          post: 'binary',
          mimeType: 'image/jpeg');
      expect(task.fileUri, equals(fileUri.first));
      expect(task.mimeType, equals('image/jpeg'));
      final result = await FileDownloader().upload(task);
      expect(result.status, equals(TaskStatus.complete));
      final resultTask = result.task as UriUploadTask;
      final filename = resultTask.filename;
      final uri = resultTask.fileUri!;
      print('Resulting filename: ${resultTask.filename}');
      print('Resulting file uri: $uri');
      expect(filename, isNotNull);
      if (Platform.isAndroid) {
        expect(uri.scheme, equals('content'));
      } else {
        expect(uri.scheme, equals('file'));
      }
      if (!Platform.isIOS) {
        expect(uri.toString().contains(fileUri.first.toString()), isTrue);
      } else {
        // on iOS, delete the local copy of the file
        expect(await FileDownloader().uri.deleteFile(uri), isTrue);
      }
    });

    test('pick single photo (no upload) using pickFile', () async {
      print('Pick a photo to upload');
      final fileUri = await FileDownloader()
          .uri
          .pickFile(startLocation: SharedStorage.images);
      expect(fileUri, isNotNull);
      print(fileUri);
      if (Platform.isIOS) {
        // on iOS, delete the local copy of the file
        expect(await FileDownloader().uri.deleteFile(fileUri!), isTrue);
      }
    });

    test('pick multiple photos (no upload)', () async {
      print('Pick 2 photos');
      final fileUris = await FileDownloader().uri.pickFiles(
          startLocation: SharedStorage.images, multipleAllowed: true);
      expect(fileUris, isNotNull);
      expect(fileUris!.length, equals(2));
      print(fileUris);
      final task = UriUploadTask(
          url: uploadBinaryTestUrl, fileUri: fileUris.first, post: 'binary');
      expect(task.fileUri, equals(fileUris.first));
      if (Platform.isIOS) {
        // on iOS, delete the local copies of the files
        for (final uri in fileUris) {
          expect(await FileDownloader().uri.deleteFile(uri), isTrue);
        }
      }
    });

    test('pick a video (no upload)', () async {
      print('Pick a video');
      final fileUri = await FileDownloader()
          .uri
          .pickFiles(startLocation: SharedStorage.video);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(1));
      final task = UriUploadTask(
          url: uploadBinaryTestUrl, fileUri: fileUri.first, post: 'binary');
      expect(task.fileUri, equals(fileUri.first));
    });

    test('pick multiple videos (no upload)', () async {
      print('Pick 2 videos');
      final fileUri = await FileDownloader()
          .uri
          .pickFiles(startLocation: SharedStorage.video, multipleAllowed: true);
      expect(fileUri, isNotNull);
      expect(fileUri!.length, equals(2));
      final task = UriUploadTask(
          url: uploadBinaryTestUrl, fileUri: fileUri.first, post: 'binary');
      expect(task.fileUri, equals(fileUri.first));
    });
  });

  test('Persistence', () async {
    print('Pick a directory to store a file to download');
    final directoryUri =
        await FileDownloader().uri.pickDirectory(persistedUriPermission: true);
    print('directoryUri=$directoryUri');
    expect(directoryUri, isNotNull);
    if (Platform.isIOS) {
      expect(directoryUri!.scheme, equals('urlbookmark'));
    }
    final task = UriDownloadTask(url: workingUrl, directoryUri: directoryUri!);
    expect(allDigitsRegex.hasMatch(task.filename), isTrue); // filename omitted
    expect(task.directoryUri, equals(directoryUri));
    final result = await FileDownloader().download(task);
    expect(result.status, equals(TaskStatus.complete));
    final resultTask = result.task as UriDownloadTask;
    final filename = resultTask.filename;
    final uri = resultTask.fileUri!;
    print('Resulting filename: ${resultTask.filename}');
    print('Resulting file uri: $uri');
    expect(filename, equals(task.filename));
    if (Platform.isAndroid) {
      expect(uri.scheme, equals('content'));
    } else {
      expect(uri.scheme, equals('file'));
    }
    expect(uri.path, contains(filename));
    expect(await FileDownloader().uri.deleteFile(uri), isTrue);
  });

  test('Activate URI', () async {
    print('Pick a photo to upload');
    final fileUri = await FileDownloader()
        .uri
        .pickFile(startLocation: SharedStorage.images);
    print('Uri from picker: ${fileUri!}');
    if (Platform.isIOS) {
      expect(fileUri.scheme, equals('media'));
    }
    final activatedUri = await FileDownloader().uri.activate(fileUri);
    if (!Platform.isIOS) {
      expect(activatedUri, equals(fileUri));
    }
    print('Activated uri: ${activatedUri!}');
    if (!Platform.isAndroid) {
      expect(activatedUri.scheme, equals('file'));
      final file = File.fromUri(activatedUri);
      expect(file.existsSync(), isTrue);
      file.deleteSync();
    } else {
      // on Android, expect the original Uri
      expect(activatedUri, equals(fileUri));
    }
  });
}
