# Working with URIs

The `background_downloader` plugin provides a powerful way to manage file downloads and uploads using URIs (Uniform Resource Identifiers) as an alternative to traditional file paths. This approach offers several advantages, especially when dealing with platform-specific differences in file access and permissions. This document explains when and why to use the URI-based methods and how they differ from the traditional file path approach.

## Why Use URIs?

The traditional approach of using `baseDirectory/directory/filename` to specify file locations works well in many cases. However, it can become complex when dealing with:

*   **File and Directory Pickers:** Obtaining user-selected files or directories through pickers often involves platform-specific URIs (e.g., `content://` URIs on Android) that cannot be directly translated into file paths.
*   **Shared Storage:** Accessing shared storage locations (like the user's Downloads or Documents directory) may require different permissions and APIs across platforms.
*   **Platform Abstraction:** Writing cross-platform code that handles file operations consistently can be challenging when relying solely on file paths.

The URI-based methods in `background_downloader` address these challenges by providing a unified way to work with files and directories, regardless of their underlying representation.

## When to Use URIs

Consider using the URI approach when:

*   You are using file or directory pickers to obtain user-selected files or locations.
*   You need to access files in shared storage locations.
*   You want to write more abstract, platform-independent code for file operations.
*   You are working with files that might not have a direct file path representation (e.g., files accessed through content providers on Android).
*   You want to download directly to an (external) storage destination on Android and bypass the temporary file that is used in the traditional approach.

Note that Uri downloads cannot be paused or resumed.

## Key Concepts

### `FileDownloader().uri`

The `FileDownloader().uri` property provides access to a set of utility functions for working with URIs, including:

*   `pickDirectory()`: Opens a directory picker dialog and returns the selected directory's URI.
*   `pickFile()`: Opens a file picker dialog and returns the selected file's URI.
*   `pickFiles()`: Opens a file picker dialog and allows selection of multiple files, returning their URIs in a list.
*   `createDirectory()`: Creates a new directory within a specified parent directory URI.
*   `getFileBytes()`: Retrieves the file data (bytes) for a given URI.
*   `copyFile()`: copies a file from a source uri to a destination. Destination can be a `Uri`, a `File` or a `String` containing a file path
*   `moveFile()`: moves a file from a source uri to a destination. Destination can be a `Uri`, a `File` or a `String` containing a file path. If the move fails, it is possible that the file was copied but the source was not deleted
*   `deleteFile()`: Deletes the file at the given URI.
*   `openFile()`: Opens the file at a given URI.
*   `moveToSharedStorage()`: Moves a file to a shared storage location.
*   `activate()`: Activates a previously accessed directory or file. Only relevant if you use `persistedUriPermission` or use the photo/video picker. In those cases, before using the Uri returned from the picker (or when retrieving that Uri if you stored it in a database), you must first activate it by calling `final uri = await downloader.uri.activate(persistentUri)` and use the resulting `uri` for subsequent operations. This is platform-agnostic (and will return the `persistentUri` on platforms other than iOS, so no `Platform.isIOS` check is needed).

The `pick...` methods and `createDirectory` take an optional `persistedUriPermission` argument (defaults to `false`) that when `true` registers the picked directory with the OS, allowing access in a later session - see [persistent URI permissions](#Persistent-URI-Permissions).

### `UriDownloadTask` and `UriUploadTask`

These task types are analogous to `DownloadTask` and `UploadTask` but are designed to work with URIs instead of file paths.

*   `UriDownloadTask`: Downloads a file to a specified directory URI. On Android, this bypasses the temp file used in the traditional approach and downloads directly to the destination.
*   `UriUploadTask`: Uploads a file from a given file URI. If the `filename` is omitted, it will be based on the task's URL.

These tasks may have a `directoryUri` (for `UriDownloadTask` only) and/or `fileUri` that may only be available in the status update.

A URI can also be passed instead of a file path when using `MultiUploadTask`.

Note that the `filePath` method on a `UriTask` will throw if the `directoryUri` or `fileUri` have a scheme other than `file`.

## Core Use Cases: Code Examples

### Downloading a File to a User-Picked Directory

```dart
Future<void> downloadFileToPickedDirectory() async {
  final downloader = FileDownloader();
  final directoryUri = await downloader.uri.pickDirectory();

  if (directoryUri != null) {
    final task = UriDownloadTask(
      url: 'https://example.com/image.jpg',
      directoryUri: directoryUri,
      filename: 'downloaded_image.jpg',
    );
    final result = await downloader.download(task);
    if (result.status == TaskStatus.complete) {
      print('File downloaded to: ${result.task.fileUri}'); // note use of result.task
    }
  } else {
    print('User canceled directory selection.');
  }
}
```

### Uploading a User-Picked File

```dart
Future<void> uploadPickedFile() async {
  final downloader = FileDownloader();
  final fileUri = await downloader.uri.pickFile();

  if (fileUri != null) {
    final task = UriUploadTask(
      url: 'https://example.com/upload',
      fileUri: fileUri,
      // omitting filename will set it based on the url
    );
    final result = await downloader.upload(task);
    if (result.status == TaskStatus.complete) {
      print('Filename: ${result.task.filename}'); // note use of result.task
    }
  } else {
    print('User canceled file selection.');
  }
}
```

### Creating a New Directory

```dart
Future<void> createNewDirectory(Uri parentDirectoryUri) async {
  final downloader = FileDownloader();
  final newDirectoryUri = await downloader.uri.createDirectory(
    parentDirectoryUri,
    'New Folder',
  );
  print('New directory created at: $newDirectoryUri');
}
```

### Picking a File with Cross-Platform Support (Including Desktop)

```dart
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:file_picker/file_picker.dart' as file_picker;

Future<Uri?> pickFileCrossPlatform() async {
  final downloader = FileDownloader();

  if (Platform.isAndroid || Platform.isIOS) {
    return await downloader.uri.pickFile();
  } else {
    // Desktop: Use file_picker package
    final result = await file_picker.FilePicker.platform.pickFiles();
    if (result != null && result.files.isNotEmpty) {
      return File(result.files.first.path!).uri;
    }
  }
  return null; // User canceled or no file picked
}
```

### Picking and Uploading a Photo/Video

```dart
Future<void> pickAndUploadMediaIOS() async {
  final downloader = FileDownloader();

  // Pick a photo or video. On iOS and Android this will use the media picker, and on
  // iOS this will copy the file to cache (ONLY for startLocation .images and .videos)
  final fileUri = await downloader.uri.pickFile(startLocation: SharedStorage.images);
  if (fileUri != null) {
    final task = UriUploadTask(
        url: 'https://example.com/upload',
        fileUri: fileUri,
        filename: 'uploaded_media'
    );
    final result = await downloader.upload(task);
    if (result.status == TaskStatus.complete) {
      print('Media uploaded from: $fileUri');
    }
    
    if (Platform.isIOS) {
      // On iOS, delete the temporary file created by the media picker
      await downloader.uri.deleteFile(fileUri);
      print("Temporary file deleted");
    }
  } else {
    print('User canceled media selection.');
  }
}
```

## Persistent URI Permissions

On Android and iOS, the `pickDirectory()`, `pickFile()`, `pickFiles()`, and `createDirectory()` methods have an optional parameter `persistedUriPermission` (which defaults to `false`). Setting this to `true` allows you to obtain a URI that can be stored in a database and used even after the application restarts or the device reboots. If you have obtained a persistent URI you must activate it before use by calling `final uri = await downloader.uri.activate(persistentUri);` and use the resulting `uri` for subsequent operations.

**Note:**  You should only request persisted URI permissions if you intend to store the URI for long-term use (e.g., in a database). Do not request persistent permissions unnecessarily.

### Android

When `persistedUriPermission` is `true`, the picked directory or file URI is registered with the OS. Your app can then store this URI and use it in future sessions without needing to prompt the user to pick the file or directory again.

### iOS

Similar to Android, setting `persistedUriPermission` to `true` registers the URI with the OS, allowing it to be stored and used later. On iOS, these persistent URIs (also called URL bookmarks) have a special `urlbookmark://` scheme. URIs with this scheme can be used with the `uri` methods and the URI based upload and download tasks, but if you need to directly access the file referenced by the bookmark URI you must "activate" it using the `activate()` method. This method will return a new, usable `file://` URI for that session.


## Platform-Specific Considerations
While the URI approach abstracts away many platform differences, there are still some important distinctions to keep in mind:

### Android
* **Content URIs**: Android often uses `content://` URIs to represent files, especially those obtained through the Storage Access Framework. These cannot be converted to a file path or `file://` scheme Uri
* **Direct Download**: When downloading to a URI destination, background_downloader bypasses the temporary file and downloads directly to the final location. This behavior is different from the regular file path approach where a temporary file is used. This also means that, for `UriDownloadTask` on Android ONLY, the presence of a file at the destination URI does not mean the file has successfully downloaded (it may be partial)

### iOS
* **`urlbookmark://`** URIs: When requesting persistent permissions for a directory or file using `persistedUriPermission` set to true, iOS returns a special `urlbookmark://` URI. This URI contains security information and can safely be stored in a database for later use. You can 'manually' convert the bookmark URL to a regular `file://` url by calling `activate`, but it is safer to pass the bookmark URI directly to `uri` methods and tasks, so no platform-specific treatment is required.
* **`media://` URIs**: When using the media picker on iOS (`pickFile` with `SharedStorage.images` or `SharedStorage.videos`), the selected media file is copied to the application's cache directory, and a `media://` URI is returned. This URI can safely be used with the `uri` methods, or used as the `fileUri` in a `UriUploadTask`. Note that the developer is responsible for deleting the file using `FileDownloader().uri.deleteFile` after use. If you need to access the referenced file directly, then use `activate()` to obtain a `file://` URI.
* **Temporary File Deletion**: After using a `media://` URI (obtained from the media picker), you must delete the temporary file using `downloader.uri.deleteFile()`.

### Desktop (macOS, Windows, Linux)
* **No Built-in Pickers**: `background_downloader` does not provide built-in file/directory pickers for desktop platforms. You should use the `file_picker` package to obtain file paths and then convert them to `file://` URIs using `Uri.file(filePath, windows: Platform.isWindows)` and use those URIs like you use the iOS/Android ones.
