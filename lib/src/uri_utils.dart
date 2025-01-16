/// Object attached to the [Filedownloader]'s `utils` property, used to access
/// URI related utility functions

library;

import 'dart:io';

import '../background_downloader.dart';

sealed class URIUtils {

  Future<Uri> pickDirectory({SharedStorage startLocation})

  // General utility functions for conversion of URIs

  /// Converts a [filePath] to a file URI
  Uri fileUri(String filePath) =>
      Uri.file(filePath, windows: Platform.isWindows);

  /// Returns the filePath represented by this [uri]
  String filePath(Uri uri) => isFileUri(uri)
      ? uri.path
      : throw ArgumentError.value(uri, 'uri', 'Not a file URI');

  /// Returns the File represented by this [uri]
  File file(Uri uri) => File(filePath(uri));

  /// True if Uri scheme is file
  bool isFileUri(Uri uri) => uri.scheme == 'file';

  /// True if Uri scheme is content
  bool isContentUri(Uri uri) => uri.scheme == 'content';
}
