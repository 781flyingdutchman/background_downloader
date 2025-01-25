## 8.9.4
* Modifies the interval between `TaskProgressUpdate` such that an update is sent at least once every 2.5 seconds if progress has been made, even if it less than 2% of the file size
* Improves `rescheduleKilledTasks` to also reschedule tasks marked as `waitingToRetry` but not registered as such

## 8.9.3
* Adds `start` which ensures the various start-up calls are executed in the correct order. Use this instead of calling `trackTasks`, `resumeFromBackground` and `rescheduleKilledTasks` separately
* Adds `rescheduleKilledTasks` which will compare enqueued/running tasks in the database with those active in the downloader, and reschedules those that have been killed by the user
* [iOS] Removes limit on range of partial file uploads using the Range header (was 2GB)

## 8.9.2
* Upgraded minimum Dart SDK to 3.5.0 / Flutter SDK 3.24.0 to stay in sync with dependency updates
* [Android] Fix bug when uploading files greater than 2GB, that was introduced in V8.9.0

## 8.9.1
* [iOS] Adds Privacy Manifest
* [iOS] Adds support for Swift Package Manager and defaults the example app to using it

## 8.9.0
* Adds `options` field to Task, which take a `TaskOptions` object to configure less common task specific options - currently `onTaskStart`, `onTaskFinished` and `auth`
  - `onTaskStart` is a callback with signature`Future<Task?> Function(Task original)`, called just before the task starts executing. Your callback receives the `original` task about to start, and can modify this task if necessary. If you make modifications, you return the modified task - otherwise return null to continue execution with the original task. You can only change the task's `url` (including query parameters) and `headers` properties - making changes to any other property may lead to undefined behavior.
  - `onTaskFinished` is a callback with signature `Future<void> Function(TaskStatusUpdate taskStatusUpdate)`, called when the task has reached a final state (regardless of outcome). Your callback receives the final `TaskStatusUpdate` and can act on that.
  - `auth` is an optional `Auth` object that helps manage accessToken and accessToken refresh - see the README for details
  - __NOTE:__ The callback functionality is experimental for now, and its behavior may change without warning in future updates. Please provide feedback on callbacks
* Upgrades Android Java version to version 17 (modifies build.gradle)
* Fixes concurrency issue on iOS
* Changes how `numTotal` is calculated for group notifications: `numTotal` is now increment when a task is enqueued, instead of when it starts running. Note that this can lead to a '0/20 files' type notification if the tasks are enqueued but cannot start due to a constraint such as requiring WiFi
* Expands type of Android URI that can be used to upload a file (was MediaStore URIs only, now accepts any Android URI, e.g. one provided by a document provider such as a file picker)

## 8.8.1

* Fixes Android bug where timeout timer is not cleaned up after use

## 8.8.0

* [iOS] Adds configuration option to exclude downloaded files from iCloud backup
* Adds `allGroups` parameter to `allTasks` and `allTaskIds` methods, to retrieve all tasks regardless of `group`
* [Android] Fixes issue with un-commanded restart of a download in specific scenarios

## 8.7.1

* Fix for compilation issue on Kotlin 2

## 8.7.0

* Adds option to specify a file location for upload using a Mediastore URI on Android, using `UploadTask.fromUri`. A Mediastore URI can also be requested from methods `moveToSharedStorage` and `pathInSharedStorage` by adding `asAndroidUri = true` to the call.
* Fixes bug with ParallelDownload when an error occurs
* Updates dependency on package mime to 2.0, therefore also Dart 3.2 (Flutter 3.16.0) or greater. Use `dependency_overrides` in pubspec.yaml to resolve (background_downloader works with 1.0 and 2.0)

## 8.6.0

* Adds option for partial uploads, for binary uploads only. Set the byte range by adding a "Range" header to your binary `UploadTask`, e.g. a value of "bytes=100-149" will upload 50 bytes starting at byte 100. You can omit the range end (but not the "-") to upload from the indicated start byte to the end of the file.  The "Range" header will not be passed on to the server. Note that on iOS an invalid range will cause enqueue to fail, whereas on Android and Desktop the task will fail when attempting to start.
* Fixes issue in iOS when multiple Flutter engines register the plugin
* Fixes issue with lingering HTTP connections on desktop
* Adds CI workflow (formatting, lints, build Android, build iOS)

## 8.5.6

* Fixes desktop upload cancellation bug
* Adds Url-encoding of Content-Disposition header for binary uploads. Note for multipart uploads, filename is 'browserEncoded' which does not encode Non-ASCII characters
* Fixes bug with creation of unique filename on iOS 

## 8.5.5

* Fixes concurrent database write bug for TaskRecords

## 8.5.4

* If the value of a `fields` entry of an `UploadTask` is in JSON format (defined as start/end with {} or []) then the field's mime-type will be set to `application/json`, whereas it would not have been set prior
* Fixes an issue on iOS where use of the holding queue can lead to deadlock
* For Windows, when using `BaseDirectory.root`, fixes an issue with `Task.split` and `Task.baseDirectoryPath`. When using `BaseDirectory.root` on Windows, your task's `directory` must contain the drive letter.

