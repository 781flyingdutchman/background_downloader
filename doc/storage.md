# File Storage & Locations

## Specifying the location of the file

To ensure robust file handling across all platforms (iOS, Android, Linux, MacOS, Windows) and to avoid issues with absolute paths changing between app restarts (common on mobile), the downloader splits the file location into three parts:

1.  **BaseDirectory**: The root folder for the file.
2.  **directory**: An optional subdirectory within the BaseDirectory.
3.  **filename**: The name of the file.

### Why split the path?

On iOS and Android, the absolute path to your application's sandbox can change every time the app starts. If you store an absolute path (e.g., `/var/mobile/Containers/Data/Application/1234/Documents/my_file.txt`) and try to use it after a restart, it might point to a non-existent location if the app ID (the `1234` part) has changed. 

By using `BaseDirectory` (e.g., `.applicationDocuments`), the downloader always looks up the *current* correct path at runtime, ensuring your file references remain valid.

### The `BaseDirectory` enum

*   `BaseDirectory.applicationDocuments`: Private directory for the app. Good for user-generated data.
*   `BaseDirectory.temporary`: Cache directory. The OS may clear this to free up space.
*   `BaseDirectory.applicationSupport`: Private directory for app support files.
*   `BaseDirectory.applicationLibrary`: (iOS/MacOS only) The Library directory.

### Using Absolute Paths

If you must use absolute paths, you can set `baseDirectory` to `BaseDirectory.root`. However, you are responsible for ensuring the path is valid. To help with this, you can use `Task.split(absolutePath)` which attempts to split an absolute path into the best matching `BaseDirectory`, `directory`, and `filename`.

```dart
// Recommended: let the downloader handle the path
final task = DownloadTask(
    url: 'https://google.com',
    baseDirectory: BaseDirectory.applicationDocuments,
    directory: 'my_downloads',
    filename: 'data.txt');

// Not recommended (mobile): using absolute path
final task = DownloadTask(
    url: 'https://google.com',
    baseDirectory: BaseDirectory.root,
    directory: '/absolute/path/to', 
    filename: 'data.txt');
```

# Shared and scoped storage

The download directories specified in the `BaseDirectory` enum are all local to the app. To make downloaded files available to the user outside of the app, or to other apps, they need to be moved to shared or scoped storage, and this is platform dependent behavior. For example, to move the downloaded file associated with a `DownloadTask` to a shared 'Downloads' storage destination, execute the following _after_ the download has completed:
```dart
final newFilepath = await FileDownloader().moveToSharedStorage(task, SharedStorage.downloads);
if (newFilePath == null) {
  // handle error
} else {
  // do something with the newFilePath
}
```

Because the behavior is very platform-specific, not all `SharedStorage` destinations have the same result. The options are:
* `.downloads` - implemented on all platforms, but 'faked' on iOS: files in this directory are not accessible to other users
* `.images` - implemented on Android and iOS only. On iOS, this moves the image to the Photos Library and returns an identifier instead of a filePath - see below
* `.video` - implemented on Android and iOS only. On iOS, this moves the video to the Photos Library and returns an identifier instead of a filePath - see below
* `.audio` - implemented on Android and iOS only, and 'faked' on iOS: files in this directory are not accessible to other users
* `.files` - implemented on Android only
* `.external` - implemented on Android only

The 'fake' on iOS is that we create an appropriately named subdirectory in the application's Documents directory where the file is moved to. iOS apps do not have access to the system wide directories.

Methods `moveToSharedStorage` and the similar `moveFileToSharedStorage` also take an optional
`directory` argument for a subdirectory in the `SharedStorage` destination. They also take an
optional `mimeType` parameter that overrides the mimeType derived from the filePath extension.

If the file already exists in shared storage, then on iOS and desktop it will be overwritten,
whereas on Android API 29+ a new file will be created with an indexed name (e.g. 'myFile (1).txt').

__On MacOS:__ For the `.downloads` to work you need to enable App Sandbox entitlements and set the key `com.apple.security.files.downloads.read-write` to true.  

__On Android:__ Depending on what `SharedStorage` destination you move a file to, and depending on the OS version your app runs on, you _may_ require extra permissions `WRITE_EXTERNAL_STORAGE` and/or `READ_EXTERNAL_STORAGE` . See [here](https://medium.com/androiddevelopers/android-11-storage-faq-78cefea52b7c) for details on the new scoped storage rules starting with Android API version 30, which is what the plugin is using.

__On iOS:__ For `.images` and `.video` SharedStorage destinations, you need user [permission](permissions.md) to add to the Photos Library, which requires you to set the `NSPhotoLibraryAddUsageDescription` key in `Info.plist`. The returned String is _not_ a `filePath`, but a unique identifier. If you only want to add the file to the Photos Library you can ignore this identifier. If you want to actually get access to the file (and `filePath`) in the Photos Library, then the user needs to grant an additional 'modify' permission, which requires you to set the `NSPhotoLibraryUsageDescription` in `Info.plist`. To get the actual `filePath`, call `pathInSharedStorage` and pass the identifier obtained via the call to `moveToSharedStorage` as the `filePath` parameter:
```dart
final identifier = await FileDownloader().moveToSharedStorage(task, SharedStorage.images);
if (identifier != null) {
  final path = await FileDownloader().pathInSharedStorage(identifier, SharedStorage.images);
  debugPrint('iOS path to dog picture in Photos Library = ${path ?? "permission denied"}');
} else {
  debugPrint('Could not add file to Photos Library, likely because permission denied');
}
```
The reason for this two-step approach is that typically you only want to add to the library (requires `PermissionType.iosAddToPhotoLibrary`), which does not require the user to give read/write access to their entire photos library (`PermissionType.iosChangePhotoLibrary`, required to get the `filePath`).

## Path to file in shared storage

To check if a file exists in shared storage, obtain the path to the file by calling
`pathInSharedStorage` and, if not null, check if that file exists.

__On Android 29+:__ If you
have generated a version with an indexed name (e.g. 'myFile (1).txt'), then only the most recently stored version is available this way, even if an earlier version actually does exist. Also, only files stored by your app will be returned via this call, as you don't have access to files stored by other apps.

__On iOS:__ To make files visible in the Files browser, do not move them to shared storage. Instead, download the file to the `BaseDirectory.applicationDocuments` and add the following to your `Info.plist`:
```
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
<key>UIFileSharingEnabled</key>
<true/>
```
This will make all files in your app's `Documents` directory visible to the Files browser.

See `moveToSharedStorage` above for the special handling of `.video` and `.images` destinations on iOS.
