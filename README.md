# A background file downloader for iOS and Android

Define where to get your file from, where to store it, and how you want to monitor the download, and the background loader will ensure this is done in a responsible way using native platform background downloaders.  `background_downloader` uses URLSessions on iOS and DownloadWorker on Android, so tasks will complete also when your app is in the background.

## Concepts and basic usage

A download is defined by a `BackgroundDownloadTask` object that contains the download instructions, and updates related to that task are passed on to callbacks that you need to register.

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

Note that success only refers to the enqueueing of the download task, not its result, which must be monitored via the `downloadStatusCallback`. It will receive an update with status `DownloadTaskStatus.running`, followed by a status update with the result (e.g. `DownloadTaskStatus.complete` or `DownloadTaskStatus.failed`).

## Location of the downloaded file

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


## Monitoring progress while downloading

To also monitor progress while the file is downloading, register the `DownloadProgressCallback` and add a `progressUpdates` parameter to the task:
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

Progress updates will be sent periodically, not more than twice per second per task.  If a task completes successfully, the `DownloadProgressCallback` is called with a `progress` value of 1.0. Failed tasks generate `progress` of -1, cancelled tasks -2 and notFound tasks -3.

Because you can use the `progress` value to derive task status, you can choose to not receive status updates by setting the `progressUpdates` parameter of a task to `DownloadTaskProgressUpdates.progressUpdates` (and you won't need to register a `DownloadStatusCallback`). If you don't want to use any callbacks (and just check if the file exists after a while!) set the `progressUpdates` parameter of a task to `DownloadTaskProgressUpdates.none`.

## Simplified use

If status and progress monitoring is not required, you can also use the convenience methode `download`, which will only return when the file download has  completed or failed:
```
    final result = await FileDownloader.download(task);
```

The `result` will be a `DownloadTaskStatus` and should be checked for completion, failure etc.  Note that for this use, `BackgroundDownloadTask` fields `group` and `progressUpdates` should not be set, as they are used by the `FileDownloader` for this convenience method.

## Advanced use

Optionally, `headers` can be added to the `BackgroundDownloadTask`, which will be added to the http request. This may be useful for authentication, for example. Also optionally, `metaData` can be added to the `BackgroundDownloadTask`, which is ignored by the downloader but may be helpful when receiving an update about the task.

To manage or monitor tasks, use the following methods:
* `reset` to reset the downloader by cancelling all ongoing download tasks
* `allTaskIds` to get a list of `taskId` values of all tasks currently running (i.e. not completed in any way)
* `cancelTasksWithIds` to cancel all tasks with a `taskId` in the provided list of taskIds
* `taskForId` to get the `BackgroundDownloadTask` for the given `taskId`, or `null` if not found. Only tasks that are running (ie. not completed in any way) are guaranteed to be returned, but returning a task does not guarantee that it is running

Because an app may require different types of downloads, and handle those differently, you can specify a `group` with your task, and register callbacks specific to each `group`. If no group is specified (as in the examples above), the default group `default` is used. For example, to create and handle downloads for group 'bigFiles':
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

The methods `initialize`, `registerCallBacks`, `reset` and `allTaskIds` all take an optional `group` parameter to target tasks in a specific group. Note that if tasks are enqueued with a `group` other than default, calling any of these methods without a group parameter will not affect/include those tasks - only the default tasks.

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
* On both platforms, downloads will not start without a network connection, and do not distinguish between metered (cellular) and unmetered (WiFi) connections
* Redirects will be followed
* Background downloads are aggressively controlled by the native platform. You should therefore always assume that a task that was started may not complete, and may disappear without providing any status or progress update to indicate why. For example, if a user swipes your app up from the iOS App Switcher, all scheduled background downloads are terminated without notification 