## 8.5.3

* Bug fixes
* Improvements to documentation

## 8.5.2

* Removes references to `dart:html` to allow web compilation using WASM. Note the package still does not work on the web
* Adds auto-decode of `post` field if Map or List. Throws if `jsonEncode` cannot convert the object, in which case you have to encode it yourself using a custom encoder

## 8.5.1

* Fixes an issue where temporary files were not deleted when canceling a paused parallel download task

## 8.5.0

* Adds `DataTask` for scheduled server requests
* Fixes bug omitting Content-Type header for iOS uploads, and Content-Disposition header for desktop uploads

### DataTask

The downloader already supported server requests for immediate execution using `FileDownloader.request(Request request)`. This change adds the option to scheduled a server request similar to scheduling any other `Task`.

To schedule a server request using the background mechanism (e.g. if you want to wait for WiFi to be available), create and enqueue a `DataTask`.
A `DataTask` is similar to a `DownloadTask` except it:
* Does not accept file information, as there is no file involved
* Does not allow progress updates
* Accepts `post` data as a String, or
* Accepts `json` data, which will be converted to a String and posted as content type `application/json`
* Accepts `contentType` which will set the `Content-Type` header value
* Returns the server `responseBody`, `responseHeaders` and possible `taskException` in the final `TaskStatusUpdate` fields

Typically you would use `enqueue` to enqueue a `DataTask` and monitor the result using a listener or callback, but you can also use `transmit` to enqueue and wait for the final result of the `DataTask`.


## 8.4.3

* Fixes iOS/Android issue where `retrieveLocallyStoredData` retrieves only a basic `TaskStatusUpdate`, without responseCode, responseBody etc

## 8.4.2

* Fixes iOS/Android bug with ParallelDownloadTask hanging when number of chunks exceeds ~10

## 8.4.1

* Fixes Android bug when using `Config.runInForeground` that can lead to a crash

## 8.4.0

* Adds optional holding queue to manage how many tasks are executed concurrently
* Fixes bug with using `unique` parameter in context of server suggested filename
* Transition from imperative to declarative Gradle plugin application, see [here](https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply)

### Holding queue

Once you `enqueue` a task with the `FileDownloader` it is added to an internal queue that is managed by the native platform you're running on (e.g. Android). Once enqueued, you have limited control over the execution order, the number of tasks running in parallel, etc, because all that is managed by the platform.  If you want more control over the queue, you need to use a `TaskQueue` or a `HoldingQueue`:
* A `TaskQueue` is a Dart object that you can add to the `FileDownloader`. You can create this object yourself (implementing the `TaskQueue` interface) or use the bundled `MemoryTaskQueue` implementation. This queue sits "in front of" the `FileDownloader` and instead of using the `enqueue` and `download` methods directly, you now simply `add` your tasks to the `TaskQueue`. Because this is a Dart object, the queue will suspend when the OS suspends your application, and if the app gets killed, tasks held in the `TaskQueue` will be lost (unless you have implemented persistence)
* A `HoldingQueue` is native to the OS and can be configured using `FileDownloader().configure` to limit the number of concurrent tasks that are executed (in total, by host or by group). When using this queue you do not change how you interact with the FileDownloader, but you cannot implement your own holding queue. Because this queue is native, it will continue to run when your app is suspended by the OS, but if the app is killed then tasks held in the holding queue will be lost (unlike tasks already enqueued natively, which persist)

This update adds the holding queue.

Use a holding queue to limit the number of tasks running concurrently. Calling `await FileDownloader().configure(globalConfig: (Config.holdingQueue, (3, 2, 1)))` activates the holding queue and sets the constraints `maxConcurrent` to 3, `maxConcurrentByHost` to 2, and `maxConcurrentByGroup` to 1. Pass `null` for no constraint for that parameter.

Using the holding queue adds a queue on the native side where tasks may have to wait before being enqueued with the Android WorkManager or iOS URLSessions. Because the holding queue lives on the native side (not Dart) tasks will continue to get pulled from the holding queue even when the app is suspended by the OS. This is different from the `TaskQueue`, which lives on the Dart side and suspends when the app is suspended by the OS

When using a holding queue:
* Tasks will be taken out of the queue based on their priority and time of creation, provided they pass the constraints imposed by the `maxConcurrent` values
* Status messages will differ slightly. You will get the `TaskStatus.enqueued` update immediately upon enqueuing. Once the task gets enqueued with the Android WorkManager or iOS URLSessions you will not get another "enqueue" update, but if that enqueue fails the task will fail. Once the task starts running you will get `TaskStatus.running` as usual
* The holding queue and the native queues managed by the Android WorkManager or iOS URLSessions are treated as a single queue for queries like `taskForId` and `cancelTasksWithIds`. There is no way to determine whether a task is in the holding queue or already enqueued with the Android WorkManager or iOS URLSessions


## 8.3.0

