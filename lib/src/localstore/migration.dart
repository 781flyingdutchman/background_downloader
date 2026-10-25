import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'localstore.dart';

/// Migrates Localstore data before the storage executor starts handling requests.
class LocalStoreMigration {
  LocalStoreMigration(this._db, this.log);

  final Localstore _db;
  final Logger log;

  static const taskRecordsPath = 'backgroundDownloaderTaskRecords';
  static const resumeDataPath = 'backgroundDownloaderResumeData';
  static const pausedTasksPath = 'backgroundDownloaderPausedTasks';
  static const metaDataCollection = 'backgroundDownloaderDatabase';

  Future<(String, int)> get storedDatabaseVersion async {
    final metaData = await _db
        .collection(metaDataCollection)
        .doc('metaData')
        .get();
    return ('Localstore', (metaData?['version'] as num?)?.toInt() ?? 0);
  }

  (String, int) get currentDatabaseVersion => ('Localstore', 1);

  Future<void> initialize() async {
    final (currentName, currentVersion) = currentDatabaseVersion;
    final (storedName, storedVersion) = await storedDatabaseVersion;
    if (storedName != currentName) {
      log.warning('Cannot migrate from database name $storedName');
      return;
    }
    if (storedVersion == currentVersion) {
      return;
    }
    log.fine(
      'Migrating $currentName database from version $storedVersion to $currentVersion',
    );
    switch (storedVersion) {
      case 0:
        // move files from docDir to supportDir
        final Directory docDir;
        try {
          docDir = await getApplicationDocumentsDirectory();
        } on MissingPlatformDirectoryException catch (e) {
          log.fine('Skipping database migration from documents directory: $e');
          break;
        }
        final supportDir = await getApplicationSupportDirectory();
        await Future.wait(
          [resumeDataPath, pausedTasksPath, taskRecordsPath].map((path) async {
            try {
              final fromPath = join(docDir.path, path);
              if (await Directory(fromPath).exists()) {
                log.finest('Moving $path to support directory');
                final toPath = join(supportDir.path, path);
                await Directory(toPath).create(recursive: true);
                final entities = await Directory(fromPath).list().toList();
                await Future.wait(
                  entities.whereType<File>().map(
                    (file) => file.copy(join(toPath, basename(file.path))),
                  ),
                );
                await Directory(fromPath).delete(recursive: true);
              }
            } catch (e) {
              log.fine('Error migrating database for path $path: $e');
            }
          }),
        );

      default:
        log.warning('Illegal starting version: $storedVersion');
    }
    await _db.collection(metaDataCollection).doc('metaData').set({
      'version': currentVersion,
    });
  }
}
