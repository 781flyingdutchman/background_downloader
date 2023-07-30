## 6.3.3

Bug fix for `taskNotificationTapCallback`: convenience methods that `await` a result, such as `download` (but not `enqueue`), now use the default taskNotificationTapCallback, even though those tasks are in the `awaitGroup`, because that behavior is more in line with expectations. If you need a separate callback for the `awaitGroup`, then set it after setting the default callback. You set the default callback by omitting the `group` parameter in the `registerCallbacks` call.

## 6.3.2

Fixed a bug on iOS related to NSNull Json decoding

## 6.3.1

Added an optional parameter to the tasksFinished method that allows you to use it the moment you receive a status update for a task, like this:
```dart
void downloadStatusCallback(TaskStatusUpdate update) {
    // process your status update, then check if all tasks are finished
    final bool allTasksFinished = update.status.isFinalState && 
        await FileDownloader().tasksFinished(ignoreTaskId: update.task.taskId) ;
    print('All tasks finished: $allTasksFinished');
  }
```
This excludes the task that is currently finishing up from the test. Without this, it's possible `tasksFinished` returns `false` as that currently finishing task may not have left the queue yet.

## 6.3.0

Added `pathInSharedStorage` method, which obtains the path to a file moved to shared storage.

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

* Fixed bug when download is interrupted due to lost network connection (on Android)
* Fixed bug with `moveToSharedStorage` on iOS: shared storage is now 'faked' on iOS, creating
  subdirectories of the regular Documents directory, as iOS apps do not have access to shared
  media and download directories
* Fixed bug with notifications disappearing on iOS

## 6.2.1

Bug fix for type cast errors and for thread safety on iOS for notifications

## 6.2.0

Added `tasksFinished` method that returns `true` if all tasks in the group have finished

Fixed bug related to `allTasks` method

## 6.1.4

Fixed permission bug on Android 10

## 6.1.3

Added `namespace` to Android build.gradle and removed irrelevant log messages

## 6.1.2

Migrating the persistent data from the documents directory to the support directory, so it is no longer visible in - for example - the iOS Files app, or the Linux home directory.

## 6.1.1

Bug fix for `request` method where the `httpRequestMethod` override was not taken into account properly.

## 6.1.0

Added `unregisterCallBacks` to remove callbacks if you no longer want updates, and `resetUpdates` to reset the `updates` stream so it can be listened to again.

Bug fix for `DownloadTask.withSuggestedFilename` for servers that do not follow case convention for the Content-Disposition header.

## 6.0.0

Breaking changes:
* The `TaskStatusCallback` and `TaskProgressCallback` now take a single argument (`TaskStatusUpdate` and `TaskProgressUpdate` respectively) instead of multiple arguments. This aligns the callback API with the `updates` listener API, and makes it easier to add data to an update in the future. For example, in this version we add an `exception` property to programmatically handle exceptions
* Similarly, the `download` and `upload` methods now return a `TaskStatusUpdate` instead of a `TaskStatus`
* For consistency, the `taskStatus` property of the `TaskRecord` (used to store task information in a persistent database) is renamed to `status`
* The `trackTasks` method no longer takes a `group` argument, and starts tracking for all tasks, regardless of group. If you need tracking only for a specific group, call the new `trackTasksInGroup` method

Other changes (non-breaking):
* You can override the `httpRequestMethod` used for requests by setting it in the `Request`, `DownloadTask` or `UploadTask`. By default, requests and downloads use GET (unless `post` is set) and uploads use PUT
* The `download`, `upload`, `downloadBatch` and `uploadBatch` methods now take an optional `onElapsedTime` callback that is called at regular intervals (defined by the optional `elapsedTimeInterval` which defaults to 5 seconds) with the time elapsed since the call was made. This can be used to trigger UI warnings (e.g. 'this is taking rather long') or to cancel the task if it does not complete within a desired time. For performance reasons the `elapsedTimeInterval` should not be set to a value less than one second, and this mechanism should not be used to indicate progress.
* If a task fails, the `TaskStatusUpdate` will contain a `TaskException` that provides information about the type of exception (e.g. a `TaskFileSystemException` indicates an issue with storing or retrieving the file) and contains a `description` and (for `TaskHttpException` only) the `httpResponseCode`. If tasks are tracked, the  The following `TaskException` subtypes may occur:
  - `TaskException` (general exception)
  - `TaskFileSystemException` (issue retrieving or storing the file)
  - `TaskUrlException` (issue with the url)
  - `TaskConnectionException` (issue with the connection to the server)
  - `TaskResumeException` (issue with pausing or resuming a task)
  - `TaskHttpException` (issue with the HTTP connection, e.g. we received an error response from the server, captured in `httpResponseCode`)

