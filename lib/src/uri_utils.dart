/// Object attached to the [Filedownloader]'s `utils` property, used to access
/// URI related utility functions

library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'base_downloader.dart';
import 'models.dart';
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

      }

  Future<Uri?> pickDirectory({SharedStorage? startLocation,
    bool persistedUriPermission = false}) =>
      throw UnimplementedError(
          'pickDirectory not implemented for this platform. '
              'Use the file_picker package and convert the resulting filePath '
              'to a URI using the .toFileUri extension');
}

class NativeUriUtils extends UriUtils {
  final _methodChannel = MethodChannel(
      'com.bbflight.background_downloader/file_picker');

  NativeUriUtils(super.downloader);
}


class AndroidUriUtils extends NativeUriUtils {
  AndroidUriUtils(super.downloader);

  Future<Uri?> pickDirectory({SharedStorage? startLocation,
    bool persistedUriPermission = false}) async {
    final uriString = (await _methodChannel.invokeMethod('pickDirectory', {
      'startLocation': startLocation?.toString(),
      'persistedUriPermission': persistedUriPermission,
    })) as String?;
    return (uriString != null) ? Uri.parse(uriString) : null;
  }

  Future<List<Uri>?> pickFiles(SharedStorage? startLocation,
      List<String>? allowedExtensions,
      bool multipleAllowed,
      bool persistedUriPermission) async {
    final uriStrings = (await _methodChannel.invokeMethod('pickFiles', {
      'startLocation': startLocation?.toString(),
      'allowedExtensions': allowedExtensions,
      'multipleAllowed': multipleAllowed,
      'persistedUriPermission': persistedUriPermission,
    })) as List<String>?;
    return (uriStrings != null && uriStrings.isNotEmpty) ? uriStrings.map((e) =>
        Uri.parse(e)).toList(growable: false) : null;
  }

  Future<String> createDirectory(String parentDirectoryUri,
      String newDirectoryName,
      bool persistedUriPermission) async {
    return (await _methodChannel.invokeMethod('createDirectory', {
      'parentDirectoryUri': parentDirectoryUri,
      'newDirectoryName': newDirectoryName,
      'persistedUriPermission': persistedUriPermission,
    })) as String;
  }
}


/// Extensions on String related to Uri and File
extension StringUriExtensions on String {
  /// Converts a [filePath] to a file URI
  Uri toFileUri() => Uri.file(this, windows: Platform.isWindows);
}

/// Extensions on Uri related to File and String
extension UriExtensions on Uri {
  /// Returns the filePath represented by this [uri]
  String toFilePath() =>
      isFileUri
          ? path
          : throw ArgumentError.value(this, 'uri', 'Not a file URI');

  /// Returns the File represented by this [uri]
  File toFile() => File(toFilePath());

  /// True if Uri scheme is file
  bool get isFileUri => scheme == 'file';

  /// True if Uri scheme is content
  bool get isContentUri => scheme == 'content';
}
