/// Object attached to the [Filedownloader]'s `utils` property, used to access
/// URI related utility functions

library;

import 'dart:io';

import 'package:flutter/services.dart';

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
  final BaseDownloader _downloader;

  UriUtils(BaseDownloader downloader) : _downloader = downloader;

  factory UriUtils.withDownloader(BaseDownloader downloader) =>
      switch (downloader) {
        AndroidDownloader() => AndroidUriUtils(downloader),
        IOSDownloader() => IOSUriUtils(downloader),
        _ => DesktopUriUtils(downloader)
      };

  Future<Uri?> pickDirectory(
      {SharedStorage? startLocation,
      Uri? startLocationUri,
      bool persistedUriPermission = false});

  Future<List<Uri>?> pickFiles(
      {SharedStorage? startLocation,
      Uri? startLocationUri,
      List<String>? allowedExtensions,
      bool multipleAllowed = false,
      bool persistedUriPermission = false});

  Future<Uri> createDirectory(Uri parentDirectoryUri, String newDirectoryName,
      {bool persistedUriPermission = false});
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
    final uriString = (await _methodChannel.invokeMethod('pickDirectory', [
      startLocation?.index,
      startLocationUri?.toString(),
      persistedUriPermission
    ])) as String?;
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
    final uriString = (await _methodChannel.invokeMethod('createDirectory', [
      parentDirectoryUri.toString(),
      newDirectoryName,
      persistedUriPermission
    ])) as String;
    return Uri.parse(uriString);
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
