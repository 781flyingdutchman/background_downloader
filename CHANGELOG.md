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
