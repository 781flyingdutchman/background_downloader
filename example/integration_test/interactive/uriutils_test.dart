// ignore_for_file: avoid_print, empty_catches

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('pickers and directory functions', () {
    late Directory documentsDir;
    late UriUtils uriUtils;

    setUp(() async {
      documentsDir = await getApplicationDocumentsDirectory();
      uriUtils = FileDownloader().uri;
    });

    tearDown(() async {
      // Clean up any created directories after each test
      final testDirectory = Directory(p.join(documentsDir.path, 'testDir'));
      if (await testDirectory.exists()) {
        await testDirectory.delete(recursive: true);
      }
    });

    testWidgets('pickDirectory with null startLocation -> pick Documents',
        (WidgetTester tester) async {
      final pickedDirUri = await uriUtils.pickDirectory();
      print(pickedDirUri);
    });

    testWidgets(
        'pickDirectory with null startLocation, then new directory and pick again',
        (WidgetTester tester) async {
      final pickedDirUri = await uriUtils.pickDirectory();
      print(pickedDirUri);
      final newDirUri = await uriUtils.createDirectory(pickedDirUri!, 'NewDir');
      expect(newDirUri, isNotNull);
      expect(newDirUri.toString(), contains('NewDir'));
      print(newDirUri);
      final pick2DirUri =
          await uriUtils.pickDirectory(startLocationUri: newDirUri);
      print(pick2DirUri);
      expect(pick2DirUri, isNotNull);
      expect(pick2DirUri.toString(), contains('NewDir'));
    });

    testWidgets(
        'pickDirectory with SharedStorage.images startLocation -> pick Images',
        (WidgetTester tester) async {
      final pickedDirUri =
          await uriUtils.pickDirectory(startLocation: SharedStorage.images);
      expect(
          pickedDirUri?.toString(),
          equals(
              'content://com.android.externalstorage.documents/tree/primary%3APictures'));
    },
        // Some tests could require some manual setup as the SAF can behave in unexpected ways
        skip: false);

    testWidgets('pickFiles with null startLocation and extensions',
        (WidgetTester tester) async {
      final pickedFilesUri = await uriUtils
          .pickFiles(allowedExtensions: ['jpg'], multipleAllowed: false);
      expect(pickedFilesUri, isNotNull);
      print(
          'Picked ${pickedFilesUri!.length} files: ${pickedFilesUri.map((uri) => uri.toString()).join(', ')}');
    }, skip: false);

    testWidgets(
        'pickFiles with null startLocation then create new dir and pick again',
        (WidgetTester tester) async {
      final pickedDirUri = await uriUtils.pickDirectory();
      final newDirUri = await uriUtils.createDirectory(pickedDirUri!, 'NewDir');
      expect(newDirUri, isNotNull);
      expect(newDirUri.toString(), contains('NewDir'));
      final pickedFilesUri =
          await uriUtils.pickFiles(startLocationUri: newDirUri);
      expect(pickedFilesUri, isNotNull);
      print(
          'Picked ${pickedFilesUri!.length} files: ${pickedFilesUri.map((uri) => uri.toString()).join(', ')}');
    }, skip: false);

    testWidgets('pickFiles with SharedStorage.images and no extensions',
        (WidgetTester tester) async {
      final pickedFilesUri = await uriUtils.pickFiles(
          startLocation: SharedStorage.images, multipleAllowed: false);
      expect(pickedFilesUri, isNotNull);
      print(
          'Picked ${pickedFilesUri!.length} files: ${pickedFilesUri.map((uri) => uri.toString()).join(', ')}');
    },
        // Some tests could require some manual setup as the SAF can behave in unexpected ways
        skip: false);

    testWidgets('pickFiles and get the file data (bytes)',
        (WidgetTester tester) async {
      final pickedFilesUri = await uriUtils.pickFiles();
      expect(pickedFilesUri, isNotNull);
      print(
          'Picked ${pickedFilesUri!.length} files: ${pickedFilesUri.map((uri) => uri.toString()).join(', ')}');
      final bytes = await uriUtils.getFileBytes(pickedFilesUri.first);
      expect(bytes, isNotNull);
      print('File data: ${bytes!.length} bytes');
    }, skip: false);

    testWidgets('pickFiles and get the file data (bytes) with persistence',
        (WidgetTester tester) async {
      final pickedFilesUri =
          await uriUtils.pickFiles(persistedUriPermission: true);
      expect(pickedFilesUri, isNotNull);
      print(
          'Picked ${pickedFilesUri!.length} files: ${pickedFilesUri.map((uri) => uri.toString()).join(', ')}');
      final bytes = await uriUtils.getFileBytes(pickedFilesUri.first);
      expect(bytes, isNotNull);
      print('File data: ${bytes!.length} bytes');
    }, skip: false);

    testWidgets('createDirectory with single level',
        (WidgetTester tester) async {
      final testDirUri =
          await uriUtils.pickDirectory(); // must be created from picker
      final newDirUri = await uriUtils.createDirectory(testDirUri!, 'testDir');
      expect(newDirUri, isNotNull);
      expect(newDirUri.toString(), contains('testDir'));
      print(newDirUri.toString());
    });

    testWidgets('createDirectory with multiple levels',
        (WidgetTester tester) async {
      final testDirUri =
          await uriUtils.pickDirectory(); // must be created from picker
      final newDirUri =
          await uriUtils.createDirectory(testDirUri!, 'testDir/level2/level3');

      expect(newDirUri, isNotNull);
      print(newDirUri.toString());
      expect(newDirUri.toString(), contains('testDir%2Flevel2%2Flevel3'));
    });

    testWidgets('createDirectory with leading/trailing separators',
        (WidgetTester tester) async {
      final testDirUri =
          await uriUtils.pickDirectory(); // must be created from picker
      final newDirUri =
          await uriUtils.createDirectory(testDirUri!, '/testDir/level2/');
      expect(newDirUri, isNotNull);
      print(newDirUri.toString());
      expect(newDirUri.toString(), contains('testDir%2Flevel2'));
    });

    testWidgets('pickFiles returns null when cancelled',
        (WidgetTester tester) async {
      // This test simulates user cancellation by returning null from the native side
      final result = await uriUtils.pickFiles();
      expect(result, isNull);
    }, skip: false);
  });
}
