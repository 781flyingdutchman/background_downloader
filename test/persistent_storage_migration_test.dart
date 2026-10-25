import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/src/localstore/localstore.dart';
import 'package:background_downloader/src/localstore/migration.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory supportDir;
  late Directory documentsDir;
  late LocalStoreMigration migration;
  final records = <LogRecord>[];
  var documentsLookups = 0;
  var documentsAvailable = false;
  var supportAvailable = true;
  Object? documentsError;

  setUpAll(() async {
    root = await Directory('.dart_tool').createTemp('storage_migration_test_');
    supportDir = Directory(path.join(root.absolute.path, 'support'));
    documentsDir = Directory(path.join(root.absolute.path, 'documents'));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        switch (call.method) {
          case 'getApplicationSupportDirectory':
            return supportAvailable ? supportDir.path : null;
          case 'getApplicationDocumentsDirectory':
            documentsLookups++;
            if (documentsError != null) throw documentsError!;
            return documentsAvailable ? documentsDir.path : null;
          default:
            throw StateError('Unexpected path lookup: ${call.method}');
        }
      },
    );
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await root.delete(recursive: true);
    });
  });

  setUp(() async {
    await Localstore.instance
        .collection(LocalStoreMigration.metaDataCollection)
        .doc('metaData')
        .delete();
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
    await supportDir.create(recursive: true);
    Localstore.instance.clearCache();
    migration = LocalStoreMigration(
      Localstore.instance,
      Logger('LocalStorePersistentStorageExecutor'),
    );
    records.clear();
    documentsLookups = 0;
    documentsAvailable = false;
    supportAvailable = true;
    documentsError = null;
  });

  test(
    'v0 migration initializes storage without a documents directory',
    () async {
      expect(await migration.storedDatabaseVersion, ('Localstore', 0));

      // A null platform response makes path_provider throw
      // MissingPlatformDirectoryException, as on Windows without Documents.
      await migration.initialize();

      expect(documentsLookups, 1);
      expect(
        await migration.storedDatabaseVersion,
        migration.currentDatabaseVersion,
      );
      final metadata = File(
        path.join(
          supportDir.path,
          LocalStoreMigration.metaDataCollection,
          'metaData',
        ),
      );
      expect(jsonDecode(await metadata.readAsString()), {'version': 1});
      expect(
        records.any(
          (record) =>
              record.loggerName == 'LocalStorePersistentStorageExecutor' &&
              record.message.contains('Skipping') &&
              record.message.contains('MissingPlatformDirectoryException'),
        ),
        isTrue,
      );

      // The recorded version prevents another documents lookup on startup.
      await migration.initialize();
      expect(documentsLookups, 1);
    },
  );

  test('v0 migration still moves all legacy collections', () async {
    documentsAvailable = true;
    const collections = [
      LocalStoreMigration.resumeDataPath,
      LocalStoreMigration.pausedTasksPath,
      LocalStoreMigration.taskRecordsPath,
    ];
    for (final collection in collections) {
      final directory = Directory(path.join(documentsDir.path, collection));
      await directory.create(recursive: true);
      await File(path.join(directory.path, 'record')).writeAsString(collection);
    }

    await migration.initialize();

    for (final collection in collections) {
      expect(
        await Directory(path.join(documentsDir.path, collection)).exists(),
        isFalse,
      );
      expect(
        await File(path.join(supportDir.path, collection, 'record'))
            .readAsString(),
        collection,
      );
    }
    expect(
      await migration.storedDatabaseVersion,
      migration.currentDatabaseVersion,
    );
  });

  test('v0 migration still propagates other documents lookup errors', () async {
    documentsError = PlatformException(code: 'unexpected_documents_error');

    await expectLater(
      migration.initialize(),
      throwsA(isA<PlatformException>()),
    );

    expect(await migration.storedDatabaseVersion, ('Localstore', 0));
    expect(
      records.any((record) => record.message.contains('Skipping')),
      isFalse,
    );
  });

  test('v0 migration still propagates missing support directory', () async {
    // Localstore has already resolved its database directory. Only the
    // migration's support-directory lookup should fail here.
    expect(await migration.storedDatabaseVersion, ('Localstore', 0));
    documentsAvailable = true;
    supportAvailable = false;

    await expectLater(
      migration.initialize(),
      throwsA(isA<MissingPlatformDirectoryException>()),
    );

    expect(await migration.storedDatabaseVersion, ('Localstore', 0));
    expect(
      records.any((record) => record.message.contains('Skipping')),
      isFalse,
    );
  });
}
