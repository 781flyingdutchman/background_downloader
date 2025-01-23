/// Object attached to the [Filedownloader]'s `utils` property, used to access
/// URI related utility functions

library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'base_downloader.dart';
import 'models.dart';
import 'package:path/path.dart' as p;
import 'native_downloader.dart';

/// Base implementation of the utilities related to File, Uri and filePath
/// manipulation.
///
/// Use the [withDownloader] factory constructor to get the appropriate subclass
/// for the platform you're on
sealed class UriUtils {
  final log = Logger('UriUtils');
  final BaseDownloader _downloader;

  UriUtils(BaseDownloader downloader) : _downloader = downloader;

  factory UriUtils.withDownloader(BaseDownloader downloader) =>
      switch (downloader) {
        AndroidDownloader() => AndroidUriUtils(downloader),
        IOSDownloader() => IOSUriUtils(downloader),
        _ => DesktopUriUtils(downloader)
      };

  /// Opens a directory picker dialog and returns the selected directory's URI.
  ///
  /// [startLocation] (optional) specifies a [SharedStorage] location to open the picker at.
  /// [startLocationUri] (optional) specifies a URI to open the picker at.
  /// Only one of [startLocation] or [startLocationUri] should be provided.
  /// [persistedUriPermission] (optional, defaults to `false`) indicates whether to take persisted URI permission
  /// for the selected directory, if the platform supports it.
  ///
  /// Returns the selected directory's URI, or `null` if the user canceled the operation.
  Future<Uri?> pickDirectory(
      {SharedStorage? startLocation,
      Uri? startLocationUri,
      bool persistedUriPermission = false});

  /// Opens a file picker dialog and returns a list of the selected files' URIs.
  ///
  /// [startLocation] (optional) specifies a [SharedStorage] location to open the picker at.
  /// [startLocationUri] (optional) specifies a URI to open the picker at.
  /// Only one of [startLocation] or [startLocationUri] should be provided.
  /// [allowedExtensions] (optional) specifies a list of file extensions to filter the picker by.
  /// [multipleAllowed] (optional, defaults to `false`) indicates whether to allow multiple file selection.
  /// [persistedUriPermission] (optional, defaults to `false`) indicates whether to take persisted URI permission
  /// for the selected files, if the platform supports it.
  ///
  /// Returns a list of the selected files' URIs, or `null` if the user canceled the operation.
  Future<List<Uri>?> pickFiles(
      {SharedStorage? startLocation,
      Uri? startLocationUri,
      List<String>? allowedExtensions,
      bool multipleAllowed = false,
      bool persistedUriPermission = false});

  /// Creates a new directory with the given name within the specified parent directory.
  ///
  /// [parentDirectoryUri] is the URI of the parent directory.
  /// [newDirectoryName] is the name of the new directory to create.
  /// [persistedUriPermission] (optional, defaults to `false`) indicates whether to take persisted URI permission
  /// for the created directory, if the platform supports it.
  ///
  /// Returns the URI of the newly created directory.
  Future<Uri> createDirectory(Uri parentDirectoryUri, String newDirectoryName,
      {bool persistedUriPermission = false});

  /// Retrieves the file data (bytes) for a given URI.
  ///
  /// [uri] is the URI of the file.
  ///
  /// Returns a [Uint8List] containing the file data, or `null` if an error occurred.
  Future<Uint8List?> getFileBytes(Uri uri);

  /// Deletes the file at the given URI.
  ///
  /// [uri] is the URI of the file to delete.
  ///
  /// Returns `true` if the file was deleted successfully, `false` otherwise.
  Future<bool> deleteFile(Uri uri);

  /// Packs [filename] and [uri] into a single String
  ///
  /// use [unpack] to retrieve the filename and uri from the packed String
  static String pack(String filename, Uri uri) =>
      ':::$filename::::::${uri.toString()}:::';

  /// Unpacks [packedString] into a (filename, uri). If this is not a packed
  /// string, returns the original [packedString] as (filename and null) or,
  /// if it is a Uri as (null and the uri)
  static ({String? filename, Uri? uri}) unpack(String packedString) {
    final regex = RegExp(r':::([\s\S]*?)::::::([\s\S]*?):::');
    final match = regex.firstMatch(packedString);

    if (match != null && match.groupCount == 2) {
      final filename = match.group(1)!;
      final uriString = match.group(2)!;
      final uri = Uri.tryParse(uriString);
      return (filename: filename, uri: uri?.hasScheme == true ? uri : null);
    } else {
      final uri = Uri.tryParse(packedString);
      if (uri?.hasScheme == true) {
        return (filename: null, uri: uri);
      }
      return (filename: packedString, uri: null);
    }
  }

  /// Returns the Uri represented by [value], or null if the String is not a
  /// valid Uri or packed Uri string.
  ///
  /// [value] should be a full Uri string, or a packed String containing
  /// a Uri (see [pack])
  static Uri? uriFromStringValue(String value) {
    final (:filename, :uri) = unpack(value);
    return uri;
  }

  /// Returns true if [value] is a valid Uri or packed Uri string.
  ///
  /// [value] should be a full Uri string, or a packed String containing
  /// a Uri (see [pack])
  static bool containsUri(String value) => uriFromStringValue(value) != null;
}