Fixed a few bugs.

## 5.6.0

Adds handler for when the user taps a notification, and an `openFile` method to open a file using the platform-specific convention.

To handle notification taps, register a callback that takes `Task` and `NotificationType` as parameters:

```
FileDownloader().registerCallbacks(
            taskNotificationTapCallback: myNotificationTapCallback);
            
void myNotificationTapCallback(Task task, NotificationType notificationType) {
    print('Tapped notification $notificationType for taskId ${task.taskId}');
  }
```

To open a file, call `FileDownloader().openFile` and supply either a `Task` or a full `filePath` (but not both) and optionally a `mimeType` to assist the Platform in choosing the right application to use to open the file.
The file opening behavior is platform dependent, and while you should check the return value of the call to `openFile`, error checking is not fully consistent.

Note that on Android, files stored in the `BaseDirectory.applicationDocuments` cannot be opened. You need to download to a different base directory (e.g. `.applicationSupport`) or move the file to shared storage before attempting to open it.

If all you want to do on notification tap is to open the file, you can simplify the process by
adding `tapOpensFile: true` to your call to `configureNotifications`, and you don't need to
register a `taskNotificationTapCallback`.

## 5.5.0

Adds `withSuggestedFilename` for `DownloadTask`. Use:
```
   final task = await DownloadTask(url: 'https://google.com')
       .withSuggestedFilename(unique: true);
```

The method `withSuggestedFilename` returns a copy of the task it is called on, with the `filename` field modified based on the filename suggested by the server, or the last path segment of the URL, or unchanged if neither is feasible. If `unique` is true, the filename will be modified such that it does not conflict with an existing filename by adding a sequence. For example "file.txt" would become "file (1).txt".

Bug fixes:
* Fix for issue #35 for pausing convenience download and a specific issue with nginx related to pause/resume
* Fix for issue #38 related to notification permissions on iOS

## 5.4.6

Fix issue #34 with `moveToSharedStorage` on iOS

## 5.4.5

An invalid url in the `Task` now results in `false` being returned from the `enqueue` call on
all platforms. Previously, the behavior was inconsistent.

## 5.4.4

Added optional properties to `UploadTask` related to multi-part uploads:
* `fileField` is the field name used to indicate the file (default to "file")
* `mimeType` overrides the mimeType derived from the filename extension
* `fields` is a `Map<String, String>` containing form field name/value pairs that will be uploaded along with the file in a multi-part upload

## 5.4.3

Added optional `mimeType` parameter for calls to `moveToSharedStorage` and
`moveFileToSharedStorage`. This sets the mimeType
directly, instead of relying on the system to determine the mime type based on the file extension.
Note that this may change the filename - for example, when moving the test file `google.html` to
`SharedStorage.images` while setting `mimeType` to 'images/jpeg', the path to the file in shared
storage becomes `/storage/emulated/0/Pictures/google.html.jpg` (note the added .jpg).

## 5.4.2

Better permissions management, implementation of moveToSharedStorage for Android versions below Q

## 5.4.1

Minor fixes

## 5.4.0

### Shared and scoped storage

The download directories specified in the `BaseDirectory` enum are all local to the app. To make downloaded files available to the user outside of the app, or to other apps, they need to be moved to shared or scoped storage, and this is platform dependent behavior. For example, to move the downloaded file associated with a `DownloadTask` to a shared 'Downloads' storage destination, execute the following _after_ the download has completed:
```
    final newFilepath = await FileDownloader().moveToSharedStorage(task, SharedStorage.downloads);
    if (newFilePath == null) {
        ... // handle error
    } else {
        ... // do something with the newFilePath
    }
```

Because the behavior is very platform-specific, not all `SharedStorage` destinations have the same result. The options are:
* `.downloads` - implemented on all platforms, but on iOS files in this directory are not accessible to other users
* `.images` - implemented on Android and iOS only. On iOS files in this directory are not accessible to other users
* `.video` - implemented on Android and iOS only. On iOS files in this directory are not accessible to other users
* `.audio` - implemented on Android and iOS only. On iOS files in this directory are not accessible to other users
* `.files` - implemented on Android only
* `.external` - implemented on Android only

