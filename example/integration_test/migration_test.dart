import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localstore/localstore.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

const tasksPath = 'backgroundDownloaderTaskRecords';

void main() {
  setUp(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final supportDir = await getApplicationSupportDirectory();
    try {
      Directory(path.join(supportDir.path, tasksPath))
          .deleteSync(recursive: true);
    } catch (e) {
      debugPrint('applicationSupportDirectory tasksPath was already deleted');
    }
  });

  tearDown(() async {});

  testWidgets('migration', (widgetTester) async {
    final docDir = await getApplicationDocumentsDirectory();
    final supportDir = await getApplicationSupportDirectory();
    Directory(path.join(docDir.path, tasksPath)).createSync();
    await File(path.join(docDir.path, tasksPath, 'test'))
        .writeAsString('contents', flush: true);
    final downloader = FileDownloader().downloaderForTesting;
    await Future.delayed(const Duration(milliseconds: 100));
    expect(
        File(path.join(docDir.path, tasksPath, 'test')).existsSync(), isFalse);
    expect(File(path.join(supportDir.path, tasksPath, 'test')).existsSync(),
        isTrue);
    debugPrint(path.join(supportDir.path, tasksPath, 'test'));
    final metaData = await Localstore.instance
        .collection('backgroundDownloaderDatabase')
        .doc('metaData')
        .get();
    final version = metaData?['version'] ?? 0;
    expect(version, equals(1)); // BaseDownloader.databaseVersion
    // now initialize again
    // docDir and supportDir file should not be touched
    final file2 = File(path.join(docDir.path, tasksPath, 'test2'));
    Directory(path.join(docDir.path, tasksPath)).createSync();
    await file2.writeAsString('contents2');
    await downloader.initialize();
    expect(
        File(path.join(docDir.path, tasksPath, 'test2')).existsSync(), isTrue);
    expect(File(path.join(supportDir.path, tasksPath, 'test2')).existsSync(),
        isFalse);
    expect(File(path.join(supportDir.path, tasksPath, 'test')).existsSync(),
        isTrue);
    debugPrint('Migration done');
  });
}
