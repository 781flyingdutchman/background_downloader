# A background file downloader and uploader for iOS, Android, MacOS, Windows and Linux

Create a [DownloadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/DownloadTask-class.html) to define where to get your file from, where to store it, and how you want to monitor the download, then call `FileDownloader().download` and wait for the result.  Background_downloader uses URLSessions on iOS and DownloadWorker on Android, so tasks will complete also when your app is in the background. The download behavior is highly consistent across all supported platforms: iOS, Android, MacOS, Windows and Linux.

Monitor progress by passing an `onProgress` listener, and monitor detailed status updates by passing an `onStatus` listener to the `download` call.  Alternatively, monitor tasks centrally using an event listener or callbacks and call `enqueue` to start the task.

Optionally, keep track of task status and progress in a persistent database, and show mobile notifications to keep the user informed and in control when your app is in the background.

To upload a file, create an [UploadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/UploadTask-class.html) and call `upload`. To make a regular server request, create a [Request](https://pub.dev/documentation/background_downloader/latest/background_downloader/Request-class.html) and call `request`, or a enqueue a [DataTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/DataTask-class.html). To download in parallel from multiple servers, create a [ParallelDownloadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/ParallelDownloadTask-class.html).

The plugin supports headers, retries, priority, requiring WiFi before starting the up/download, user-defined metadata and display name and GET, POST and other http(s) requests, and can be configured by platform. You can manage  the tasks in the queue (e.g. cancel, pause and resume), and have different handlers for updates by group of tasks. Downloaded files can be moved to shared storage to make them available outside the app.

Pickers for files, photos/videos and directories are included for iOS and Android, and the downloader supports `Uri` based file locations and operations that are consistent across all platforms, including Android's `content://` URIs (used for the Storage Access Framework) and iOSs URL Bookmarks for persistent file locators (see [working with URIs](doc/URI.md)).

No setup is required for Android (except when using notifications), Windows and Linux, and only minimal set up for iOS and MacOS.

## File locations

To ensure your file paths work robustly across platform restarts (especially on iOS and Android where absolute paths can change), the downloader predominantly uses a combination of `BaseDirectory`, `directory` (subdirectory) and `filename`.

*   **BaseDirectory**: One of `.applicationDocuments`, `.temporary`, `.applicationSupport`, or `.applicationLibrary`. These map to stable, platform-specific locations.
*   **directory**: An optional subdirectory within the base directory.
*   **filename**: The name of the file.

Absolute paths can be used but are discouraged on mobile platforms. See [File Storage](doc/storage.md) for details.



# Documentation

For more specific details, please check the **[Topic Index](doc/topic_index.md)** or specific documentation files:

*   **[Notifications](doc/notifications.md)**: Usage, configuration, grouping, tapping, and setup.
*   **[Database & Central Monitoring](doc/database.md)**: Using event listeners, callbacks, and the persistent database to track tasks.
*   **[Downloads](doc/downloads.md)**: Normal and parallel downloads (chunked).
*   **[Uploads](doc/uploads.md)**: Single and multi-part uploads.

*   **[File Storage & Locations](doc/storage.md)**: Shared and scoped storage, moving files to Photos/Downloads.
*   **[Lifecycle & Queue Management](doc/lifecycle.md)**: Pausing, resuming, canceling, grouping tasks, and task queues. including Authentication.
*   **[Permissions](doc/permissions.md)**: Handling permissions on Android and iOS.
*   **[Server Requests & Cookies](doc/requests.md)**: Making immediate requests and handling cookies.
*   **[Optional Parameters](doc/parameters.md)**: Headers, retries, priority, metadata, etc.
*   **[Configuration](doc/CONFIG.md)**: Global configuration for timeouts, proxies, etc.
*   **[Working with URIs](doc/URI.md)**: Using URIs for file locations and pickers.

# Quick Start

### Downloads example

```dart
// Use .download to start a download and wait for it to complete

// define the download task (subset of parameters shown)
final task = DownloadTask(
        url: 'https://google.com/search',
        urlQueryParameters: {'q': 'pizza'},
        filename: 'results.html',
        headers: {'myHeader': 'value'},
        directory: 'my_sub_directory',
        updates: Updates.statusAndProgress, // request status and progress updates
        requiresWiFi: true,
        retries: 5,
        allowPause: true,
        metaData: 'data for me');

// Start download, and wait for result. Show progress and status changes
// while downloading
final result = await FileDownloader().download(task,
    onProgress: (progress) => print('Progress: ${progress * 100}%'),
    onStatus: (status) => print('Status: $status')
);

// Act on the result
switch (result.status) {
  case TaskStatus.complete:
    print('Success!');

  case TaskStatus.canceled:
    print('Download was canceled');

  case TaskStatus.paused:
    print('Download was paused');

  default:
    print('Download not successful');
}
```

### Enqueue example

```dart
// Use .enqueue for true parallel downloads, i.e. you don't wait for completion of the tasks you 
// enqueue, and can enqueue hundreds of tasks simultaneously.

// First define an event listener to process `TaskUpdate` events sent to you by the downloader, 
// typically in your app's `initState()`:
FileDownloader().updates.listen((update) {
      switch (update) {
        case TaskStatusUpdate():
          // process the TaskStatusUpdate, e.g.
          switch (update.status) {
            case TaskStatus.complete:
              print('Task ${update.task.taskId} success!');
            
            case TaskStatus.canceled:
              print('Download was canceled');
            
            case TaskStatus.paused:
              print('Download was paused');
            
            default:
              print('Download not successful');
          }

        case TaskProgressUpdate():
          // process the TaskProgressUpdate, e.g.
          progressUpdateStream.add(update); // pass on to widget for indicator
      }
    });

FileDownloader().start(); // activates the database and ensures proper restart after suspend/kill

// Next, enqueue tasks to kick off background downloads, e.g.
final successfullyEnqueued = await FileDownloader().enqueue(DownloadTask(
                                url: 'https://google.com',
                                filename: 'google.html',
                                updates: Updates.statusAndProgress));

```

**Note**: if you have a large number of tasks to enqueue (e.g. hundreds), we recommend using `FileDownloader().enqueueAll(tasks)` which is much more efficient than calling `enqueue` in a loop.


## Initial setup

No setup is required for Windows or Linux.

### Android

This package needs Kotlin 1.9.20 or above to compile.
For modern Flutter projects this should be added to the `/android/settings.gradle` file.
```gradle
plugins {
    // ...
    id "org.jetbrains.kotlin.android" version "1.9.20" apply false
    // ...
}
```
For older flutter projects, the kotlin version is set in the `android/build.gradle` file as follows.
```gradle
buildScript {
    ext.kotlin_version = '1.9.20'
}
```

### iOS

On iOS, ensure that you have the Background Fetch capability enabled:
* Select the Runner target in XCode
* Select the Signing & Capabilities tab
* Click the + icon to add capabilities
* Select 'Background Modes'
* Tick the 'Background Fetch' mode

Note that iOS by default requires all URLs to be https (and not http). See [here](https://developer.apple.com/documentation/security/preventing_insecure_network_connections) for more details and how to address issues.

### MacOS

MacOS needs you to request a specific entitlement in order to access the network. To do that open macos/Runner/DebugProfile.entitlements and add the following key-value pair.

```
  <key>com.apple.security.network.client</key>
  <true/>
```
Then do the same thing in macos/Runner/Release.entitlements.

## Limitations

* iOS 14.0 or greater; Android API 21 or greater
* On Android, downloads are by default limited to 9 minutes, after which the download will end with `TaskStatus.failed`. To allow for longer downloads, set the `DownloadTask.allowPause` field to true: if the task times out, it will pause and automatically resume, eventually downloading the entire file. Alternatively, [configure](doc/CONFIG.md) the downloader to allow tasks to run in the foreground, or (on Android 14 and above) set the task's [priority](doc/PARAMETERS.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service.
* On iOS, once enqueued (i.e. `TaskStatus.enqueued`), a background download must complete within 4 hours. [Configure](doc/CONFIG.md) 'resourceTimeout' to adjust.
* Redirects will be followed
* Background downloads and uploads are aggressively controlled by the native platform. You should therefore always assume that a task that was started may not complete, and may disappear without providing any status or progress update to indicate why. For example, if a user swipes your app up from the iOS App Switcher, all scheduled background downloads are terminated without notification
