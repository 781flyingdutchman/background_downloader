# A background file downloader and uploader for iOS, Android, MacOS, Windows and Linux

Create a [DownloadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/DownloadTask-class.html) to define where to get your file from, where to store it, and how you want to monitor the download, then call `FileDownloader().download` and wait for the result.  Background_downloader uses URLSessions on iOS and DownloadWorker on Android, so tasks will complete also when your app is in the background. The download behavior is highly consistent across all supported platforms: iOS, Android, MacOS, Windows and Linux.

Monitor progress by passing an `onProgress` listener, and monitor detailed status updates by passing an `onStatus` listener to the `download` call.  Alternatively, monitor tasks centrally using an [event listener](#using-an-event-listener) or [callbacks](#using-callbacks) and call `enqueue` to start the task.

Optionally, keep track of task status and progress in a persistent [database](#using-the-database-to-track-tasks).

To upload a file, create an [UploadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/UploadTask-class.html) and call `upload`. To make a regular [server request](#server-requests), create a [Request](https://pub.dev/documentation/background_downloader/latest/background_downloader/Request-class.html) and call `request`.

The plugin supports [headers](#headers), [retries](#retries), [requiring WiFi](#requiring-wifi) before starting the up/download, user-defined [metadata](#metadata) and GET and [POST](#post-requests) http(s) requests. You can [manage and monitor the tasks in the queue](#managing-and-monitoring-tasks-in-the-queue), and have different handlers for updates by [group](#grouping-tasks) of tasks.

No setup is required for Android, Windows and Linux, and only minimal [setup for iOS](#ios) and [MacOS](#macos).

## Contents

- [Basic use](#basic-use)
  - [Tasks and the FileDownloader](#tasks-and-the-filedownloader)
  - [Monitoring the task](#monitoring-the-task)
  - [Specifying the location of the file to download or upload](#specifying-the-location-of-the-file-to-download-or-upload)
  - [A batch of files](#a-batch-of-files)
- [Central monitoring and tracking in a persistent database](#central-monitoring-and-tracking-in-a-persistent-database)
  - [Using an event listener](#using-an-event-listener)
  - [Using callbacks](#using-callbacks)
  - [Using the database to track Tasks](#using-the-database-to-track-tasks)
- [Uploads](#uploads)
- [Managing and monitoring tasks in the queue](#managing-and-monitoring-tasks-in-the-queue)
  - [Grouping tasks](#grouping-tasks)
- [Server requests](#server-requests)
- [Optional parameters](#optional-parameters)

## Basic use

### Tasks and the FileDownloader

A `DownloadTask` or `UploadTask` (both subclasses of `Task`) defines one download or upload. It contains the `url`, the file name and location, what updates you want to receive while the task is in progress, [etc](#optional-parameters).  The [FileDownloader](https://pub.dev/documentation/background_downloader/latest/background_downloader/FileDownloader-class.html) class is the entrypoint for all calls. To download a file:
```
    final task = DownloadTask(
            url: 'https://google.com',
            filename: 'testfile.txt'); // define your task
    final result = await FileDownloader().download(task);  // do the download and wait for result
```

The `result` will be a `TaskStatus` that represents how the download ended: `.complete`, `.failed`, `.canceled` or `.notFound`.

### Monitoring the task

#### Progress

If you want to monitor progress during the download itself (e.g. for a large file), then add a progress callback that takes a double as its argument:
```
    final result = await FileDownloader().download(task, 
        onProgress: (progress) => print('Progress update: $progress'));
```
Progress updates start with 0.0 when the actual download starts (which may be in the future, e.g. if waiting for a WiFi connection), and will be sent periodically, not more than twice per second per task.  If a task completes successfully you will receive a final progress update with a `progress` value of 1.0 (`progressComplete`). Failed tasks generate `progress` of `progressFailed` (-1.0), canceled tasks `progressCanceled` (-2.0), notFound tasks `progressNotFound` (-3.0) and waitingToRetry tasks `progressWaitingToRetry` (-4.0).

#### Status

If you want to monitor status changes while the download is underway (i.e. not only the final state, which you will receive as the result of the `download` call) you can add a status change callback that takes the status as an argument:
```
    final result = await FileDownloader().download(task, 
        onStatus: (status) => print('Status update: $status'));
```

The status will follow a sequence of `.enqueued` (waiting to execute), `.running` (actively downloading) and then one of the final states mentioned before, or `.waitingToRetry` if retries are enabled and the task failed.


### Specifying the location of the file to download or upload

In the `DownloadTask` and `UploadTask` objects, the `filename` of the task refers to the filename without directory. To store the task in a specific directory, add the `directory` parameter to the task. That directory is relative to the base directory, so cannot start with a `/`. By default, the base directory is the directory returned by the call to `getApplicationDocumentsDirectory()`, but this can be changed by also passing a `baseDirectory` parameter (`BaseDirectory.temporary` for the directory returned by `getTemporaryDirectory()` and `BaseDirectory.applicationSupport` for the directory returned by `getApplicationSupportDirectory()`).

So, to store a file named 'testfile.txt' in the documents directory, subdirectory 'my/subdir', define the task as follows:
```
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt',
        directory: 'my/subdir');
```

To store that file in the temporary directory:
```
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt',
        directory: 'my/subdir',
        baseDirectory: BaseDirectory.temporary);
```

The downloader will only store the file upon success (so there will be no partial files saved), and if so, the destination is overwritten if it already exists, and all intermediate directories will be created if needed.

Note: the reason you cannot simply pass a full absolute directory path to the downloader is that the location of the app's documents directory may change between application starts (on iOS), and may therefore fail for downloads that complete while the app is suspended.  You should therefore never store permanently, or hard-code, an absolute path.

### A batch of files

To download a batch of files and wait for completion of all, create a `List` of `DownloadTask` objects and call `downloadBatch`:
```
   final result = await FileDownloader().downloadBatch(tasks);
```

The result is a `Batch` object that contains the result for each task in `.results`. You can use `.numSucceeded` and `.numFailed` to check if all files in the batch downloaded successfully, and use `.succeeded` or `.failed` to iterate over successful or failed tasks within the batch.  If you want to get progress updates for the batch (in terms of how many files have been downloaded) then add a callback:
```
   final result = await FileDownloader().downloadBatch(tasks, (succeeded, failed) {
      print('$succeeded files succeeded, $failed have failed');
      print('Progress is ${(succeeded + failed) / tasks.length} %');
   });
```
The callback will be called upon completion of each task (whether successful or not), and will start with (0, 0) before any downloads start, so you can use that to start a progress indicator.  Note that it is not possible to monitor download progress of individual files within the batch.

For uploads, create a `List` of `UploadTask` objects and call `uploadBatch` - everything else is the same.

## Central monitoring and tracking in a persistent database

Instead of monitoring in the `download` call, you may want to use a centralized task monitoring approach, and/or keeping track of tasks in a database. This is helpful for instance if:
1. You start download in multiple locations in your app, but want to monitor those in one place, instead of defining `onStatus` and `onProgress` for every call to `download`
2. You have different groups of tasks, and each group needs a different monitor
3. You want to keep track of the status and progress of tasks in a persistent database that you query
4. Your downloads take long, and your user may switch away from your app for a long time, which causes your app to get suspended by the operating system. The downloads continue in the background and will finish eventually, but when your app restarts from a suspended state, the result `Future` that you were awaiting when you called `download` may no longer be 'alive', and you will therefore miss the completion of the downloads that happened while suspended. This situation is uncommon, as the app will typically remain alive for several minutes even when moving to the background, but if you find this to be a problem for your use case, then you should process status and progress updates for long running background tasks centrally.

Central monitoring can be done by listening to an updates stream, or by registering callbacks. In both cases you now use `enqueue` instead of `download` or `upload`. `enqueue` returns almost immediately with a `bool` to indicate if the `Task` was successfully enqueued. Monitor status changes and act when a `Task` completes via the listener or callback.  As long as you start listening to the updates (or register your callbacks) as soon as your app starts, you will get notified of status and progress update changes that happened while your app was suspended, immediately after the app awakes.


### Using an event listener

Listen to updates from the downloader by listening to the `updates` stream, and process those updates centrally. For example, the following creates a listener to monitor status and progress updates for downloads, and then enqueues a task as an example:
```
  final subscription = FileDownloader().updates.listen((update) {
      if (update is TaskStatusUpdate) {
        print('Status update for ${update.task} with status ${update.status}');
      } else if (update is TaskProgressUpdate) {
        print('Progress update for ${update.task} with progress ${update.progress}');
    });
    // define the task
    final task = DownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
        updates:
            Updates.statusAndProgress); // needed to also get progress updates
    // enqueue the download
    final successFullyEnqueued = await FileDownloader().enqueue(task);
    // updates will be sent to your subscription listener
```

Note that `successFullyEnqueued` only refers to the enqueueing of the download task, not its result, which must be monitored via the listener. Also note that in order to get progress updates the task must set its `updates` field to a value that includes progress updates. In the example, we are asking for both status and progress updates, but other combinations are possible. For example, if you set `updates` to `Updates.status` then the task will only generate status updates and no progress updates. You define what updates to receive on a task by task basis via the `Task.updates` field, which defaults to status updates only.

You can start your subscription in a convenient place, like a widget's `initState`, and don't forget to cancel your subscription to the stream using `subscription.cancel()`. Note the stream can only be listened to once.

### Using callbacks

Instead of listening to the `updates` stream you can register a callback for status updates, and/or a callback for progress updates.  This may be the easiest way if you want different callbacks for different [groups](#grouping-tasks).

The `TaskStatusCallback` receives the `Task` and the updated `TaskStatus`, so a simple callback function is:
```
void taskStatusCallback(
    Task task, TaskStatus status) {
  print('taskStatusCallback for $task with status $status');
}
```

The `TaskProgressCallback` receives the `Task` and `progess` as a double, so a simple callback function is:
```
void taskProgressCallback(Task task, double progress) {
  print('taskProgressCallback for $task with progress $progress');
}
```

A basic file download with just status monitoring (no progress) then requires registering the central callback, and a call to `enqueue` to start the download:
``` 
  FileDownloader().registerCallbacks(taskStatusCallback: taskStatusCallback);
  final successFullyEnqueued = await FileDownloader().enqueue(
      DownloadTask(url: 'https://google.com', filename: 'google.html'));
```

You define what updates to receive on a task by task basis via the `Task.updates` field, which defaults to status updates only.  If you register a callback for a type of task, updates are provided only through that callback and will not be posted on the `updates` stream.

Note that all tasks will call the same callback, unless you register separate callbacks for different [groups](#grouping-tasks) and set your `Task.group` field accordingly.

### Using the database to track Tasks

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

You can interact with the `database` using 
`allRecords`, `allRecordsOlderThan`, `recordForId`, 
`deleteAllRecords`, 
`deleteRecordWithId` etc. Note that only tasks that you asked to be tracked (using `trackTasks`, which activates tracking for all tasks in a group) will be in the database. All active tasks in the queue, regardless of tracking, can be queried via the `FileDownloader().taskForId` call etc, but those will only return the task itself, not its status or progress, as those are expected to be monitored via listener or callback.  Note: tasks that are started using `download`, `upload`, `batchDownload` or `batchUpload` are assigned a special group name 'await', as callbacks for these tasks are handled within the `FileDownloader`. If you want to  track those tasks in the database, call `FileDownloader().trackTasks(FileDownloader.awaitGroup)` at the start of your app.

## Uploads

Uploads are very similar to downloads, except:
* define an `UploadTask` object instead of a `DownloadTask`
* the file location now refers to the file you want to upload
* call `upload` instead of `download`, or `uploadBatch` instead of `downloadBatch`

There are two ways to upload a file to a server: binary upload (where the file is included in the POST body) and form/multi-part upload. Which type of upload is appropriate depends on the server you are uploading to. The upload will be done using the binary upload method only if you have set the `post` field of the `UploadTask` to 'binary'.
## Managing and monitoring tasks in the queue

To manage or monitor tasks, use the following methods:
* `reset` to reset the downloader by cancelling all ongoing download tasks
* `allTaskIds` to get a list of `taskId` values of all tasks currently active (i.e. not in a final state). You can exclude tasks waiting for retries by setting `includeTasksWaitingToRetry` to `false`
* `allTasks` to get a list of all tasks currently active (i.e. not in a final state). You can exclude tasks waiting for retries by setting `includeTasksWaitingToRetry` to `false`
* `cancelTasksWithIds` to cancel all tasks with a `taskId` in the provided list of taskIds
* `taskForId` to get the `DownloadTask` for the given `taskId`, or `null` if not found. Only tasks that are active (ie. not in a final state) are guaranteed to be returned, but returning a task does not guarantee that it is active

### Grouping tasks

Because an app may require different types of downloads, and handle those differently, you can specify a `group` with your task, and register callbacks specific to each `group`. If no group is specified the default group named `default` is used. For example, to create and handle downloads for group 'bigFiles':
```
  FileDownloader().registerCallbacks(
        group: 'bigFiles'
        taskStatusCallback: bigFilesDownloadStatusCallback,
        taskProgressCallback: bigFilesDownloadProgressCallback);
  final task = DownloadTask(
        group: 'bigFiles',
        url: 'https://google.com',
        filename: 'google.html',
        updates:
            Updates.statusAndProgress);
  final successFullyEnqueued = await FileDownloader().enqueue(task);
```

The methods `registerCallBacks`, `reset`, `allTaskIds` and `allTasks` all take an optional `group` parameter to target tasks in a specific group. Note that if tasks are enqueued with a `group` other than default, calling any of these methods without a group parameter will not affect/include those tasks - only the default tasks.

If you listen to the `updates` stream instead of using callbacks, you can test for the task's `group` field in your listener, and process the update differently for different groups.

Note: tasks that are started using `download`, `upload`, `batchDownload` or `batchUpload` are assigned a special group name 'await', as callbacks for these tasks are handled within the `FileDownloader`.



## Server requests

To make a regular server request (e.g. to obtain a response from an API end point that you process directly in your app) use the `request` method.  It works similar to the `download` method, except you pass a `Request` object that has fewer fields than the `DownloadTask`, but is similar in structure.  You `await` the response, which will be a [Response](https://pub.dev/documentation/http/latest/http/Response-class.html) object as defined in the dart [http package](https://pub.dev/packages/http), and includes getters for the response body (as a `String` or as `UInt8List`), `statusCode` and `reasonPhrase`.

Because requests are meant to be immediate, they are not enqueued like a `Task` is, and do not allow for status/progress monitoring.

## Optional parameters

The `DownloadTask`, `UploadTask` and `Request` objects all take several optional parameters that define how the task will be executed.  Note that a `Task` is a subclass of `Request`, and both `DownloadTask` and `UploadTask` are subclasses of `Task`, so what applies to a `Request` or `Task` will also apply to a `DownloadTask` and `UploadTask`.

### Request, DownloadTask & UploadTask

#### urlQueryParameters

If provided, these parameters (presented as a `Map<String, String>`) will be appended to the url as query parameters. Note that both the `url` and `urlQueryParameters` must be urlEncoded (e.g. a space must be encoded as %20).

#### Headers

Optionally, `headers` can be added to the `Task`, which will be added to the HTTP request. This may be useful for authentication, for example.

#### POST requests

For downloads, if the required server request is a HTTP POST request (instead of the default GET request) then set the `post` field of a `DownloadTask` to a `String` or `UInt8List` representing the data to be posted (for example, a JSON representation of an object). To make a POST request with no data, set `post` to an empty `String`.

For an `UploadTask` the POST field is used to request a binary upload, by setting it to 'binary'. By default, uploads are done using the form/multi-part format.

#### Retries

To schedule automatic retries of failed requests/tasks (with exponential backoff), set the `retries` field to an
integer between 1 and 10. A normal `Task` (without the need for retries) will follow status
updates from `enqueued` -> `running` -> `complete` (or `notFound`). If `retries` has been set and
the task fails, the sequence will be `enqueued` -> `running` ->
`waitingToRetry` -> `enqueued` -> `running` -> `complete` (if the second try succeeds, or more
retries if needed).  A `Request` will behave similarly, except it does not provide intermediate status updates.

### DownloadTask & UploadTask

#### Requiring WiFi

If the `requiresWiFi` field of a `Task` is set to true, the task won't start unless a WiFi network is available. By default `requiresWiFi` is false, and downloads/uploads will use the cellular (or metered) network if WiFi is not available, which may incur cost.

#### Metadata

`metaData` can be added to a `Task`. It is ignored by the downloader but may be helpful when receiving an update about the task.


## Initial setup

No setup is required for Android, Windows or Linux.

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

* On Android, once started (i.e. `TaskStatus.running`), a task must complete within 8 minutes
* On iOS, once enqueued (i.e. `TaskStatus.enqueued`), a background download must complete within 4 hours
* Redirects will be followed
* Background downloads and uploads are aggressively controlled by the native platform. You should therefore always assume that a task that was started may not complete, and may disappear without providing any status or progress update to indicate why. For example, if a user swipes your app up from the iOS App Switcher, all scheduled background downloads are terminated without notification