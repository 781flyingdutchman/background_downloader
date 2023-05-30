
import 'localstore/localstore.dart';

typedef JsonMap = Map<String, dynamic>;

const metaDataCollection = 'backgroundDownloaderDatabase';

/// Interface for the persistent storage used to back the downloader
///
/// [PersistentStorage] uses the 'collection' & 'document' concepts,
/// where a collection is a named collection of documents, and a document
/// is a Map<String, dynamic> representing an object (i.e. a [JsonMap]).
/// Each object must have a unique String identifier.
///
/// The JsonMap must contain only simple JSON objects, such that a call
/// to jsonEncode encodes it without errors
abstract interface class PersistentStorage {



  /// Identifier for this type of persistent storage, used for
  /// database migration
  String get storageName;

  /// Version number of database code, used for database migration
  int get databaseVersion;

  /// Version number of database as stored, used for database migration
  Future<int> get storedDatabaseVersion;

  /// Migrate the data from this [fromStorageName] and [fromVersion] to
  /// our current [storageName] and [databaseVersion]
  ///
  /// Returns true if successful. If not successful, the old data
  /// may not have been migrated, but the new version will still work
  Future<bool> migrate(String fromStorageName, [int? fromVersion]);

  /// Store the [document] in the [collection] under [identifier]
  ///
  /// Returns true if successful
  Future<bool> store(JsonMap document, String collection, String identifier);

  /// Retrieve the document with [identifier] from the [collection]
  ///
  /// Returns the document as a [JsonMap], or null if not successful
  Future<JsonMap?> retrieve(String collection, String identifier);

  /// Retrieve all documents in this [collection]
  ///
  /// Returns a [JsonMap] where the keys are the document identifiers
  /// and the values are the documents themselves, as a [JsonMap].
  ///
  /// The returned Map is empty if the collection does not exist, or
  /// if it is empty
  Future<JsonMap> retrieveAll(String collection);

  /// Delete the [collection] or the document with [identifier] in the
  /// collection.
  ///
  /// Returns true is successful
  Future<bool> delete(String collection, [String? identifier]);

}

class LocalStorePersistentStorage implements PersistentStorage {

  final _db = Localstore.instance;

  @override
  Future<bool> store(JsonMap document, String collection, String identifier)
  async {
    await _db.collection(collection).doc(identifier).set(document);
    return true;
  }

  @override
  Future<JsonMap?> retrieve(String collection, String identifier) => _db
      .collection(collection).doc(identifier).get();

  @override
  Future<JsonMap> retrieveAll(String collection) async {
    return await _db.collection(collection).get() ?? {};
  }

  @override
  Future<bool> delete(String collection, [String? identifier]) async {
    if (identifier == null) {
      await _db.collection(collection).delete();
    } else {
      await _db.collection(collection).doc(identifier).delete();
    }
    return true;
  }

  @override
  Future<bool> migrate(String fromStorageName, [int? fromVersion]) {
    // TODO: implement migrate
    throw UnimplementedError();
  }

  @override
  String get storageName => 'LocalStore';

  @override
  int get databaseVersion => 1;

  @override
  Future<int> get storedDatabaseVersion async {
    final metaData =
        await _db.collection(metaDataCollection).doc('metaData').get();
    return metaData?['version'] as int? ?? 0;
  }
}