* Adds `responseStatusCode` to `TaskStatusUpdate` for tasks that result in `TaskStatus.complete` or `TaskStatus.notFound` (null otherwise).
* Adds `Task.split` to extract the baseDirectory, directory and filename from an absolute filePath or a File. This is saver than using `.fromFile` and preferred
* Adds `UploadTask.fromFile` to create an `UploadTask` from an existing `File` object. Note that this will create a task with an absolute path reference and `BaseDirectory.root`, which can cause problems on mobile platforms, so use with care
* Fixes bug on Android API 34 when using configuration `Config.runInForeground`

### Extracting baseDirectory, directory and filename from a filePath or File

If you already have a path to a file or a `File` object, you can extract the values for `baseDirectory`, `directory` and `filename` using `Task.split` to create the task:
```dart
final (baseDirectory, directory, filename) = await Task.split(filePath: yourPath);
final task = UploadTask(
        url: 'https://yourserver.com',
        baseDirectory: baseDirectory,
        directory: directory,
        filename: filename);
```

### Using foreground service on Android targeting API 34
If targeting API 34 or greater, you must add to your `AndroidManifest.xml` a permission declaration `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />` and the foreground service type definition (under the `application` element):
  ```
  <service
    android:name="androidx.work.impl.foreground.SystemForegroundService"
    android:foregroundServiceType="dataSync"
    tools:node="merge" />
  ```

## 8.2.1

* Adds option to specify multiple values for a single field name in the `UploadTask.fields` property by formatting the value as `'"value1", "value2", "value3"'` (note the double quotes and the comma to separate the values).

## 8.2.0

* Adds `Future<bool> requireWiFi(RequireWiFi requirement, {final rescheduleRunningTasks = true})` to set a globally enforced WiFi requirement, and pause/resume or cancel/restart tasks accordingly. This is helpful when implementing a global toggle switch to prevent data download over metered (cellular) networks. iOS and Android only

## 8.1.0

* Adds `responseHeaders` to `TaskStatusUpdate` for tasks that complete successfully (null otherwise). Per Dart convention, header names are lower-cased
* Added `ext.kotlin_version` back to build.gradle

## 8.0.5

Android minSdk now 21 (was 24) and compileSdk now 34 (was 33)

## 8.0.4

### Kotlin compiler V1.9

Kotlin compiler version moved from 1.8 to 1.9, typically this means changing your project's `build.gradle` entry:
```agsl
buildscript {
    ext.kotlin_version = '1.9.0' # changed from '1.8.0'
    repositories {
        google()
        mavenCentral()
    }
```

### Enable multiple application instances on Android

* Changes approach to backgroundChannel and activity fields in Kotlin plugin
* Allows use of `android:launchMode="standard"` in Android manifest

### Improvements and bug fixes

* Notification handling on Android when app is suspended
* Kotlin code refactoring for posting on backgroundChannel
* Web compilation

## 8.0.3

### Bypassing permissions on iOS

By default, the downloader allows any of the permissions to be requested, but that also means that Apple requires you to add things like Photo Library Usage Description to your Info.plist, even if you never move files to the Photo Library.

On iOS, to bypass the permission code altogether at compile time (and therefore remove the need to provide the Info.plist entry) modify your app's Podfile as follows:
```agsl
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    
    # The following loop has been added to bypass compilation of specific
    # permissions.
    # If you want to bypass one or more permissions (so that you don't
    # have to include things like a Photo Library Usage Description
    # if you don't add files to the Photo Library) then add this loop
    # and uncomment the permissions you want to bypass.
    # If you bypass (by including the line below) then the
    # check will not happen, and the permission is aways denied. If you
    # bypass you do not need to include the associated entry in your
    # Info.plist file
    target.build_configurations.each do |config|
      config.build_settings['OTHER_SWIFT_FLAGS'] ||= ['$(inherited)']
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_NOTIFICATIONS'
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY'
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY'
      end
  end
end
```
and uncomment the line items that you want to bypass by deleting the `#` mark at the start of the line.

## 8.0.2

Allow compilation on XCode 14 by adding compiler version gate for Swift >=5.9

## 8.0.1

Fix issue #208 concurrentModificationException on Android and similar in iOS

## 8.0.0

### Summary of changes:
* Permissions must now be explicitly checked and requested to improve user experience and give control to developer
* Add images and video to iOS Photo Library when using `SharedStorage.images` or `SharedStorage.video`
* `SqlitePersistentStorage` backing database moved to separate package `background_downloader_sql` to reduce app size for default
* Add notification for groups of downloads
* Add `BaseDirectory.root` to allow absolute file path (use with care!)
* Add fields `mimeType` and `charSet` to `TaskStatusUpdate`
* Add `Request.cookieHeader` to parse 'Set-Cookie' response header
* Add `platformVersion` method
* Add `ready` getter to wait for initialization if needed
* Bug fixes and other improvements

### BREAKING: Permissions

Permissions are no longer automatically requested. You need to explicitly check, and if necessary ask for permissions ahead of calling methods that use them.

User permissions may be needed to display notifications, to move files to shared storage (on Android) and to add images or video to the iOS Photo Library. These permissions should be checked and if needed requested before executing those operations.