final class DesktopUriUtils extends UriUtils {
  DesktopUriUtils(super.downloader);

  @override
  Future<Uri?> pickDirectory(
          {SharedStorage? startLocation,
          Uri? startLocationUri,
          bool persistedUriPermission = false}) =>
      throw UnimplementedError(
          'pickDirectory not implemented for this platform. '
          'Use the file_picker package and convert the resulting filePath '
          'to a URI using the .toFileUri extension');

  @override
  Future<List<Uri>?> pickFiles(
          {SharedStorage? startLocation,
          Uri? startLocationUri,
          List<String>? allowedExtensions,
          bool multipleAllowed = false,
          bool persistedUriPermission = false}) =>
      throw UnimplementedError('pickFiles not implemented for this platform. '
          'Use the file_picker package and convert the resulting filePath '
          'to a URI using the .toFileUri extension');

  @override
  Future<Uri> createDirectory(Uri parentDirectoryUri, String newDirectoryName,
      {bool persistedUriPermission = false}) async {
    final parentPath =
        parentDirectoryUri.toFilePath(windows: Platform.isWindows);
    final cleanedSegments = newDirectoryName
        .split(RegExp(r'[\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    final fullPath = p.joinAll([parentPath, ...cleanedSegments]);
    final createdDirectory = await Directory(fullPath).create(recursive: true);
    return createdDirectory.uri;
  }

  @override
  Future<Uint8List?> getFileBytes(Uri uri) {
    //TODO: Implement this for desktop
    throw UnimplementedError('Not done yet');
  }

  @override
  Future<bool> deleteFile(Uri uri) {
    // TODO: implement deleteFile
    throw UnimplementedError();
  }
}

final class NativeUriUtils extends UriUtils {
  final _methodChannel =
      MethodChannel('com.bbflight.background_downloader.uriutils');

  NativeUriUtils(super.downloader);

  @override
  Future<Uri?> pickDirectory(
      {SharedStorage? startLocation,
      Uri? startLocationUri,
      bool persistedUriPermission = false}) async {
    final uriString = (await _methodChannel.invokeMethod<String>(
        'pickDirectory', [
      startLocation?.index,
      startLocationUri?.toString(),
      persistedUriPermission
    ]));
    return (uriString != null) ? Uri.parse(uriString) : null;
  }

  @override
  Future<List<Uri>?> pickFiles(
      {SharedStorage? startLocation,
      Uri? startLocationUri,
      List<String>? allowedExtensions,
      bool multipleAllowed = false,
      bool persistedUriPermission = false}) async {
    final uriStrings = (await _methodChannel.invokeMethod('pickFiles', [
      startLocation?.index,
      startLocationUri?.toString(),
      allowedExtensions,
      multipleAllowed,
      persistedUriPermission
    ]));
    print(uriStrings);
    // uriStrings can be a list of Strings or just one String, or null
    return switch (uriStrings) {
      String uri => [Uri.parse(uri)],
      List<Object?>? uris => uris
          ?.where((e) => e != null)
          .map((e) => Uri.parse(e as String))
          .toList(growable: false),
      _ => throw ArgumentError(
          'pickFiles returned invalid value $uriStrings of type ${uriStrings.runtimeType}')
    };
  }

  @override
  Future<Uri> createDirectory(Uri parentDirectoryUri, String newDirectoryName,
      {bool persistedUriPermission = false}) async {
    final uriString = (await _methodChannel.invokeMethod<String>(
        'createDirectory', [
      parentDirectoryUri.toString(),
      newDirectoryName,
      persistedUriPermission
    ]));
    return Uri.parse(uriString!);
  }

  /// Retrieves the file data (bytes) for a given URI.
  ///
  /// [uri] is the URI of the file.
  ///
  /// Returns a [Uint8List] containing the file data, or `null` if an error occurred.
  @override
  Future<Uint8List?> getFileBytes(Uri uri) async {
    try {
      final result = await _methodChannel.invokeMethod<Uint8List>(
          'getFileBytes', uri.toString());
      return result;
    } catch (e) {
      print('Error reading file: $e');
      return null;
    }
  }

  @override
  Future<bool> deleteFile(Uri uri) async {
    try {
      await _methodChannel.invokeMethod('deleteFile', uri.toString());
      return true;
    } catch (e) {
      log.fine('Error deleting file at URI $uri: $e');
      return false;
    }
  }
}

final class AndroidUriUtils extends NativeUriUtils {
  AndroidUriUtils(super.downloader);
}

final class IOSUriUtils extends NativeUriUtils {
  IOSUriUtils(super.downloader);
}

/// Extensions on String related to Uri and File
extension StringUriExtensions on String {
  /// Converts a [filePath] to a file URI
  Uri toFileUri() => Uri.file(this, windows: Platform.isWindows);
}

/// Extensions on Uri related to File and String
extension UriExtensions on Uri {
  /// Returns the File represented by this [uri]
  File toFile() => File(toFilePath(windows: Platform.isWindows));

  /// True if Uri scheme is file
  bool get isFileUri => scheme == 'file';

  /// True if Uri scheme is content
  bool get isContentUri => scheme == 'content';
}
