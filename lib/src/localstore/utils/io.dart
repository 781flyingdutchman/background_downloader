import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../localstore.dart';
import 'utils_impl.dart';
import 'package:logging/logging.dart';

final _log = Logger('Localstore');

final class Utils implements UtilsImpl {
  Utils._();

  static final Utils _utils = Utils._();
  static final lastPathComponentRegEx = RegExp(r'[^/\\]+[/\\]?$');

  static Utils get instance => _utils;
  final _storageCache = <String, StreamController<Map<String, dynamic>>>{};
  final _fileCache = <String, File>{};

  /// Clears the cache
  @override
  void clearCache() {
    _storageCache.clear();
    _fileCache.clear();
  }

  @override
  Future<Map<String, dynamic>?> get(String path,
      [bool? isCollection = false, List<List>? conditions]) async {
    // Fetch the documents for this collection
    if (isCollection != null && isCollection == true) {
      final dbDir = await Localstore.instance.databaseDirectory;
      final fullPath = '${dbDir.path}$path';
      final dir = Directory(fullPath);
      if (!await dir.exists()) {
        return {};
      }
      List<FileSystemEntity> entries =
          await dir.list(recursive: false).toList();
      return await _getAll(entries.whereType<File>().toList());
    } else {
      try {
        // Reads the document referenced by this [DocumentRef].
        final file = await _getFile(path);
        final randomAccessFile = await file!.open(mode: FileMode.append);
        final data = await _readFile(randomAccessFile);
        await randomAccessFile.close();
        if (data is Map<String, dynamic>) {
          final key = path.replaceAll(lastPathComponentRegEx, '');
          // ignore: close_sinks
          final storage = _storageCache.putIfAbsent(key, () => _newStream(key));
          storage.add(data);
          return data;
        }
      } on PathNotFoundException {
        // return null if not found
      }
    }
    return null;
  }

  @override
  Future<dynamic>? set(Map<String, dynamic> data, String path) {
    return _writeFile(data, path);
  }

  @override
  Future delete(String path) async {
    if (path.endsWith(Platform.pathSeparator)) {
      await _deleteDirectory(path);
    } else {
      await _deleteFile(path);
    }
  }

  @override
  Stream<Map<String, dynamic>> stream(String path, [List<List>? conditions]) {
    // ignore: close_sinks
    var storage = _storageCache[path];
    if (storage == null) {
      storage = _storageCache.putIfAbsent(path, () => _newStream(path));
    } else {
      _initStream(storage, path);
    }
    return storage.stream;
  }

  Future<Map<String, dynamic>?> _getAll(List<FileSystemEntity> entries) async {
    final items = <String, dynamic>{};
    final dbDir = await Localstore.instance.databaseDirectory;
    await Future.wait(entries.map((e) async {
      final path = e.path.replaceAll(dbDir.path, '');
      final file = await _getFile(path);
      try {
        final randomAccessFile = await file!.open(mode: FileMode.append);
        final data = await _readFile(randomAccessFile);
        await randomAccessFile.close();

        if (data is Map<String, dynamic>) {
          items[path] = data;
        }
      } on PathNotFoundException {
        // ignore if not found
      }
    }));

    if (items.isEmpty) return null;
    return items;
  }

  /// Streams all file in the path
  StreamController<Map<String, dynamic>> _newStream(String path) {
    final storage = StreamController<Map<String, dynamic>>.broadcast();
    _initStream(storage, path);

    return storage;
  }

  Future _initStream(
    StreamController<Map<String, dynamic>> storage,
    String path,
  ) async {
    final dbDir = await Localstore.instance.databaseDirectory;
    final fullPath = '${dbDir.path}$path';
    final dir = Directory(fullPath);
    try {
      if (await dir.exists()) {
        final entries = await dir.list(recursive: false).toList();
        await Future.wait(entries.whereType<File>().map((e) async {
          final path = e.path.replaceAll(dbDir.path, '');
          final file = await _getFile(path);
          final randomAccessFile = await file!.open(mode: FileMode.append);
          final data = await _readFile(randomAccessFile);
          await randomAccessFile.close();
          if (data is Map<String, dynamic>) {
            storage.add(data);
          }
        }));
      }
    } catch (e) {
      return e;
    }
  }

  Future<dynamic> _readFile(RandomAccessFile file) async {
    try {
      await file.lock(FileLock.blockingShared);
      try {
        final length = await file.length();
        await file.setPosition(0);
        final buffer = Uint8List(length);
        await file.readInto(buffer);

        final contentText = utf8.decode(buffer);
        final data = json.decode(contentText) as Map<String, dynamic>;
        return data;
      } finally {
        await file.unlock();
      }
    } catch (e) {
      return e;
    }
  }

  Future<File?> _getFile(String path) async {
    if (_fileCache.containsKey(path)) return _fileCache[path];

    final dbDir = await Localstore.instance.databaseDirectory;

    final file = File('${dbDir.path}$path');

    if (!await file.exists()) {
      try {
        await file.create(recursive: true);
      } catch (e) {
        // Retry once in case of race condition with concurrent delete
        try {
          await file.create(recursive: true);
        } catch (e) {
           _log.warning('Failed to create file $path: $e');
        }
      }
    }
    _fileCache.putIfAbsent(path, () => file);

    return file;
  }

  Future _writeFile(Map<String, dynamic> data, String path) async {
    final serialized = json.encode(data);
    final buffer = utf8.encode(serialized);
    final file = await _getFile(path);
    try {
      final randomAccessFile = await file!.open(mode: FileMode.append);
      try {
        await randomAccessFile.lock(FileLock.blockingExclusive);
        try {
          await randomAccessFile.setPosition(0);
          await randomAccessFile.writeFrom(buffer);
          await randomAccessFile.truncate(buffer.length);
        } finally {
          await randomAccessFile.unlock();
        }
      } finally {
        await randomAccessFile.close();
      }
    } on PathNotFoundException {
      // ignore if path not found
    }
    final key = path.replaceAll(lastPathComponentRegEx, '');
    // ignore: close_sinks
    final storage = _storageCache.putIfAbsent(key, () => _newStream(key));
    storage.add(data);
  }

  Future _deleteFile(String path) async {
    final dbDir = await Localstore.instance.databaseDirectory;
    final file = File('${dbDir.path}$path');
    try {
      await file.delete();
    } catch (e) {
      _log.finest('Error deleting file $path: $e');
    }
    _fileCache.remove(path);
  }

  Future _deleteDirectory(String path) async {
    final dbDir = await Localstore.instance.databaseDirectory;
    final dir = Directory('${dbDir.path}$path');
    try {
      await dir.delete(recursive: true);
    } catch (e) {
      _log.finest('Error deleting directory $path: $e');
    }
    _fileCache.removeWhere((key, value) => key.startsWith(path));
  }
}
