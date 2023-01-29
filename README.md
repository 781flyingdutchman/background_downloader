# A background file downloader for iOS and Android

Define where to get your file from, where to store it, and how you want to monitor the download in a [BackgroundDownloadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/BackgroundDownloadTask-class.html), then `enqueue` the task.  Background_downloader uses URLSessions on iOS and DownloadWorker on Android, so tasks will complete also when your app is in the background.

You can monitor download tasks using an [event listener](#using-an-event-listener) or [callbacks](#using-callbacks), or use convenience functions to `await` the download of a [file](#awaiting-a-download) or a [batch](#awaiting-a-batch-download) of files. If you just want to make a regular [server request](#server-requests-without-file-download) using similar terminology, create a [Request](https://pub.dev/documentation/background_downloader/latest/background_downloader/Request-class.html) and call `request`.

The downloader supports [headers](#headers), [retries](#retries), [requiring WiFi](#requiring-wifi) before starting the download, user-defined [metadata](#metadata) and GET and [POST](#post-requests) http(s) requests. You can [manage and monitor the tasks in the queue](#managing-and-monitoring-tasks-in-the-queue), and have different handlers for updates by [group](#grouping-tasks).

No setup is required for Android, and only minimal [setup for iOS](#initial-setup-for-ios).


## Concepts and basic usage

A download is defined by a `BackgroundDownloadTask` object that contains the download instructions, and updates related to that task are passed on to a stream you can listen to, or alternatively to callback functions that you register.

Once a task is enqueued for download, you will receive an update with `DownloadTaskStatus.enqueued` almost immediately, followed by `.running` when the actual download starts, followed by a status update with the result (e.g. `.complete`, `.failed`, `.notFound`, or - if [retries](#retries) are enabled - `.waitingToRetry`).  If you [cancel](#managing-and-monitoring-tasks-in-the-queue) the task you will receive `.canceled`.

### Using an event listener

For simple downloads you listen to events from the downloader, and process those. For example, the following creates a listener to monitor status and progress updates for downloads, and then enqueues a task as an example:
```
  FileDownloader.initialize();  // initialize before starting to listen
  final subscription = FileDownloader.updates.listen((event) {
      if (event is BackgroundDownloadStatusEvent) {
        print('Status update for ${event.task} with status ${event.status}');
      } else if (event is BackgroundDownloadProgressEvent) {
        print('Progress update for ${event.task} with progress ${event.progress}');
    });
    // initate a download
    final successFullyEnqueued = await FileDownloader.enqueue(
      BackgroundDownloadTask(url: 'https://google.com', filename: 'google.html'));
    // status update events will be sent to your subscription listener
```

Note that `successFullyEnqueued` only refers to the enqueueing of the download task, not its result, which must be monitored via the listener.

You can start your subscription in a convenient place, like a widget's `initState`, and don't forget to cancel your subscription to the stream using `subscription.cancel()`. Note the stream can only be listened to once: to listen again, first call `FileDownloader.initialize()`.

### Using callbacks

For more complex downloads (e.g. if you want different handlers for different groups of downloads - see [below](#grouping-tasks)) you can register a callback for status updates, and/or a callback for progress updates.

The `DownloadStatusCallback` receives the `BackgroundDownloadTask` and the updated `DownloadTaskStatus`, so a simple callback function is:
```
void downloadStatusCallback(
    BackgroundDownloadTask task, DownloadTaskStatus status) {
  print('downloadStatusCallback for $task with status $status');
}
```

The `DownloadProgressCallback` receives the `BackgroundDownloadTask` and `progess` as a double, so a simple callback function is:
```
void downloadProgressCallback(BackgroundDownloadTask task, double progress) {
  print('downloadProgressCallback for $task with progress $progress');
}
```

A basic file download with just status monitoring (no progress) then requires initialization to register the callback, and a call to `enqueue` to start the download:
``` 
  FileDownloader.initialize(downloadStatusCallback: downloadStatusCallback);
  final successFullyEnqueued = await FileDownloader.enqueue(
      BackgroundDownloadTask(url: 'https://google.com', filename: 'google.html'));
```

If you register a callback for a type of task, updates are provided only through that callback and will not be posted on the `updates` stream.

### Location of the downloaded file

The `filename` of the task refers to the filename without directory. To store the task in a specific directory, add the `directory` parameter to the task. That directory is relative to the base directory, so cannot start with a `/`. By default, the base directory is the directory returned by the call to `getApplicationDocumentsDirectory()`, but this can be changed by also passing a `baseDirectory` parameter (`BaseDirectory.temporary` for the directory returned by `getTemporaryDirectory()` and `BaseDirectory.applicationSupport` for the directory returned by `getApplicationSupportDirectory()` which is only supported on iOS).

So, to store a file named 'testfile.txt' in the documents directory, subdirectory 'my/subdir', define the task as follows:
```
final task = BackgroundDownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt',
        directory: 'my/subdir');
```

To store that file in the temporary directory:
```
final task = BackgroundDownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt',
        directory: 'my/subdir',
        baseDirectory: BaseDirectory.temporary);
```

The downloader will only store the file upon success (so there will be no partial files saved), and if so, the destination is overwritten if it already exists, and all intermediate directories will be created if needed.

Note: the reason you cannot simply pass a full absolute directory path to the downloader is that the location of the app's documents directory may change between application starts (on iOS), and may therefore fail for downloads that complete while the app is suspended.  You should therefore never store permanently, or hard-code, an absolute path.


### Monitoring progress while downloading

Status updates only report on start and finish of a download. To also monitor progress while the file is downloading, listen for `BackgroundDownloadProgressEvent` on the `Filedownloader.updates` stream (or register a `DownloadProgressCallback`) and add a `progressUpdates` parameter to the task:
``` 
    FileDownloader.initialize(
        downloadStatusCallback: downloadStatusCallback,
        downloadProgressCallback: downloadProgressCallback);
    final task = BackgroundDownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
        progressUpdates:  // needed to also get progress updates
            DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
    final successFullyEnqueued = await FileDownloader.enqueue(task);
```

Progress updates will be sent periodically, not more than twice per second per task.  If a task completes successfully you will receive a progress update with a `progress` value of 1.0. Failed tasks generate `progress` of -1, cancelled tasks -2, notFound tasks -3 and waitingToRetry tasks -4.

Because you can use the `progress` value to derive task status, you can choose to not receive status updates by setting the `progressUpdates` parameter of a task to `DownloadTaskProgressUpdates.progressUpdates` (and you won't need to register a `DownloadStatusCallback` or listen for status updates). If you don't want to use any callbacks (and just check if the file exists after a while!) set the `progressUpdates` parameter of a task to `DownloadTaskProgressUpdates.none`.

If instead of using callbacks you are listening to the `Filedownloader.updates` stream, you can distinguish progress updates from status updates by testing the event's type (`BackgroundDownloadStatusEvent` or `BackgroundDownloadProgressEvent`) and handle it accordingly.

## Simplified use

Simplified use does not require you to register callbacks or listen to updates: you just call `.download` or `.downloadBatch` and wait for the result.  Note that for simplified use, `BackgroundDownloadTask` fields `group` and `progressUpdates` should not be set, as they are used by the `FileDownloader` for these convenience methods, and may be overwritten. For tasks scheduled using the convenience methods below, no download or progress callbacks will be called, and no updates will be sent to your listener.

### Awaiting a download

If status and progress monitoring is not required, use the convenience method `download`, which returns a `Future` that completes when the file download has completed or failed:
```
    final result = await FileDownloader.download(task);
```

The `result` will be a `DownloadTaskStatus` and should be checked for completion, failure etc.

### Awaiting a batch download

To download a batch of files and wait for completion, create a `List` of `BackgroundDownloadTask` objects and call `downloadBatch`:
```
   final result = await FileDownloader.downloadBatch(tasks);
```

The result is a `BackgroundDownloadBatch` object that contains the result for each task in `.results`. You can use `.numSucceeded` and `.numFailed` to check if all files in the batch downloaded successfully, and use `.succeeded` or `.failed` to iterate over successful or failed tasks within the batch - for example to report back, or to retry.  If you want to get progress updates for the batch (in terms of how many files have been downloaded) then add a callback:
```
   final result = await FileDownloader.downloadBatch(tasks, (succeeded, failed) {
      print('$succeeded files succeeded, $failed have failed');
      print('Progress is ${(succeeded + failed) / tasks.length} %');
   });
```
The callback will be called upon completion of each task (whether successful or not), and will start with (0, 0) before any downloads start, so you can use that to start a progress indicator.  Note that it is not possible to monitor download progress of individual files within the batch - you need to  `enqueue` individual files to do that.

### Server requests without file download

To make a regular server request (e.g. to obtain a response from an API end point that you process directly in your app) use the `request` method.  It works similar to the `download` request, except you can pass a `Request` object that has fewer fields than the `BackgroundDownloadTask`, but is similar in structure.  You `await` the response, which will be a `Resonse` object as defined in the dart `http` package, and includes getters for the response body (as a `String` or as `UInt8List`), `statusCode` and `reasonPhrase`.

## Advanced use

### Headers

Optionally, `headers` can be added to the `BackgroundDownloadTask`, which will be added to the HTTP request. This may be useful for authentication, for example.

### Retries

To schedule automatic retries of failed downloads (with exponential backoff), set the `retries` field of the `BackgroundDownloadTask` to an
integer between 0 and 10. A normal download (without the need for retries) will follow status
updates from `enqueued` -> `running` -> `complete` (or `notFound`). If `retries` has been set and
the task fails, the sequence will be `enqueued` -> `running` ->
`waitingToRetry` -> `enqueued` -> `running` -> `complete` (if the second try succeeds, or more
retries if needed).

### Requiring WiFi

If the `requiresWiFi` field of a `BackgroundDownloadTask` is set to true, the task won't start downloading unless a WiFi network is available. By default `requiresWiFi` is false, and downloads will use the cellular (or metered) network if WiFi is not available, which may incur cost.

### Metadata

Also optionally, `metaData` can be added to the `BackgroundDownloadTask` (a `String`). Metadata is ignored by the downloader but may be helpful when receiving an update about the task.

### POST requests

If the server request is a HTTP POST request (instead of the default GET request) then set the `post` field of the `BackgroundDownloadTask` to a `String` or `UInt8List` representing the data to be posted (for example, a JSON representation of an object). To make a POST request with no data, set `post` to an empty `String`.

### Managing and monitoring tasks in the queue

To manage or monitor tasks, use the following methods:
* `reset` to reset the downloader by cancelling all ongoing download tasks
* `allTaskIds` to get a list of `taskId` values of all tasks currently active (i.e. not in a final state). You can exclude tasks waiting for retries by setting `includeTasksWaitingToRetry` to `false`
* `allTasks` to get a list of all tasks currently active (i.e. not in a final state). You can exclude tasks waiting for retries by setting `includeTasksWaitingToRetry` to `false`
* `cancelTasksWithIds` to cancel all tasks with a `taskId` in the provided list of taskIds
* `taskForId` to get the `BackgroundDownloadTask` for the given `taskId`, or `null` if not found. Only tasks that are running (ie. not in a final state) are guaranteed to be returned, but returning a task does not guarantee that it is running

### Grouping tasks

Because an app may require different types of downloads, and handle those differently, you can specify a `group` with your task, and register callbacks specific to each `group`. If no group is specified (as in the examples above), the default group named `default` is used. For example, to create and handle downloads for group 'bigFiles':
```
  FileDownloader.registerCallbacks(
        group: 'bigFiles'
        downloadStatusCallback: bigFilesDownloadStatusCallback,
        downloadProgressCallback: bigFilesDownloadProgressCallback);
  final task = BackgroundDownloadTask(
        group: 'bigFiles',
        url: 'https://google.com',
        filename: 'google.html',
        progressUpdates:
            DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
  final successFullyEnqueued = await FileDownloader.enqueue(task);
```

The methods `initialize`, `registerCallBacks`, `reset`, `allTaskIds` and `allTasks` all take an optional `group` parameter to target tasks in a specific group. Note that if tasks are enqueued with a `group` other than default, calling any of these methods without a group parameter will not affect/include those tasks - only the default tasks.

If you listen to the `updates` stream instead of using callbacks, you can test for the task's `group` field in your event listener, and process the event differently for different groups.

## Initial setup for iOS

On iOS, ensure that you have the Background Fetch capability enabled:
* Select the Runner target in XCode
* Select the Signing & Capabilities tab
* Click the + icon to add capabilities
* Select 'Background Modes'
* Tick the 'Background Fetch' mode

Note that iOS by default requires all URLs to be https (and not http). See [here](https://developer.apple.com/documentation/security/preventing_insecure_network_connections) for more details and how to address issues.

No setup is required for Android.

## Limitations

* On Android, once started, a background download must complete within 8 minutes
* On iOS, once enqueued, a background download must complete within 4 hours
* Redirects will be followed
* Background downloads are aggressively controlled by the native platform. You should therefore always assume that a task that was started may not complete, and may disappear without providing any status or progress update to indicate why. For example, if a user swipes your app up from the iOS App Switcher, all scheduled background downloads are terminated without notification 