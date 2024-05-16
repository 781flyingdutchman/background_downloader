import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

import 'utils_impl.dart';

/// Utils class
class Utils implements UtilsImpl {
  Utils._();
  static final Utils _utils = Utils._();
  static Utils get instance => _utils;

  @override
  void clearCache() {
    // no cache on web
  }

  @override
  Future<Map<String, dynamic>?> get(String path,
      [bool? isCollection = false, List<List>? conditions]) async {
    // Fetch the documents for this collection
    if (isCollection != null && isCollection == true) {
      var dataVal = web.window.localStorage.getItem(path);
      if (dataVal != null) {
        if (conditions != null && conditions.first.isNotEmpty) {
          return _getAll(MapEntry(path, dataVal));
          /*
          final ck = conditions.first[0] as String;
          final co = conditions.first[1];
          final cv = conditions.first[2];
          // With conditions
          try {
            final mapCol = json.decode(dataCol.value) as Map<String, dynamic>;
            final its = SplayTreeMap.of(mapCol);
            its.removeWhere((key, value) {
              if (value is Map<String, dynamic>) {
                final key = value.keys.contains(ck);
                final check = value[ck] as bool;
                return !(key == true && check == cv);
              }
              return false;
            });
            its.forEach((key, value) {
              final data = value as Map<String, dynamic>;
              _data[key] = data;
            });
            return _data;
          } catch (error) {
            throw error;
          }
          */
        } else {
          return _getAll(MapEntry(path, dataVal));
        }
      }
    } else {
      final data = await _readFromStorage(path);
      final id = path.substring(path.lastIndexOf('/') + 1, path.length);
      if (data is Map<String, dynamic>) {
        if (data.containsKey(id)) return data[id];
        return null;
      }
    }
    return null;
  }

  @override
  Future<dynamic>? set(Map<String, dynamic> data, String path) {
    return _writeToStorage(data, path);
  }

  @override
  Future delete(String path) async {
    _deleteFromStorage(path);
  }

  @override
  Stream<Map<String, dynamic>> stream(String path, [List<List>? conditions]) {
    // ignore: close_sinks
    final storage = _storageCache[path] ??
        _storageCache.putIfAbsent(
            path, () => StreamController<Map<String, dynamic>>.broadcast());

    _initStream(storage, path);
    return storage.stream;
  }

  Map<String, dynamic>? _getAll(MapEntry<String, String> dataCol) {
    final items = <String, dynamic>{};
    try {
      final mapCol = json.decode(dataCol.value) as Map<String, dynamic>;
      mapCol.forEach((key, value) {
        final data = value as Map<String, dynamic>;
        items[key] = data;
      });
      if (items.isEmpty) return null;
      return items;
    } catch (error) {
      rethrow;
    }
  }

  void _initStream(
      StreamController<Map<String, dynamic>> storage, String path) {
    var dataVal = web.window.localStorage.getItem(path);
    try {
      if (dataVal != null) {
        final mapCol = json.decode(dataVal) as Map<String, dynamic>;
        mapCol.forEach((key, value) {
          final data = value as Map<String, dynamic>;
          storage.add(data);
        });
      }
    } catch (error) {
      rethrow;
    }
  }

  final _storageCache = <String, StreamController<Map<String, dynamic>>>{};

  Future<dynamic> _readFromStorage(String path) async {
    final key = path.replaceAll(RegExp(r'[^\/]+\/?$'), '');
    final data = web.window.localStorage.getItem(key);
    if (data != null) {
      try {
        return json.decode(data) as Map<String, dynamic>;
      } catch (e) {
        return e;
      }
    }
  }

  Future<dynamic> _writeToStorage(
    Map<String, dynamic> data,
    String path,
  ) async {
    final key = path.replaceAll(RegExp(r'[^\/]+\/?$'), '');

    final uri = Uri.parse(path);
    final id = uri.pathSegments.last;
    var dataVal = web.window.localStorage.getItem(key);
    try {
      if (dataVal != null) {
        final mapCol = json.decode(dataVal) as Map<String, dynamic>;
        mapCol[id] = data;
        web.window.localStorage.setItem(
          key,
          json.encode(mapCol),
        );
      } else {
        web.window.localStorage.setItem(
          key,
          json.encode({id: data}),
        );
      }
      // ignore: close_sinks
      final storage = _storageCache[key] ??
          _storageCache.putIfAbsent(
              key, () => StreamController<Map<String, dynamic>>.broadcast());

      storage.sink.add(data);
    } catch (error) {
      rethrow;
    }
  }

  Future<dynamic> _deleteFromStorage(String path) async {
    if (path.endsWith('/')) {
      // If path is a directory path
      final dataCol = web.window.localStorage.getItem(path);

      try {
        if (dataCol != null) {
          web.window.localStorage.delete(path.toJS);
        }
      } catch (error) {
        rethrow;
      }
    } else {
      // If path is a file path
      final uri = Uri.parse(path);
      final key = path.replaceAll(RegExp(r'[^\/]+\/?$'), '');
      final id = uri.pathSegments.last;
      var dataVal = web.window.localStorage.getItem(key);

      try {
        if (dataVal != null) {
          final mapCol = json.decode(dataVal) as Map<String, dynamic>;
          mapCol.remove(id);
          web.window.localStorage.setItem(
            key,
            json.encode(mapCol),
          );
        }
      } catch (error) {
        rethrow;
      }
    }
  }
}