You can use a package like [permission_handler](https://pub.dev/packages/permission_handler), or use the `FileDownloader().permissions` object, which has three methods:
* `status`: returns a `PermissionsStatus`. On Android this is either `granted` or `denied`. If you have not asked for permission yet, then Android returns `denied` and iOS returns `.undetermined`. iOS can also return `.partial`
* `request`: to request the actual permission. Only do this if you have confirmed that the permission is not already `granted`
* `shouldShowRationale`: for Android only, if `true` you should show a UI element (e.g. a dialog) to explain to the user why this permission is necessary

All three methods take one `PermissionType` parameter:
* `notifications`, to display notifications
* `androidSharedStorage`, to move files to external storage on Android, before API 29
* `iosAddToPhotoLibrary`, to move files to `SharedStorage.images` or `SharedStorage.video` on iOS, as this adds those files to the Photo Library
* `iosChangePhotoLibrary`, to access the path to files moved to the Photos Library

For example, to request permissions for notifications:
```dart
final permissionType = PermissionType.notifications;
var status = await FileDownloader().permissions.status(permissionType);
if (status != PermissionStatus.granted) {
if (await FileDownloader().permissions.shouldShowRationale(permissionType)) {
await showRationaleDialog(permissionType); // Show a dialog with rationale
}
status = await FileDownloader().permissions.request(permissionType);
debugPrint('Permission for $permissionType was $status');
}
```

The downloader will check permission status before each action, e.g. will not show notifications unless permissions for notifications have been granted.

Note that permissions are very platform and version dependent, e.g. notification permissions on Android are only required as of API 33, and iOS 14 introduced new Photo Library permissions. If you want to get into details, you can determine the platform version you're running by calling `await FileDownloader().platformVersion()`.

### BREAKING: Use iOS Photos Library for .video and .images SharedStorage destinations

Previously, .images and .video destinations were 'faked' on iOS. With this change, when calling `moveToSharedStorage`, the file is added to the Photos Library (provided the user grants that permission).

For `.images` and `.video` SharedStorage destinations, you need user permission to add to the Photos Library, which requires you to set the `NSPhotoLibraryAddUsageDescription` key in `Info.plist`. The returned String is _not_ a `filePath`, but a unique identifier. If you only want to add the file to the Photos Library you can ignore this identifier. If you want to actually get access to the file (and `filePath`) in the Photos Library, then the user needs to grant an additional 'modify' permission, which requires you to set the `NSPhotoLibraryUsageDescription` in `Info.plist`. To get the actual `filePath`, call `pathInSharedStorage` and pass the identifier obtained via the call to `moveToSharedStorage` as the `filePath` parameter:
```dart
// assume we have permission
final identifier = await FileDownloader().moveToSharedStorage(task, SharedStorage.images);
if (identifier != null) {
  final path = await FileDownloader().pathInSharedStorage(identifier, SharedStorage.images);
  debugPrint('iOS path to dog picture in Photos Library = ${path ?? "permission denied"}');
} else {
  debugPrint('Could not add file to Photos Library, likely because permission denied');
}
```
The reason for this two-step approach is that typically you only want to add to the library (requires `PermissionType.iosAddToPhotoLibrary`), which does not require the user to give read/write access to their entire photos library (`PermissionType.iosChangePhotoLibrary`, required to get the `filePath`).

### BREAKING: PersistentStorage and PersistentStorageMigrator

If you use the default `PersistentStorage` then nothing changes. Otherwise:
* `SqlitePersistentStorage` moved to a separate package, and the migrator used is `SqlPersistentStorageMigrator`
* `PersistentStorage` is now an interface, not a class, and `LocalStorePersistentStorage` is the default implementation
* `PersistentStorageMigrator` is now an interface, and `BasePersistentStorageMigrator` is a basic implementation that can be extended to add migration options (as is done in `SqlPersistentStorageMigrator`)

Add `background_downloader_sql` to your dependencies in pubspec.yaml to get `SqlitePersistentStorage` and SQLite related migration options back.

The reason for this change is that the `sqflite` dependency adds significant size to apps, even if they do not use the SQLite functionality.

### Introduce groupNotification

If you download or upload multiple files simultaneously, you may not want a notification for every task, but one notification representing the group of tasks.  To do this, set the `groupNotificationId` field in a `notificationConfig` and use that configuration for all tasks in this group. It is easiest to combine this with the `group` field of the task, e.g.:
```dart
FileDownloader.configureNotificationForGroup('bunchOfFiles',
            running: const TaskNotification(
                '{numFinished} out of {numTotal}', 'Progress = {progress}'),
            complete:
                const TaskNotification('Done!', 'Loaded {numTotal} files'),
            error: const TaskNotification(
                'Error', '{numFailed}/{numTotal} failed'),
            progressBar: true,
            groupNotificationId: 'myGroupNotification');
            
// start every task like this
await FileDownloader().enqueue(DownloadTask(
            url: 'https://your_url.com',
            filename: 'your_filename',
            group: 'bunchOfFiles'));
```

All tasks in group `bunchOfFiles` will now use the notification group configuration with ID `myNotificationGroup`.

### Add `BaseDirectory.root`

You can now pass an absolute path to the downloader by using `BaseDirectory.root` combined with the path in `directory`. This allows you to reach any file destination on your platform. However, be careful: the reason you should not normally do this (and use e.g. `BaseDirectory.applicationDocuments` instead) is that the location of the app's documents directory may change between application starts (on iOS, and on Android in some cases), and may therefore fail for downloads that complete while the app is suspended.  You should therefore never store permanently, or hard-code, an absolute path, unless you are absolutely sure that that path is 'stable'.

### Add fields `mimeType` and `charSet` to `TaskStatusUpdate`

If the server provides this information via the `Content-Type` header then these fields will be non-null only for final states.

### Add Request.cookieHeader to parse 'Set-Cookie' response header

Servers may ask you to set a cookie (via the 'Set-Cookie' header in the response), to be passed along to the next request (in the 'Cookie' header).
This may be needed for authentication, or for session state.

The method `Request.cookieHeader` makes it easy to insert cookies in a request. The first argument `cookies` is either a `http.Response` object (as returned by the `FileDownloader().request` method), a `List<Cookie>`, or a String value from a 'Set-Cookie' header. It returns a `{'Cookie': '...'}` header that can be added to the next request.
The second argument is the `url` you intend to use the cookies with. This is needed to filter the appropriate cookies based on domain and path.

For example:
```dart
final loginResponse = await FileDownloader()
   .request(Request(url: 'https://server.com/login', headers: {'Auth': 'Token'}));
const downloadUrl = 'https://server.com/download';
// add the cookies from the response to the task
final task = DownloadTask(url: downloadUrl, headers: {
  'Auth': 'Token',
  ...Request.cookieHeader(loginResponse, downloadUrl) // inserts the 'Cookie' header
});
```


### Add platformVersion method
Return the platform version as a String:
* On Android this is the API integer, e.g. "33"
* On iOS this is the iOS version, e.g. "16.1"
* On desktop this is a description of the OS version, not parsable

### Add `ready`

If initializing a non-default `PersistentStorage` such as `SqlitePersistentStorage` you may need to wait for database initialization and perhaps migration to complete before using the downloader. Call `await FileDowloader().ready` before the first call that involves the persistent storage. Because initialization is often followed immediately by the `trackTasks` call, that call waits for `ready`, so this is valid:
```dart
await FileDownloader(persistentStorage: SqlitePersistentStorage()).trackTasks();
```

### Remove `awaitGroup`
* Removed all references to `awaitGroup` as the logic for the convenience methods such as `download` has changed
* Removed all references to `modifiedTasks` in `PersistentStorage` interface
* If you use a convenience function, your task _must_ generate status updates (by setting the `updates` field to `Updates.status` - the default - or `Updates.statusAndProgress`)
* If you use a convenience function and specify a progress callback, your task _must_ also generate status updates (by setting the `updates` field to `Updates.statusAndProgress`)

### Bug fixes and other improvements
* Fixes Pause notification issue on iOS
* Fixes issue with priority for multi-part file uploads
* Fixes issue #194: remove notification when canceling a paused task
* Fixes issue #200: prefer UTF-8 filename in Content-Disposition parse
* Fixes issue #202: add minimum deployment target to PodSpec on iOS
* Strip leading path separator from Task.directory instead of throwing an exception
* Refactors code to improve readability


## 7.12.3

Issue #189 related to resume on Android versions prior to S, and to expediting a task prior to S

See https://stackoverflow.com/a/68468786/4172761

Fixes issue with parsing priority from JSON
Fixes issue with setting expedited for Android versions prior to S. This effectively ignores priority (expedited) scheduling for tasks prior to Android S and defaults to normal. 

## 7.12.2

Minor improvements to `TaskQueue` and `MemoryTaskQueue`

## 7.12.1

Bug fix for web compilation

## 7.12.0

### Task priority levels

The `Task.priority` field must be 0 <= priority <= 10 with 0 being the highest priority, and defaults to 5. On Desktop and iOS all priority levels are supported. On Android, priority levels <5 are handled as 'expedited', and >=5 is handled as a normal task.

### Task queues

Once you `enqueue` a task with the `FileDownloader` it is added to an internal queue that is managed by the native platform you're running on (e.g. Android). Once enqueued, you have limited control over the execution order, the number of tasks running in parallel, etc, because all that is managed by the platform.  If you want more control over the queue, you need to add a `TaskQueue`.

The `MemoryTaskQueue` bundled with the `background_downloader` allows:
* pacing the rate of enqueueing tasks, based on `minInterval`, to avoid 'choking' the FileDownloader when adding a large number of tasks
* managing task priorities while waiting in the queue, such that higher priority tasks are enqueued before lower priority ones
* managing the total number of tasks running concurrently, by setting `maxConcurrent`
* managing the number of tasks that talk to the same host concurrently, by setting `maxConcurrentByHost`
* managing the number of tasks running that are in the same `Task.group`, by setting `maxConcurrentByGroup`

A `TaskQueue` conceptually sits 'in front of' the FileDownloader queue. To use it, add it to the `FileDownloader` and instead of enqueuing tasks with the `FileDownloader`, you now `add` tasks to the queue:
```dart
final tq = MemoryTaskQueue();
tq.maxConcurrent = 5; // no more than 5 tasks active at any one time
tq.maxConcurrentByHost = 2; // no more than two tasks talking to the same host at the same time
tq.maxConcurrentByGroup = 3; // no more than three tasks from the same group active at the same time
FileDownloader().add(tq); // 'connects' the TaskQueue to the FileDownloader
FileDownloader().updates.listen((update) { // listen to updates as per usual
  print('Received update for ${update.task.taskId}: $update')
});
for (var n = 0; n < 100; n++) {
  task = DownloadTask(url: workingUrl, metData: 'task #$n'); // define task
  tq.add(task); // add to queue. The queue makes the FileDownloader().enqueue call
}
```

Because it is possible that an error occurs when the taskQueue eventually actually enqueues the task with the FileDownloader, you can listen to the `enqueueErrors` stream for tasks that failed to enqueue.

The default `TaskQueue` is the `MemoryTaskQueue` which, as the  name suggests, keeps everything in memory. This is fine for most situations, but be aware that the queue may get dropped if the OS aggressively moves the app to the background. Tasks still waiting in the queue will not be enqueued, and will therefore be lost. If you want a `TaskQueue` with more persistence, subclass the `MemoryTaskQueue` and add persistence.
In addition, if your app is suspended by the OS due to resource constraints, tasks waiting in the queue will not be enqueued to the native platform and will not run in the background. TaskQueues are therefore best for situations where you expect the queue to be emptied while the app is still in the foreground.


## 7.11.1

Fix #164 for progress updates for uploads.

## 7.11.0

### Android external storage
Add configuration for Android to use external storage instead of internal storage. Either your app runs in default (internal storage) mode, or in external storage. You cannot switch between internal and external, as the directory structure that - for example - `BaseDirectory.applicationDocuments` refers to is different in each mode. See the [configuration document](https://github.com/781flyingdutchman/background_downloader/blob/main/CONFIG.md) for important details and limitations

Use `(Config.useExternalStorage, String whenToUse)` with values 'never' or 'always'. Default is `Config.never`.

### Server suggested filename
If you want the filename to be provided by the server (instead of assigning a value to `filename` yourself), you now have two options. The first is to create a `DownloadTask` that pings the server to determine the suggested filename:
```dart
final task = await DownloadTask(url: 'https://google.com')
        .withSuggestedFilename(unique: true);
```
The method `withSuggestedFilename` returns a copy of the task it is called on, with the `filename` field modified based on the filename suggested by the server, or the last path segment of the URL, or unchanged if neither is feasible (e.g. due to a lack of connection). If `unique` is true, the filename will be modified such that it does not conflict with an existing filename by adding a sequence. For example "file.txt" would become "file (1).txt". You can now also supply a `taskWithFilenameBuilder` to suggest the filename yourself, based on response headers.

The second approach is to set the `filename` field of the `DownloadTask` to `DownloadTask.suggestedFilename`, to indicate that you would like the server to suggest the name. In this case, you will receive the name via the task's status and/or progress updates, so you have to be careful _not_ to use the original task's filename, as that will still be `DownloadTask.suggestedFilename`. For example:
```dart
final task = await DownloadTask(url: 'https://google.com', filename: DownloadTask.suggestedFilename);
final result = await FileDownloader().download(task);
print('Suggested filename=${result.task.filename}'); // note we don't use 'task', but 'result.task'
print('Wrong use filename=${task.filename}'); // this will print '?' as 'task' hasn't changed
```

### Set content length if not provided by server

To provide progress updates (as a percentage of total file size) the downloader needs to know the size of the file when starting the download. Most servers provide this in the "Content-Length" header of their response. If the server does not provide the file size, yet you know the file size (e.g. because you have stored the file on the server yourself), then you can let the downloader know by providing a `{'Range': 'bytes=0-999'}` or a `{'Known-Content-Length': '1000'}` header to the task's `header` field. Both examples are for a content length of 1000 bytes.  The downloader will assume this content length when calculating progress.

### Bug fix

Partial Downloads, using a Range header, can now be properly paused on all platforms.

## 7.10.1

Add `displayName` field to `Task` that can be used to store and display a 'human readable' description of the task. It can be displayed in a notification using {displayName}.

Bug fix for regression in compiling for Web platform (through stubbing - no actual web functionality).

## 7.10.0

Add `ParallelDownloadTask`. Some servers may offer an option to download part of the same file from multiple URLs or have multiple parallel downloads of part of a large file using a single URL. This can speed up the download of large files.  To do this, create a `ParallelDownloadTask` instead of a regular `DownloadTask` and specify `chunks` (the number of pieces you want to break the file into, i.e. the number of downloads that will happen in parallel) and `urls` (as a list of URLs, or just one). For example, if you specify 4 chunks and 2 URLs, then the download will be broken into 8 pieces, four each for each URL.

Note that the implementation of this feature creates a regular `DownloadTask` for each chunk, with the group name 'chunk' which is now a reserved group. You will not get updates for this group, but you will get normal updates (status and/or progress) for the `ParallelDownloadTask`.

## 7.9.4

Enable compile for Web platform (through stubbing - no actual web functionality).

Automatically dismiss "complete" and "error" notifications when the user taps on the notification.

## 7.9.3

Bug fix for validating URLs to allow localhost URLs.

Update to Android Gradle Plugin 8.1.0

## 7.9.2

Add configuration `Config.useCacheDir` for Android and improved temp file logic. By default (`Config.whenAble`) the downloader will now use the application's `cacheDir` when the size of the file to download is less than half of the `cacheQuotaBytes` given to the app by Android, and use `filesDir` otherwise. If you find that downloads do not complete (or cannot be resumed when paused) this indicates the OS is removing the temp file from the `cacheDir` due to low memory conditions. In that situation, consider using `Config.never` to force the use of `filesDir`, but make sure to clean up remnant temp files in `filesDir`, as the OS does not do that for you. 

Fix for Android 33 related to the new [predictive back gesture navigation](https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture)

Documentation updates

## 7.9.1

Failed download tasks can now be resumed (under certain conditions) even if the `Task.allowPause` field is false. Resuming a failed task will attempt to continue the download where the failure occurred.  If `retries` are set to a value >0 then retries will also first attempt to resume, and only start from scratch if that fails.

Tasks can only resume if the ETag header provided by the server is strong, and equal to the ETag at the moment the download was paused/failed, or if it is not provided at all.

## 7.9.0

### Configuration

Add configuration of the downloader for several aspects:
* Running tasks in 'foreground mode' on Android to allow longer runs and prevent the OS killing some tasks when the app is in the background
* Setting the request timeout value and, for iOS only, the 'resourceTimeout'
* Checking available space before attempting a download
* Setting a proxy
* Localizing the notification button texts on iOS
* Bypassing TLS Certificate validation (for debug mode only)

Please read the [configuration document](https://github.com/781flyingdutchman/background_downloader/blob/main/CONFIG.md) for details on how to configure.

Configuration is experimental, so please test thoroughly before using in production, and let me know if there are any issues.

### Network speed and time remaining in `TaskStatusUpdate`
`TaskStatusUpdate` now has fields `networkSpeed` (in MB/s) and `timeRemaining`. Check the associated `hasNetworkSpeed` and `hasTimeRemaining` before using the values in these fields.  Use `networkSpeedAsString` and `timeRemainingAsString` for human readable versions of these values.

### Filter `TaskRecord` entries by status: `allRecordsWithStatus`
The `database` now has method `allRecordsWithStatus` to filter records based on their `TaskStatus`

## 7.8.1

Bug fix for `taskNotificationTapCallback`: convenience methods that `await` a result, such as `download` (but not `enqueue`), now use the default `taskNotificationTapCallback`, even though those tasks are in the `awaitGroup`, because that behavior is more in line with expectations. If you need a separate callback for the `awaitGroup`, then set it _after_ setting the default callback. You set the default callback by omitting the `group` parameter in the `registerCallbacks` call.

## 7.8.0

Added field `responseBody` to `TaskStatusUpdate` that, if not null, contains the server response for uploads, and for downloads that are not complete (e.g. `.notFound`). In those instances, the server response may contain useful information (e.g. a url where the uploaded file can be found, or the reason for the 'not found' status as provided by the server)

Improved handling of notification tap callbacks.

## 7.7.1

Bug fix for Flutter Downloader migration on iOS, issue #86

## 7.7.0 

### Uploading multiple files in a single request
If you need to upload multiple files in a single request, create a [MultiUploadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/MultiUploadTask-class.html) instead of an `UploadTask`. It has similar parameters as the `UploadTask`, except you specify a list of files to upload as the `files` argument of the constructor, and do not use `fileName`, `fileField` and `mimeType`. Each element in the `files` list is either:
* a filename (e.g. `"file1.txt"`). The `fileField` for that file will be set to the base name (i.e. "file1" for "file1.txt") and the mime type will be derived from the extension (i.e. "text/plain" for "file1.txt")
* a record containing `(fileField, filename)`, e.g. `("document", "file1.txt")`. The `fileField` for that file will be set to "document" and the mime type derived from the file extension (i.e. "text/plain" for "file1.txt")
* a record containing `(filefield, filename, mimeType)`, e.g. `("document", "file1.txt", "text/plain")`

The `baseDirectory` and `directory` fields of the `MultiUploadTask` determine the expected location of the file referenced, unless the filename used in any of the 3 formats above is an absolute path (e.g. "/data/user/0/com.my_app/file1.txt"). In that case, the absolute path is used and the `baseDirectory` and `directory` fields are ignored for that element of the list.
Once the `MultiUpoadTask` is created, the fields `fileFields`, `filenames` and `mimeTypes` will contain the parsed items, and the fields `fileField`, `filename` and `mimeType` contain those lists encoded as a JSON string.

Use the `MultiTaskUpload` object in the `upload` and `enqueue` methods as you would a regular `UploadTask`.

### Flutter Downloader migration
Bug fixes related to migration from Flutter Downloader (see version 7.6.0). The migration is still experimental, so please test thoroughly before relying on the migration in your app.

### Bug fixes

Fixed a bug on iOS related to NSNull Json decoding

## 7.6.0

Added `SqlitePersistentStorage` as an alternative backing storage for the downloader, and implemented migration of a pre-existing database from the Flutter Downloader package. We use the `sqflite` package, so this is only supported iOS and Android.

To use the downloader with SQLite backing and migration from Flutter Downloader, initialize the `FileDownloader` at the very beginning of your app:
```dart
final sqlStorage = SqlitePersistentStorage(migrationOptions: ['flutter_downloader', 'local_store']);
FileDownloader(persistentStorage: sqlStorage);
// start using the FileDownloader
```

This will migrate from either Flutter Downloader or the default LocalStore.

Added an optional parameter to the tasksFinished method that allows you to use it the moment you receive a status update for a task, like this:
```dart
void downloadStatusCallback(TaskStatusUpdate update) async {
    // process your status update, then check if all tasks are finished
    final bool allTasksFinished = update.status.isFinalState && 
        await FileDownloader().tasksFinished(ignoreTaskId: update.task.taskId) ;
    print('All tasks finished: $allTasksFinished');
  }
```
This excludes the task that is currently finishing up from the test. Without this, it's possible `tasksFinished` returns `false` as that currently finishing task may not have left the queue yet.

## 7.5.0

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

Bug fixes:
* Fixed bug when download is interrupted due to lost network connection (on Android)
* Fixed bug with `moveToSharedStorage` on iOS: shared storage is now 'faked' on iOS, creating 
subdirectories of the regular Documents directory, as iOS apps do not have access to shared 
media and download directories
* Fixed bug with notifications disappearing on iOS

## 7.4.1

Bug fix for type cast errors and for thread safety on iOS for notifications

## 7.4.0

Added method `expectedFileSize()` to `DownloadTask`, and added field `expectedFileSize` to  
`TaskProgressUpdate` (provided to callbacks or listeners during download), and `TaskRecord` 
entries in the database. 
Note that this field is only valid when 0 < progress < 1. It is -1 if file size cannot be determined. 

## 7.3.1

Improved [DownloadProgressIndicator](https://pub.dev/documentation/background_downloader/latest/background_downloader/DownloadProgressIndicator-class.html) widget:
* In collapsed state, now shows progress as 'n' files finished out of 'total' started (and progress as that fraction)
* Option to force collapsed state always by setting `maxExpandable` to 0. When set to 1, the indicator collapses only when the second download starts. When set greater than 1, the indicator expands to show multiple simultaneous downloads.

Added usage examples upfront in the readme

## 7.3.0

Added [DownloadProgressIndicator](https://pub.dev/documentation/background_downloader/latest/background_downloader/DownloadProgressIndicator-class.html) widget and modified the example app to show how to wire it up.

The widget is configurable (e.g. pause and cancel buttons) and can show multiple downloads simultaneously in either an expanded
or collapsed mode.

If tracking downloads in persistent storage, pausing a file now does not override the stored progress with `progressPaused`.

Fixed bugs.

## 7.2.0

Added option to use a different persistent storage solution than the one provided by default. The downloader stores a few things in persistent storage, and uses a modified version of the [localstore](https://pub.dev/packages/localstore) package by default. To use a different persistent storage solution, create a class that implements the [PersistentStorage](https://pub.dev/documentation/background_downloader/latest/background_downloader/PersistentStorage-class.html) interface, and initialize the downloader by calling `FileDownloader(persistentStorage: yourStorageClass())` as the first use of the `FileDownloader`.

A simple example is included in the example app (using the [sqflite](https://pub.dev/packages/sqflite) package).

Fixed a few bugs.

## 7.1.0

Added `tasksFinished` method that returns `true` if all tasks in the group have finished

Fixed bug related to `allTasks` method

## 7.0.2

Added `namespace` to Android build.gradle and removed irrelevant log messages

Fixed permission bug on Android 10

Changed class modifiers to allow mocking with Mockito

## 7.0.1

Migrating the persistent data from the documents directory to the support directory, so it is no longer visible in - for example - the iOS Files app, or the Linux home directory.

Further Dart 3 changes (not visible to user).

## 7.0.0

Migration to Dart 3 - not other functional change or API change.  If you use Dart 2 please use version `6.1.1` of this plugin, which will be maintained until the end of 2023.

Most classes in the package are now `final` classes, and under the hood we use the new Records and Pattern matching features of Dart 3. None of this should matter if you've used the package as intended.

## 6.3.2

Fixed a bug on iOS related to NSNull Json decoding

## 6.3.1

Added an optional parameter to the tasksFinished method that allows you to use it the moment you receive a status update for a task, like this:
```dart
void downloadStatusCallback(TaskStatusUpdate update) async {
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

Bug fixes:
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
* You can override the `httpRequestMethod` used for requests by setting it in the `Request`, `DownloadTask` or `UploadTask`. By default, requests and downloads use GET (unless `post` is set) and uploads use POST
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
