import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

const tasksPath = 'backgroundDownloaderTaskRecords';
const databaseMetadataPath = 'backgroundDownloaderDatabase';

void main() {
  setUp(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      debugPrint(
          '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    });
    WidgetsFlutterBinding.ensureInitialized();
    for (var dir in [
      await getApplicationDocumentsDirectory(),
      await getApplicationSupportDirectory()
    ]) {
      try {
        Directory(path.join(dir.path, tasksPath)).deleteSync(recursive: true);
      } catch (e) {
        debugPrint('$dir tasksPath was already deleted');
      }
      try {
        Directory(path.join(dir.path, databaseMetadataPath))
            .deleteSync(recursive: true);
      } catch (e) {
        debugPrint('$dir databaseMetadataPath was already deleted');
      }
    }
    Localstore.instance.clearCache();
  });

  tearDown(() async {});

  testWidgets('migration from version 0', (widgetTester) async {
    final docDir = await getApplicationDocumentsDirectory();
    final supportDir = await getApplicationSupportDirectory();
    Directory(path.join(docDir.path, tasksPath)).createSync();
    await File(path.join(docDir.path, tasksPath, 'test'))
        .writeAsString('contents', flush: true);
    expect(
        File(path.join(docDir.path, tasksPath, 'test')).existsSync(), isTrue);
    final downloader = FileDownloader().downloaderForTesting;
    await Future.delayed(const Duration(milliseconds: 100));
    // file 'test' in docDir should have been moved to supportDir
    expect(
        File(path.join(docDir.path, tasksPath, 'test')).existsSync(), isFalse);
    expect(File(path.join(supportDir.path, tasksPath, 'test')).existsSync(),
        isTrue);
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
    expect(
        File(path.join(docDir.path, tasksPath, 'test2')).existsSync(), isTrue);
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