On MacOS, for the `.downloads` to work you need to enable App Sandbox entitlements and set the key `com.apple.security.files.downloads.read-write` to true.
On Android, depending on what `SharedStorage` destination you move a file to, and depending on the OS version your app runs on, you _may_ require extra permissions `WRITE_EXTERNAL_STORAGE` and/or `READ_EXTERNAL_STORAGE` . See [here](https://medium.com/androiddevelopers/android-11-storage-faq-78cefea52b7c) for details on the new scoped storage rules starting with Android API version 30, which is what the plugin is using.

Methods `moveToSharedStorage` and the similar `moveFileToSharedStorage` also take an optional `directory` argument for a subdirectory in the `SharedStorage` destination.

Thanks to @rebaz94 for implementing scoped storage on Android.

### Library base directory

The `BaseDirectory` enum now also supports `.applicationLibrary`. On iOS and MacOS this is the directory provided by the `path_provider` package's `getLibraryDirectory()` call. On Other platforms, for consistency, this is the subdirectory 'Library' of the directory returned byn the `getApplicationSupportDirectory()` call.

### Bug fix

Fixed a bug with iOS cancellation in non-US locales.

## 5.3.0

### Notifications

On iOS and Android, for downloads only, the downloader can generate notifications to keep the user informed of progress also when the app is in the background, and allow pause/resume and cancellation of an ongoing download from those notifications.

Configure notifications by calling `FileDownloader().configureNotification` and supply a `TaskNotification` object for different states. For example, the following configures notifications to show only when actively running (i.e. download in progress), disappearing when the download completes or ends with an error. It will also show a progress bar and a 'cancel' button, and will substitute {filename} with the actual filename of the file being downloaded.
```
    FileDownloader().configureNotification(
        running: TaskNotification('Downloading', 'file: {filename}'),
        progressBar: true)
```

To also show a notifications for other states, add a `TaskNotification` for `complete`, `error` and/or `paused`. If `paused` is configured and the task can be paused, a 'Pause' button will show for the `running` notification, next to the 'Cancel' button.

There are three possible substitutions of the text in the `title` or `body` of a `TaskNotification`:
* {filename} is replaced with the filename as defined in the `Task`
* {progress} is substituted by a progress percentage, or '--%' if progress is unknown
* {metadata} is substituted by the `Task.metaData` field

Notifications on iOS follow Apple's [guidelines](https://developer.apple.com/design/human-interface-guidelines/components/system-experiences/notifications/), notably:
* No progress bar is shown, and the {progress} substitution always substitutes to an empty string. In other words: only a single `running` notification is shown and it is not updated until the download state changes
* When the app is in the foreground, on iOS 14 and above the notification will not be shown but will appear in the NotificationCenter. On older iOS versions the notification will be shown also in the foreground. Apple suggests showing progress and download controls within the app when it is in the foreground

While notifications are possible on desktop platforms, there is no true background mode, and progress updates and indicators can be shown within the app. Notifications are therefore ignored on desktop platforms.

The `configureNotification` call configures notification behavior for all download tasks. You can specify a separate configuration for a `group` of tasks by calling `configureNotificationForGroup` and for a single task by calling `configureNotificationForTask`. A `Task` configuration overrides a `group` configuration, which overrides the default configuration.

When attempting to show its first notification, the downloader will ask the user for permission to show notifications (platform version dependent) and abide by the user choice. For Android, starting with API 33, you need to add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` to your app's `AndroidManifest.xml`. Also on Android you can localize the button text by overriding string resources `bg_downloader_cancel`, `bg_downloader_pause`, `bg_downloader_resume` and descriptions `bg_downloader_notification_channel_name`, `bg_downloader_notification_channel_description`. Localization on iOS is not currently supported.

## 5.2.0

Better persistence for tasks that execute while the app is suspended by the operating system.  
To ensure your callbacks or listener capture events that may have happened when your app was
suspended in the background, call `FileDownloader().resumeFromBackground()` right after registering
your callbacks or listener.

## 5.1.0

Previously, Android file downloads were limited to 8 minutes. Now, long downloads are possible provided the `DownloadTask.allowPause` field is set to true. Just before the download times out, the downloader will pause and then resume the task in a new worker, effectively resetting the 9 minute clock.  As a result, the download will eventually complete

## 5.0.0

### Pause and resume

To pause or resume a task, call:
* `pause` to attempt to pause a task. Whether a task can be canceled or not depends primarily on the server. Soon after the task is running (`TaskStatus.running`) you can call `taskCanResume` which will return a Future that resolves to `true` if the server appears capable of pause & resume. If that returns `false`, then calling `pause` will return `false` as well, and the call is ignored
* `resume` to resume a previously paused task, which returns true if resume appears feasible. The taskStatus will follow the same sequence as a newly enqueued task. If resuming turns out to be not feasible (e.g. the operating system deleted the temp file with the partial download) then the task will either restart as a normal download, or fail.

This adds `TaskStatus.paused` which may require updating `switch` statements to remain exhaustive, though this status will never appear unless you use pause.

### Individual status and progress callbacks for batch upload and download

Adds status and progress callbacks for individual files in a batch. This is breaking if you used a batch progress callback earlier, as that is now a named parameter. Change:
```
   final result = await FileDownloader().downloadBatch(tasks, (succeeded, failed) {
      print('$succeeded files succeeded, $failed have failed');
      print('Progress is ${(succeeded + failed) / tasks.length} %');
   });
```
to
```
   final result = await FileDownloader().downloadBatch(tasks, batchProgressCallback: (succeeded, failed) {
    ...
   });
```

To also monitor status and progress for each file in the batch, add a `taskStatusCallback` (taking `Task` and `TaskStatus` as arguments) and/or a `taskProgressCallback (taking `Task` and a double as arguments).

### iOS minimum version from 11.0 to 13.0
To improve Swift code readability and maintenance, the minimum iOS version has moved from 11.0 to 13.0

## 4.2.3

Fixed another bug with `database.allRecords` if taskId contains illegal filename characters (like '/'). For
tracking record id purposes those are now replaced with '_'

## 4.2.2

Fixed bug with `database.allRecords` if taskId contains illegal filename characters (like '/'). For
tracking record id purposes those are now replaced with '_'

## 4.2.1

Upgraded dependency to address issue with Windows platform database performance

## 4.2.0

Added `creationTime` field to `Request` and `Task`.

Added `allRecordsOlderThan(Duration age, {String? group})` to `database`, making it easy to extract
the `TaskRecord` entries that are stale.

## 4.1.0

Adds optional tracking of task status and progress in a persistent database.

To keep track of the status and progress of all tasks, even after they have completed, activate tracking by calling `trackTasks()` and use the `database` field to query. For example:
```
    // at app startup, start tracking
    await FileDownloader().trackTasks();
    
    
    // somewhere else: enqueue a download
    final task = DownloadTask(
            url: 'https://google.com',
            filename: 'testfile.txt');
    final successfullyEnqueued = await FileDownloader().enqueue(task);
    
    // somewhere else: query the task status by getting a `TaskRecord`
    // from the database
    final record = await FileDownloader().database.recordForId(task.taskId);
    print('Taskid ${record.taskId} with task ${record.task} has '
        'status ${record.taskStatus} and progress ${record.progress}'
```

You can interact with the `database` using `allRecords`, `recordForId`, `deleteAllRecords`, `deleteRecordWithId` etc. Note that only tasks that you asked to be tracked (using `trackTasks`, which activates tracking for all tasks in a group) will be in the database. All active tasks in the queue, regardless of tracking, can be queried via the `FileDownloader.taskForId` call etc, but those will only return the task itself, not its status or progress, as those are expected to be monitored via listener or callback.  Note: tasks that are started using `download`, `upload`, `batchDownload` or `batchUpload` are assigned a special group name 'await', as callbacks for these tasks are handled within the `FileDownloader`. If you want to  track those tasks in the database, call `FileDownloader().trackTasks(FileDownloader.awaitGroup)` at the start of your app.

## 4.0.0

Adds support for MacOS, Windows and Linux and refactored the backend to be more easily extensible.

Changes FileDownloader usage from static to a singleton. This means that instead of calling
`FileDownloader.downloader(...)` now call `FileDownloader().downloader(...)` etc.

Calling `.initialize` is not longer required.

## 3.0.1

iOS BaseDirectory.applicationSupport now uses iOS applicationSupportDirectory instead of
libraryDirectory

## 3.0.0

Version 3 introduces uploads, `onProgress` and `onStatus` callbacks passed to `download` and `upload`,
and cleans up the API to be less verbose.

The class hierarchy is `Request` -> `Task` -> (`DownloadTask` | `UploadTask`), and several
methods and callbacks will return or expect a `Task` that may be a `DownloadTask` or `UploadTask`.

To align naming convention, several class and enum names have been changed:
- class BackgroundDownloadTask -> DownloadTask, and field progressUpdates -> updates
- enum DownloadTaskStatus -> TaskStatus
- enum DownloadProgressUpdates -> Updates (and enum value changes)
- class BackgroundDownloadEvent -> TaskUpdate
- class BackgroundDownloadStatusEvent -> TaskStatusUpdate
- class BackgroundDownloadProgressEvent -> TaskProgressUpdate
- typedef DownloadStatusCallback -> TaskStatusCallback
- typedef DownloadProgressCallback -> TaskProgressCallback
- class DownloadBatch -> Batch
- typedef BatchDownloadProgressCallback -> BatchProgressCallback

## 2.1.1

The url and urlQueryParameters passed to a `BackgroundDownloadTask` or `Request` must be encoded if necessary. For example, if the url or query parameters contain a space, it must be replaced with %20 per urlencoding

## 2.1.0

Changes:
- Added option to use a POST request: setting the `post` field to a String or UInt8List passes that data to the server using the POST method to obtain your file
- Added `request` method, taking a `Request` object (a superclass of `BackgroundDownloadTask`), for simple server requests, where you process the server response directly (i.e. not in a file).
- Refactored Android Kotlin code and made small improvement to the fix for [issue](https://github.com/781flyingdutchman/background_downloader/issues/6) with
  Firebase plugin `onMethodCall` handler

## 2.0.1

Fix for [issue](https://github.com/781flyingdutchman/background_downloader/issues/6) with
Firebase plugin `onMethodCall` handler

## 2.0.0

Added option to automatically retry failed downloads. This is a breaking change, though for most
existing implementations no or very little change is required.

The main change is the addition of `enqueued` and `waitingToRetry` status to the
`DownloadTaskStatus` enum (and removal of `undefined`). As a result, when checking a
`DownloadStatusUpdate` (e.g. using a `switch` statement) you need to cover these new cases (and
for existing implementations can typically just ignore them).  The progressUpdate equivalent of
`waitingToRetry` is a value of -4.0, but for existing implementations this will never be
emitted, as they won't have retries.

The second change is that a task now emits `enqueued` when enqueued, and `running` once the actual
download (on the native platform) starts. In existing applications this can generally be ignored,
but it allows for more precise status updates.

To use automatic retries, simply set the `retries` field of the `BackgroundDownloadTask` to an
integer between 0 and 10. A normal download (without the need for retries) will follow status
updates from `enqueued` -> `running` -> `complete` (or `notFound`). If `retries` has been set and
the task fails, the sequence will be `enqueued` -> `running` ->
`waitingToRetry` -> `enqueued` -> `running` -> `complete` (if the second try succeeds, or more
retries if needed).

## 1.6.1

Fix for [issue](https://github.com/781flyingdutchman/background_downloader/issues/6) with
Firebase plugin `onMethodCall` handler

## 1.6.0

Added option to set `requiresWiFi` on the `BackgroundDownloadTask`, which ensures the task won't
start downloading unless a WiFi network is available. By default `requiresWiFi` is false, and
downloads will use the cellular (or metered) network if WiFi is not available, which may incur cost.

## 1.5.0

Added `allTasks` method to get a list of running tasks. Use `allTaskIds` to get a list of taskIds
only.

## 1.4.2

Added note to README referring to an issue (
and [fix](https://github.com/firebase/flutterfire/issues/9689#issuecomment-1304491789)) where the
firebase plugin interferes with the downloader

## 1.4.1

Improved example app, updated documentation and fixed minor Android bug

## 1.4.0

Added `downloadBatch` method to enqueue and wait for completion of a batch of downloads

## 1.3.0

Added option to use an event listener instead of (or in addition to) callbacks

## 1.2.0

Added FileDownloader.download as a convenience method for simple downloads. This method's Future
completes only after the download has completed or failed, and can be used for simple downloads
where status and progress checking is not required.

## 1.1.0

Added headers and metaData fields to the BackgroundDownloadTask. Headers will be added to the
request, and metaData is ignored but may be helpful to the user

## 1.0.2

Replaced Ktor client with a basic Kotlin implementation

## 1.0.0

Initial release
