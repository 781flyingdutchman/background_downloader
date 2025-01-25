# A background file downloader and uploader for iOS, Android, MacOS, Windows and Linux

Create a [DownloadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/DownloadTask-class.html) to define where to get your file from, where to store it, and how you want to monitor the download, then call `FileDownloader().download` and wait for the result.  Background_downloader uses URLSessions on iOS and DownloadWorker on Android, so tasks will complete also when your app is in the background. The download behavior is highly consistent across all supported platforms: iOS, Android, MacOS, Windows and Linux.

Monitor progress by passing an `onProgress` listener, and monitor detailed status updates by passing an `onStatus` listener to the `download` call.  Alternatively, monitor tasks centrally using an [event listener](#using-an-event-listener) or [callbacks](#using-callbacks) and call `enqueue` to start the task.

Optionally, keep track of task status and progress in a persistent [database](#using-the-database-to-track-tasks), and show mobile [notifications](#notifications) to keep the user informed and in control when your app is in the background.

To upload a file, create an [UploadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/UploadTask-class.html) and call `upload`. To make a regular [server request](#server-requests), create a [Request](https://pub.dev/documentation/background_downloader/latest/background_downloader/Request-class.html) and call `request`, or a enqueue a [DataTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/DataTask-class.html). To download in parallel from multiple servers, create a [ParallelDownloadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/ParallelDownloadTask-class.html).

The plugin supports [headers](#headers), [retries](#retries), [priority](#priority), [requiring WiFi](#requiring-wifi) before starting the up/download, user-defined [metadata and display name](#metadata-and-displayname) and GET, [POST](#post-requests) and other http(s) [requests](#http-request-method), and can be [configured](#configuration) by platform. You can [manage  the tasks in the queue](#managing-tasks-and-the-queue) (e.g. cancel, pause and resume), and have different handlers for updates by [group](#grouping-tasks) of tasks. Downloaded files can be moved to [shared storage](#shared-and-scoped-storage) to make them available outside the app.

No setup is required for [Android](#android) (except when using notifications), Windows and Linux, and only minimal [setup for iOS](#ios) and [MacOS](#macos).

## Usage examples

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

### Uploads example

```dart
/// define the multi-part upload task (subset of parameters shown)
final task = UploadTask(
        url: 'https://myserver.com/uploads',
        filename: 'myData.txt',
        fields: {'datafield': 'value'},
        fileField: 'myFile', 
        updates: Updates.statusAndProgress // request status and progress updates
);

// Start upload, and wait for result. Show progress and status changes
// while uploading
final result = await FileDownloader().upload(task,
  onProgress: (progress) => print('Progress: ${progress * 100}%'),
  onStatus: (status) => print('Status: $status')
);

// Act on result, similar to download
```

### Batch download example
```dart
final tasks = [task1, task2, task3]; // a list of Download tasks

// download the batch
final result = await FileDownloader().downloadBatch(tasks,
  batchProgressCallback: (succeeded, failed) =>
    print('Completed ${succeeded + failed} out of ${tasks.length}, $failed failed')
);
```

### Task tracking database example
```dart
// activate tracking at the start of your app
await FileDownloader().trackTasks();

// somewhere else: enqueue a download (does not complete immediately)
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt');
final successfullyEnqueued = await FileDownloader().enqueue(task);

// query the tracking database, returning a record for each task
final records = await FileDownloader().database.allRecords();
for (record in records) {
  print('Task ${record.tasksId} status is ${record.status}');
  if (record.status == TaskStatus.running) {
    print('-- progress ${record.progress * 100}%');
    print('-- file size ${record.expectedFileSize} bytes');
  }
};

// or get record for specific task
final record = await FileDownloader().database.recordForId(task.taskId);
```

### Notifications example
```dart
// configure notification for all tasks
FileDownloader().configureNotification(
  running: TaskNotification('Downloading', 'file: {filename}'),
  complete: TaskNotification('Download finished', 'file: {filename}'),
  progressBar: true
);

// all downloads will now show a notification while downloading, and when complete. 
// {filename} will be replaced with the task's filename.
```

---

# Contents

- [Basic use](#basic-use)
  - [Tasks and the FileDownloader](#tasks-and-the-filedownloader)
  - [Monitoring the task](#monitoring-the-task)
  - [Specifying the location of the file to download or upload](#specifying-the-location-of-the-file-to-download-or-upload)
  - [A batch of files](#a-batch-of-files)
- [Central monitoring and tracking in a persistent database](#central-monitoring-and-tracking-in-a-persistent-database)
  - [Using an event listener](#using-an-event-listener)
  - [Using callbacks](#using-callbacks)
  - [Using the database to track Tasks](#using-the-database-to-track-tasks)
- [Notifications](#notifications)
- [Shared and scoped storage](#shared-and-scoped-storage)
- [Permissions](#permissions)
- [Uploads](#uploads)
- [Parallel downloads](#parallel-downloads)
- [Managing tasks in the queue](#managing-tasks-and-the-queue)
  - [Canceling, pausing and resuming tasks](#canceling-pausing-and-resuming-tasks)
  - [Grouping tasks](#grouping-tasks)
  - [Task queues and holding queues](#task-queues-and-holding-queues)
  - [Changing WiFi requirements](#changing-wifi-requirements)
- [Authentication and pre- and post-execution callbacks](#authentication-and-pre--and-post-execution-callbacks)
- [Server requests](#server-requests)
- [Cookies](#cookies)
- [Optional parameters](#optional-parameters)
- [Initial setup](#initial-setup)
- [Configuration](#configuration)
- [Limitations](#limitations)

## Basic use

### Tasks and the FileDownloader

A `DownloadTask` or `UploadTask` (both subclasses of `Task`) defines one download or upload. It contains the `url`, the file name and location, what updates you want to receive while the task is in progress, [etc](#optional-parameters).  The [FileDownloader](https://pub.dev/documentation/background_downloader/latest/background_downloader/FileDownloader-class.html) class is the entrypoint for all calls. To download a file:
```dart
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt'); // define your task
final result = await FileDownloader().download(task);  // do the download and wait for result
```

The `result` will be a [TaskStatusUpdate](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskStatusUpdate-class.html), which has a field `status` that indicates how the download ended: `.complete`, `.failed`, `.canceled` or `.notFound`.
It may also contain the `responseHeaders` (with lowercase header names), the `responseStatusCode`, and the `mimeType` and `charSet` if the server provided that information via the Content-Type header.
If the `status` is `.failed`, the `result.exception` field will contain a `TaskException` with information about what went wrong. For uploads and some unsuccessful downloads, the `responseBody` will contain the server response.

### Monitoring the task

#### Progress

If you want to monitor progress during the download itself (e.g. for a large file), then add a progress callback that takes a double as its argument:
```dart
final result = await FileDownloader().download(task, 
    onProgress: (progress) => print('Progress update: $progress'));
```
Progress updates start with 0.0 when the actual download starts (which may be in the future, e.g. if waiting for a WiFi connection), and will be sent periodically, not more than twice per second per task, and not less than once every 2.5 seconds.  If a task completes successfully you will receive a final progress update with a `progress` value of 1.0 (`progressComplete`). Failed tasks generate `progress` of `progressFailed` (-1.0), canceled tasks `progressCanceled` (-2.0), notFound tasks `progressNotFound` (-3.0), waitingToRetry tasks `progressWaitingToRetry` (-4.0) and paused tasks `progressPaused` (-5.0).

Use `await task.expectedFileSize()` to query the server for the size of the file you are about
to download.  The expected file size is also included in `TaskProgressUpdate`s that are sent to
listeners and callbacks - see [Using an event listener](#using-an-event-listener) and [Using callbacks](#using-callbacks)

A [DownloadProgressIndicator](https://pub.dev/documentation/background_downloader/latest/background_downloader/DownloadProgressIndicator-class.html) widget is included with the package, and the example app shows how to wire it up.
The widget can be configured to include pause and resume buttons, and to expand to show multiple
simultaneous downloads, or to collapse and show a file download counter.

To provide progress updates (as a percentage of total file size) the downloader needs to know the size of the file when starting the download. Most servers provide this in the "Content-Length" header of their response. If the server does not provide the file size, yet you know the file size (e.g. because you have stored the file on the server yourself), then you can let the downloader know by providing a `{'Range': 'bytes=0-999'}` or a `{'Known-Content-Length': '1000'}` header to the task's `header` field. Both examples are for a content length of 1000 bytes.  The downloader will assume this content length when calculating progress.  

#### Status

If you want to monitor status changes while the download is underway (i.e. not only the final state, which you will receive as the result of the `download` call) you can add a status change callback that takes the status as an argument:
```dart
final result = await FileDownloader().download(task,
    onStatus: (status) => print('Status update: $status'));
```

The status will follow a sequence of `.enqueued` (waiting to execute), `.running` (actively 
downloading) and then one of the final states mentioned before, or `.waitingToRetry` if retries 
are enabled and the task failed.

If a task fails with `TaskStatus.failed` then in some cases it is possible to `resume` the task without having to start from scratch. You can test whether this is possible by calling `FileDownloader().taskCanResume(task)` and if true, call `resume` instead of `download` or `enqueue`.

#### Elapsed time

If you want to keep an eye on how long the download is taking (e.g. to warn the user that there may be an issue with their network connection, or to cancel the task if it takes too long), pass an `onElapsedTime` callback to the `download` method. The callback takes a single argument of type `Duration`, representing the time elapsed since the call to `download` was made. It is called at regular intervals (defined by `elapsedTimeInterval` which defaults to 5 seconds), so you can react in different ways depending on the total time elapsed. For example:
```dart
final result = await FileDownloader().download(
                      task, 
                      onElapsedTime: (elapsed) {
                          print('This is taking rather long: $elapsed');
                      },
                      elapsedTimeInterval: const Duration(seconds: 30));
```

The elapsed time logic is only available for `download`, `upload`, `downloadBatch` and `uploadBatch`. It is not available for tasks started using `enqueue`, as there is no expectation that those complete imminently.


### Specifying the location of the file to download or upload

In the `DownloadTask` and `UploadTask` objects, the `filename` of the task refers to the filename without directory. To store the task in a specific directory, add the `directory` parameter to the task. That directory is relative to the base directory. By default, the base directory is the directory returned by the call to `getApplicationDocumentsDirectory()` of the [path_provider](https://pub.dev/packages/path_provider) package, but this can be changed by also passing a `baseDirectory` parameter (`BaseDirectory.temporary` for the directory returned by `getTemporaryDirectory()`, `BaseDirectory.applicationSupport` for the directory returned by `getApplicationSupportDirectory()` and `BaseDirectory.applicationLibrary` for the directory returned by `getLibraryDirectory()` on iOS and MacOS, or subdir 'Library' of the directory returned by `getApplicationSupportDirectory()` on other platforms).

So, to store a file named 'testfile.txt' in the documents directory, subdirectory 'my/subdir', define the task as follows:
```dart
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt',
        directory: 'my/subdir');
```

To store that file in the temporary directory:
```dart
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt',
        directory: 'my/subdir',
        baseDirectory: BaseDirectory.temporary);
```

If you already have a path to a file or a `File` object, you can extract the values for `baseDirectory`, `directory` and `filename` to create the task by using `Task.split`:
```dart
final (baseDirectory, directory, filename) = await Task.split(filePath: yourPath);
final task = UploadTask(
        url: 'https://google.com',
        baseDirectory: baseDirectory,
        directory: directory,
        filename: filename);
```

The downloader will only store the file upon success (so there will be no partial files saved), and if so, the destination is overwritten if it already exists, and all intermediate directories will be created if needed.

You can also pass an absolute path to the downloader by using `BaseDirectory.root` combined with the path in `directory`. This allows you to reach any file destination on your platform. However, be careful: the reason you should not normally do this (and use e.g. `BaseDirectory.applicationDocuments` instead) is that the location of the app's documents directory may change between application starts (on iOS, and on Android in some cases), and may therefore fail for downloads that complete while the app is suspended.  You should therefore never store permanently, or hard-code, an absolute path, unless you are absolutely sure that that path is 'stable'.

Android has two storage modes: internal (default) and external storage. Read the [configuration document](https://github.com/781flyingdutchman/background_downloader/blob/main/CONFIG.md) for details on how to configure your app to use external storage instead of the default.

#### Server-suggested filename

If you want the filename to be provided by the server (instead of assigning a value to `filename` yourself), you have two options. The first is to create a `DownloadTask` that pings the server to determine the suggested filename:
```dart
final task = await DownloadTask(url: 'https://google.com')
        .withSuggestedFilename(unique: true);
```
The method `withSuggestedFilename` returns a copy of the task it is called on, with the `filename` field modified based on the filename suggested by the server, or the last path segment of the URL, or unchanged if neither is feasible (e.g. due to a lack of connection). If `unique` is true, the filename will be modified such that it does not conflict with an existing filename by adding a sequence. For example "file.txt" would become "file (1).txt". You can also supply a `taskWithFilenameBuilder` to suggest the filename yourself, based on response headers.

The second approach is to set the `filename` field of the `DownloadTask` to `DownloadTask.suggestedFilename`, to indicate that you would like the server to suggest the name. In this case, you will receive the name via the task's status and/or progress updates, so you have to be careful _not_ to use the original task's filename, as that will still be `DownloadTask.suggestedFilename`. For example:
```dart
final task = await DownloadTask(url: 'https://google.com', filename: DownloadTask.suggestedFilename);
final result = await FileDownloader().download(task);
print('Suggested filename=${result.task.filename}'); // note we don't use 'task', but 'result.task'
print('Wrong use filename=${task.filename}'); // this will print '?' as 'task' hasn't changed
```

#### Android file URIs

From Android 11 on, you can upload a file using a Storage Access Framework URI instead of the file name. To create such an `UploadTask`, use `UploadTask.fromAndroidUri` and supply the 'content://' URI. To make this easier, methods `moveToSharedStorage` and `pathInSharedStorage` can now return a URI if `asAndroidUri` is set to true. Note that if for whatever reason the URI cannot be obtained, the regular file path will be returned, so you need to confirm the returned value starts with 'content://' before using it as a URI.

### A batch of files

To download a batch of files and wait for completion of all, create a `List` of `DownloadTask` objects and call `downloadBatch`:
```dart
final result = await FileDownloader().downloadBatch(tasks);
```

The result is a `Batch` object that contains the result for each task in `.results`. You can use `.numSucceeded` and `.numFailed` to check if all files in the batch downloaded successfully, and use `.succeeded` or `.failed` to iterate over successful or failed tasks within the batch.  If you want to get progress updates for the batch (in terms of how many files have been downloaded) then add a callback:
```dart
final result = await FileDownloader().downloadBatch(tasks, batchProgressCallback: (succeeded, failed) {
  print('$succeeded files succeeded, $failed have failed');
  print('Progress is ${(succeeded + failed) / tasks.length} %');
});
```
The callback will be called upon completion of each task (whether successful or not), and will start with (0, 0) before any downloads start, so you can use that to start a progress indicator.

To also monitor status and progress for each file in the batch, add a [TaskStatusCallback](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskStatusCallback.html)  and/or a [TaskProgressCallback](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskProgressCallback.html)

To monitor based on elapsed time, see [Elapsed time](#elapsed-time).

For uploads, create a `List` of `UploadTask` objects and call `uploadBatch` - everything else is the same.

## Central monitoring and tracking in a persistent database

Instead of monitoring in the `download` call, you may want to use a centralized task monitoring approach, and/or keep track of tasks in a database. This is helpful for instance if:
1. You start download in multiple locations in your app, but want to monitor those in one place, instead of defining `onStatus` and `onProgress` for every call to `download`
2. You have different groups of tasks, and each group needs a different monitor
3. You want to keep track of the status and progress of tasks in a persistent database that you query
4. Your downloads take long, and your user may switch away from your app for a long time, which causes your app to get suspended by the operating system. A download started with a call to `download` will continue in the background and will finish eventually, but when your app restarts from a suspended state, the result `Future` that you were awaiting when you called `download` may no longer be 'alive', and you will therefore miss the completion of the downloads that happened while suspended. This situation is uncommon, as the app will typically remain alive for several minutes even when moving to the background, but if you find this to be a problem for your use case, then you should process status and progress updates for long running background tasks centrally.

Central monitoring can be done by listening to an updates stream, or by registering callbacks. In both cases you now use `enqueue` instead of `download` or `upload`. `enqueue` returns almost immediately with a `bool` to indicate if the `Task` was successfully enqueued. Monitor status changes and act when a `Task` completes via the listener or callback.

To ensure your callbacks or listener capture events that may have happened when your app was suspended in the background, call `resumeFromBackground` right after registering your callbacks or listener.

In summary, to track your tasks persistently, follow these steps in order, immediately after app startup:
1. If using a non-default `PersistentStorage` backend, initialize with `FileDownloader(persistentStorage: MyPersistentStorage())` and wait for the initialization to complete by calling `await FileDownloader().ready` (see [using the database](#using-the-database-to-track-tasks) for details on `PersistentStorage`).
2. Register an event listener or callback(s) to process status and progress updates
3. Call `await FileDownloader().start()` to execute the following calls in the correct order (or call these manually):
   a. Call `await FileDownloader().trackTasks()` if you want to track the tasks in a persistent database
   b. Call `await FileDownloader().resumeFromBackground()` to ensure events that happened while your app was in the background are processed
   c. If you are tracking tasks in the database, after ~5 seconds, call `await FileDownloader().rescheduleKilledTasks()` to reschedule tasks that are in the database as `enqueued` or `running` yet are not enqueued or running on the native side, or that are `waitingToRetry` but not registered as such. These tasks have been "lost", most likely because the user killed your app (which kills tasks on the native side without warning)

The rest of this section details [event listeners](#using-an-event-listener), [callbacks](#using-callbacks) and the [database](#using-the-database-to-track-tasks) in detail.

### Using an event listener

Listen to updates from the downloader by listening to the `updates` stream, and process those updates centrally. For example, the following creates a listener to monitor status and progress updates for downloads, and then enqueues a task as an example:
```dart
    final subscription = FileDownloader().updates.listen((update) {
      switch(update) {
        case TaskStatusUpdate():
          print('Status update for ${update.task} with status ${update.status}');
        case TaskProgressUpdate():
          print('Progress update for ${update.task} with progress ${update.progress}');
      }
    });
    
    // define the task
    final task = DownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
        updates: Updates.statusAndProgress); // needed to also get progress updates
        
    // enqueue the download
    final successFullyEnqueued = await FileDownloader().enqueue(task);
    // updates will be sent to your subscription listener
```

A TaskProgressUpdate includes `expectedFileSize`, `networkSpeed` and `timeRemaining`. Check the associated `hasExpectedFileSize`, `hasNetworkSpeed` and `hasTimeRemaining` before using the values in these fields.  Use `networkSpeedAsString` and `timeRemainingAsString` for human readable versions of these values.

Note that `successFullyEnqueued` only refers to the enqueueing of the download task, not its result, which must be monitored via the listener. Also note that in order to get progress updates the task must set its `updates` field to a value that includes progress updates. In the example, we are asking for both status and progress updates, but other combinations are possible. For example, if you set `updates` to `Updates.status` then the task will only generate status updates and no progress updates. You define what updates to receive on a task by task basis via the `Task.updates` field, which defaults to status updates only.

Best practice is to start your subscription in a singleton object that you initialize upon app startup, so that you only ever listen to the stream once, and use that singleton object to maintain state for your downloads. Note the stream can only be listened to once, though you can reset the stream controller by calling `await FileDownloader().resetUpdates()` to start listening again.

### Using callbacks

Instead of listening to the `updates` stream you can register a callback for status updates, and/or a callback for progress updates.  This may be the easiest way if you want different callbacks for different [groups](#grouping-tasks).

The [TaskStatusCallback](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskStatusCallback.html) receives a [TaskStatusUpdate](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskStatusUpdate-class.html), so a simple callback function is:
```dart
void taskStatusCallback(TaskStatusUpdate update) {
  print('taskStatusCallback for ${update.task) with status ${update.status} and exception ${update.exception}');
}
```

The [TaskProgressCallback](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskProgressCallback.html) receives a [TaskProgressUpdate](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskProgressUpdate-class.html), so a simple callback function is:
```dart
void taskProgressCallback(TaskProgressUpdate update) {
  print('taskProgressCallback for ${update.task} with progress ${update.progress} '
        'and expected file size ${update.expectedFileSize}');
}
```

A basic file download with just status monitoring (no progress) then requires registering the central callback, and a call to `enqueue` to start the download:
```dart
FileDownloader().registerCallbacks(taskStatusCallback: taskStatusCallback);
final successFullyEnqueued = await FileDownloader().enqueue(
    DownloadTask(url: 'https://google.com', filename: 'google.html'));
```

You define what updates to receive on a task by task basis via the `Task.updates` field, which defaults to status updates only.  If you register a callback for a type of task, updates are provided only through that callback and will not be posted on the `updates` stream.

Note that all tasks will call the same callback, unless you register separate callbacks for different [groups](#grouping-tasks) and set your `Task.group` field accordingly.

You can unregister callbacks using `FileDownloader().unregisterCallbacks()`.

### Using the database to track Tasks

To keep track of the status and progress of all tasks, even after they have completed, activate tracking by calling `trackTasks()` (or calling `FileDownloader().start()` with `doTrackTasks` set to true - the default) and use the `database` field to query and retrieve the [TaskRecord](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskRecord-class.html) entries stored. For example:
```dart
// at app startup, after registering listener or callback, start tracking
await FileDownloader().trackTasks();

// somewhere else: enqueue a download
final task = DownloadTask(
        url: 'https://google.com',
        filename: 'testfile.txt');
final successfullyEnqueued = await FileDownloader().enqueue(task);

// somewhere else: query the task status by getting a `TaskRecord`
// from the database
final record = await FileDownloader().database.recordForId(task.taskId);
print('TaskId ${record.taskId} with task ${record.task} has '
    'status ${record.status} and progress ${record.progress} '
    'with an expected file size of ${record.expectedFileSize} bytes'
```

You can interact with the `database` using `allRecords`, `allRecordsOlderThan`, `recordForId`,`deleteAllRecords`,
`deleteRecordWithId` etc. If you only want to track tasks in a specific [group](#grouping-tasks), call `trackTasksInGroup` instead.

If a user kills your app (e.g. by swiping it away in the app tray) then tasks that are running (natively) are killed, and no indication is given to your application. This cannot be avoided. To guard for this, upon app startup you can ask the downloader to reschedule killed tasks, i.e. tasks that show up as `enqueued` or `running` in the database, yet are not enqueued or running on the native side, or are `waitingToRetry` but not registered as such. Method `rescheduleKilledTasks` returns a record with two lists, 1) successfully rescheduled tasks and 2) tasks that failed to reschedule. Together, those are the missing tasks. Reschedule missing tasks a few seconds after you have called `resumeFromBackground`, as that gives the downloader time to processes updates that may have happened while the app was suspended, or call `FileDownloader().start()` with `doRescheduleKilledTasks` set to true (the default).

By default, the downloader uses a modified version of the [localstore](https://pub.dev/packages/localstore) package to store the `TaskRecord` and other objects. To use a different persistent storage solution, create a class that implements the [PersistentStorage](https://pub.dev/documentation/background_downloader/latest/background_downloader/PersistentStorage-class.html) interface, and initialize the downloader by calling `FileDownloader(persistentStorage: MyPersistentStorage())` as the first use of the `FileDownloader`.

As an alternative to LocalStore, use `SqlitePersistentStorage`, included in [background_downloader_sql](https://pub.dev/packages/background_downloader_sql), which supports SQLite storage and migration from Flutter Downloader.

## Notifications
Pub
On iOS and Android, for downloads and uploads, the downloader can generate notifications to keep the user informed of progress also when the app is in the background, and allow pause/resume and cancellation of an ongoing download from those notifications.

Configure notifications by calling `FileDownloader().configureNotification` and supply a
`TaskNotification` object for different states. For example, the following configures
notifications to show only when actively running (i.e. download in progress), disappearing when
the download completes or ends with an error. It will also show a progress bar and a 'cancel'
button, and will substitute {filename} with the actual filename of the file being downloaded.
```dart
FileDownloader().configureNotification(
    running: TaskNotification('Downloading', 'file: {filename}'),
    progressBar: true);
```

To also show a notifications for other states, add a `TaskNotification` for `complete`, `error`
and/or `paused`. If `paused` is configured and the task can be paused, a 'Pause' button will
show for the `running` notification, next to the 'Cancel' button. To open the downloaded file
when the user taps the `complete` notification, add `tapOpensFile: true` to your call to
`configureNotification`

There are four possible substitutions of the text in the `title` or `body` of a `TaskNotification`:
* {filename} is replaced with the `filename` field of the `Task`
* {displayName} is replaced with the `displayName` field of the `Task`
* {progress} is substituted by a progress percentage, or '--%' if progress is unknown
* {metadata} is substituted by the `metaData` field of the `Task`

Notifications on iOS follow Apple's [guidelines](https://developer.apple.com/design/human-interface-guidelines/components/system-experiences/notifications/), notably:
* No progress bar is shown, and the {progress} substitution always substitutes to an empty string. In other words: only a single `running` notification is shown and it is not updated until the download/upload state changes
* When the app is in the foreground, on iOS 14 and above the notification will not be shown but will appear in the NotificationCenter. On older iOS versions the notification will be shown also in the foreground. Apple suggests showing progress and download/upload controls within the app when it is in the foreground

No notifications will be generated:
* On desktop platforms, as there is no true background mode, and progress updates and indicators can be shown within the app
* For a `DataTask`, as those are meant for short data exchanges

The `configureNotification` call configures notification behavior for all tasks. You can specify a separate configuration for a `group` of tasks by calling `configureNotificationForGroup` and for a single task by calling `configureNotificationForTask`. A `Task` configuration overrides a `group` configuration, which overrides the default configuration.

Make sure to check for, and if necessary request, permission to display notifications - see [permissions](#permissions). For Android, starting with API 33, you need to add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` to your app's `AndroidManifest.xml`. Also on Android you can localize the button text by overriding string resources `bg_downloader_cancel`, `bg_downloader_pause`, `bg_downloader_resume` and descriptions `bg_downloader_notification_channel_name`, `bg_downloader_notification_channel_description`. Localization on iOS can be done through [configuration](#configuration).

### Grouping notifications

If you download or upload multiple files simultaneously, you may not want a notification for every task, but one notification representing the group of tasks.  To do this, set the `groupNotificationId` field in a `notificationConfig` and use that configuration for all tasks in this group. It is easiest to combine this with the `group` field of the task, e.g.:
```dart
FileDownloader().configureNotificationForGroup('bunchOfFiles', // refers to the Task.group field
            running: const TaskNotification(
                '{numFinished} out of {numTotal}', 'Progress = {progress}'),
            complete:
                const TaskNotification('Done!', 'Loaded {numTotal} files'),
            error: const TaskNotification(
                'Error', '{numFailed}/{numTotal} failed'),
            progressBar: true,
            groupNotificationId: 'myGroupNotification'); // unique ID for notification group
            
// start every task like this
await FileDownloader().enqueue(DownloadTask(
            url: 'https://your_url.com',
            filename: 'your_filename',
            group: 'bunchOfFiles'));
```

All tasks in group `bunchOfFiles` will now use the notification group configuration with ID `myNotificationGroup`. Any other task that uses a configuration with `groupNotificationId` set to 'myGroupNotification' will also be added to that group notification. Notification tap detection is not implemented for notification groups.

__On iOS__: If your `running` group notification contains a dynamic item (such as `{numFinished}` in the example above) then a new notification will be issued every time the notification message changes (different from Android, where the existing notification is updated so does not trigger a new one).

### Tapping a notification
To respond to the user tapping a notification, register a callback that takes `Task` and `NotificationType` as parameters:

```dart
FileDownloader().registerCallbacks(
  taskNotificationTapCallback: myNotificationTapCallback);

void myNotificationTapCallback(Task task, NotificationType notificationType) {
  print('Tapped notification $notificationType for taskId ${task.taskId}');
}
```

### Opening a downloaded file

To open a file (e.g. in response to the user tapping a notification), call `FileDownloader().openFile` and supply either a `Task` or a full `filePath` (but not both) and optionally a `mimeType` to assist the Platform in choosing the right application to use to open the file.
The file opening behavior is platform dependent, and while you should check the return value of the call to `openFile`, error checking is not fully consistent.

Note that on Android, files stored in the `BaseDirectory.applicationDocuments` cannot be opened. You need to download to a different base directory (e.g. `.applicationSupport`) or move the file to shared storage before attempting to open it.

If all you want to do on notification tap is to open the file, you can simplify the process by
adding `tapOpensFile: true` to your call to `configureNotifications`, and you don't need to
register a `taskNotificationTapCallback`.


### Setup for notifications

__On iOS__: Add the following to your `AppDelegate.swift`:
```swift
UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
```
or if using Objective C, add to `AppDelegate.m`:
```objective-c
[UNUserNotificationCenter currentNotificationCenter].delegate = (id<UNUserNotificationCenterDelegate>) self;
```

__On Android__: Starting with API 33, you need to add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` to your app's `AndroidManifest.xml`

If needed, localize the button text by overriding string resources `bg_downloader_cancel`, `bg_downloader_pause`, `bg_downloader_resume` and descriptions `bg_downloader_notification_channel_name`, `bg_downloader_notification_channel_description`. Optionally, supply your own notification icons by creating a version of the icons defined in `android/src/main/res/drawable`, e.g. `outline_download_done_24.xml`, and add those to your own app's `android/src/main/res/drawable` under the same name.

## Shared and scoped storage

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

__On iOS:__ For `.images` and `.video` SharedStorage destinations, you need user [permission](#permissions) to add to the Photos Library, which requires you to set the `NSPhotoLibraryAddUsageDescription` key in `Info.plist`. The returned String is _not_ a `filePath`, but a unique identifier. If you only want to add the file to the Photos Library you can ignore this identifier. If you want to actually get access to the file (and `filePath`) in the Photos Library, then the user needs to grant an additional 'modify' permission, which requires you to set the `NSPhotoLibraryUsageDescription` in `Info.plist`. To get the actual `filePath`, call `pathInSharedStorage` and pass the identifier obtained via the call to `moveToSharedStorage` as the `filePath` parameter:
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

### Path to file in shared storage

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

## Permissions

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

## Uploads

Uploads are very similar to downloads, except:
* define an `UploadTask` object instead of a `DownloadTask`
* the file location now refers to the file you want to upload
* call `upload` instead of `download`, or `uploadBatch` instead of `downloadBatch`

There are two ways to upload a file to a server: binary upload (where the file is included in the POST body) and form/multi-part upload. Which type of upload is appropriate depends on the server you are uploading to. The upload will be done using the binary upload method only if you have set the `post` field of the `UploadTask` to 'binary'.

If you already have a `File` object, you can create your `UploadTask` using `UploadTask.fromFile`, though note that this will create a task with an absolute path reference and `BaseDirectory.root`, which can cause problems on mobile platforms (see [here](#specifying-the-location-of-the-file-to-download-or-upload)). Preferably, use `Task.split` to break your `File` or filePath into appropriate baseDirectory, directory and filename and use that to create your `UploadTask`.
On Android, you can use Storage Access Framework URIs for binary uploads by creating the task using `UploadTask.fromAndroidUri`.

For multi-part uploads you can specify name/value pairs in the `fields` property of the `UploadTask` as a `Map<String, String>`. These will be uploaded as form fields along with the file. To specify multiple values for a single name, format the value as `'"value1", "value2", "value3"'` (note the double quotes and the comma to separate the values).

You can also set the field name used for the file itself by setting `fileField` (default is "file") and override the mimeType by setting `mimeType` (default is derived from filename extension).

If you need to upload multiple files in a single request, create a [MultiUploadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/MultiUploadTask-class.html) instead of an `UploadTask`. It has similar parameters as the `UploadTask`, except you specify a list of files to upload as the `files` argument of the constructor, and do not use `fileName`, `fileField` and `mimeType`. Each element in the `files` list is either:
* a filename (e.g. `"file1.txt"`). The `fileField` for that file will be set to the base name (i.e. "file1" for "file1.txt") and the mime type will be derived from the extension (i.e. "text/plain" for "file1.txt")
* a record containing `(fileField, filename)`, e.g. `("document", "file1.txt")`. The `fileField` for that file will be set to "document" and the mime type derived from the file extension (i.e. "text/plain" for "file1.txt")
* a record containing `(filefield, filename, mimeType)`, e.g. `("document", "file1.txt", "text/plain")`

The `baseDirectory` and `directory` fields of the `MultiUploadTask` determine the expected location of the file referenced, unless the filename used in any of the 3 formats above is an absolute path (e.g. "/data/user/0/com.my_app/file1.txt"). In that case, the absolute path is used and the `baseDirectory` and `directory` fields are ignored for that element of the list.
Once the `MultiUpoadTask` is created, the fields `fileFields`, `filenames` and `mimeTypes` will contain the parsed items, and the fields `fileField`, `filename` and `mimeType` contain those lists encoded as a JSON string.

Use the `MultiTaskUpload` object in the `upload` and `enqueue` methods as you would a regular `UploadTask`.

For partial uploads, set the byte range by adding a "Range" header to your binary `UploadTask`, e.g. a value of "bytes=100-149" will upload 50 bytes starting at byte 100. You can omit the range end (but not the "-") to upload from the indicated start byte to the end of the file.  The "Range" header will not be passed on to the server. Note that on iOS an invalid range will cause enqueue to fail, whereas on Android and Desktop the task will fail when attempting to start.

## Parallel downloads

Some servers may offer an option to download part of the same file from multiple URLs or have multiple parallel downloads of part of a large file using a single URL. This can speed up the download of large files.  To do this, create a `ParallelDownloadTask` instead of a regular `DownloadTask` and specify `chunks` (the number of pieces you want to break the file into, i.e. the number of downloads that will happen in parallel) and `urls` (as a list of URLs, or just one). For example, if you specify 4 chunks and 2 URLs, then the download will be broken into 8 pieces, four each for each URL.

Note that the implementation of this feature creates a regular `DownloadTask` for each chunk, with the group name 'chunk' which is now a reserved group. You will not get updates for this group, but you will get normal updates (status and/or progress) for the `ParallelDownloadTask`.

## Managing tasks and the queue

### Canceling, pausing and resuming tasks

To enable pausing, set the `allowPause` field of the `Task` to `true`. This may also cause the task to `pause` un-commanded. For example, the OS may choose to pause the task if someone walks out of WiFi coverage.

To cancel, pause or resume a task, call:
* `cancelTaskWithId` to cancel the tasks with that taskId
* `cancelTasksWithIds` to cancel all tasks with a `taskId` in the provided list of taskIds
* `pause` to attempt to pause a task. Pausing is only possible for download GET requests, only if the `Task.allowPause` field is true, and only if the server supports pause/resume. Soon after the task is running (`TaskStatus.running`) you can call `taskCanResume` which will return a Future that resolves to `true` if the server appears capable of pause & resume. If it is not, then `pause` will have no effect and return false
* `resume` to resume a previously paused task (or certain failed tasks), which returns true if resume appears feasible. The task status will follow the same sequence as a newly enqueued task. If resuming turns out to be not feasible (e.g. the operating system deleted the temp file with the partial download) then the task will either restart as a normal download, or fail.


To manage or query the queue of waiting or running tasks, call:
* `reset` to reset the downloader, which cancels all ongoing download tasks (may not yield proper status updates)
* `allTaskIds` to get a list of `taskId` values of all tasks currently active (i.e. not in a final state). You can exclude tasks waiting for retries by setting `includeTasksWaitingToRetry` to `false`. Note that paused tasks are not included in this list
* `allTasks` to get a list of all tasks currently active (i.e. not in a final state). You can exclude tasks waiting for retries by setting `includeTasksWaitingToRetry` to `false`. Note that paused tasks are not included in this list
* `taskForId` to get the `Task` for the given `taskId`, or `null` if not found.
* `tasksFinished` to check if all tasks have finished (successfully or otherwise)

Each of these methods accept a `group` parameter that targets the method to a specific group. If tasks are enqueued with a `group` other than default, calling any of these methods without a group parameter will not affect/include those tasks - only the default tasks.
Methods `allTasks` and `allTaskId` return all tasks regardless of group if argument `allGroups` is set to `true`.

**NOTE:** Only tasks that are active (ie. not in a final state) are guaranteed to be returned or counted, but returning a task does not guarantee that it is active.
This means that if you check `tasksFinished` when processing a task update, the task you received an update for may still show as 'active', even though it just finished, and result in `false` being returned. To fix this, pass that task's taskId as `ignoreTaskId` to the `tasksFinished` call, and it will be ignored for the purpose of testing if all tasks are finished: 
```dart
void downloadStatusCallback(TaskStatusUpdate update) async {
    // process your status update, then check if all tasks are finished
    final bool allTasksFinished = update.status.isFinalState && 
        await FileDownloader().tasksFinished(ignoreTaskId: update.task.taskId) ;
    print('All tasks finished: $allTasksFinished');
  }
```

### Grouping tasks

Because an app may require different types of downloads, and handle those differently, you can specify a `group` with your task, and register callbacks specific to each `group`. If no group is specified the default group `FileDownloader.defaultGroup` is used. For example, to create and handle downloads for group 'bigFiles':
```dart
FileDownloader().registerCallbacks(
    group: 'bigFiles'
    taskStatusCallback: bigFilesDownloadStatusCallback,
    taskProgressCallback: bigFilesDownloadProgressCallback);
final task = DownloadTask(
    group: 'bigFiles',
    url: 'https://google.com',
    filename: 'google.html',
    updates: Updates.statusAndProgress);
final successFullyEnqueued = await FileDownloader().enqueue(task);
```

The methods `registerCallBacks`, `unregisterCallBacks`, `reset`, `allTaskIds`, `allTasks` and `tasksFinished` all take an optional `group` parameter to target tasks in a specific group. Note that if tasks are enqueued with a `group` other than default, calling any of these methods without a group parameter will not affect/include those tasks - only the default tasks.

If you listen to the `updates` stream instead of using callbacks, you can test for the task's `group` field in your listener, and process the update differently for different groups.

### Task queues and Holding queues
Once you `enqueue` a task with the `FileDownloader` it is added to an internal queue that is managed by the native platform you're running on (e.g. Android). Once enqueued, you have limited control over the execution order, the number of tasks running in parallel, etc, because all that is managed by the platform.  If you want more control over the queue, you need to use a `TaskQueue` or a `HoldingQueue`:
* A `TaskQueue` is a Dart object that you can add to the `FileDownloader`. You can create this object yourself (implementing the `TaskQueue` interface) or use the bundled `MemoryTaskQueue` implementation. This queue sits "in front of" the `FileDownloader` and instead of using the `enqueue` and `download` methods directly, you now simply `add` your tasks to the `TaskQueue`. Because this is a Dart object, the queue will suspend when the OS suspends your application, and if the app gets killed, tasks held in the `TaskQueue` will be lost (unless you have implemented persistence)
* A `HoldingQueue` is native to the OS and can be configured using `FileDownloader().configure` to limit the number of concurrent tasks that are executed (in total, by host or by group). When using this queue you do not change how you interact with the FileDownloader, but you cannot implement your own holding queue. Because this queue is native, it will continue to run when your app is suspended by the OS, but if the app is killed then tasks held in the holding queue will be lost (unlike tasks already enqueued natively, which persist)

#### TaskQueue
The `MemoryTaskQueue` bundled with the `background_downloader` allows:
* pacing the rate of enqueueing tasks, based on `minInterval`, to avoid 'choking' the FileDownloader when adding a large number of tasks
* managing task priorities while waiting in the queue, such that higher priority tasks are enqueued before lower priority ones, even if they are added later
* managing the total number of tasks running concurrently, by setting `maxConcurrent`
* managing the number of tasks that talk to the same host concurrently, by setting `maxConcurrentByHost`
* managing the number of tasks running that are in the same `Task.group`, by setting `maxConcurrentByGroup`

A `TaskQueue` conceptually sits 'in front of' the FileDownloader queue, and the `TaskQueue` makes the call to `FileDownloader().enqueue`. To use it, add it to the `FileDownloader` and instead of enqueuing tasks with the `FileDownloader`, you now `add` tasks to the queue:
```dart
final tq = MemoryTaskQueue();
tq.maxConcurrent = 5; // no more than 5 tasks active at any one time
tq.maxConcurrentByHost = 2; // no more than two tasks talking to the same host at the same time
tq.maxConcurrentByGroup = 3; // no more than three tasks from the same group active at the same time
FileDownloader().addTaskQueue(tq); // 'connects' the TaskQueue to the FileDownloader
FileDownloader().updates.listen((update) { // listen to updates as per usual
  print('Received update for ${update.task.taskId}: $update')
});
for (var n = 0; n < 100; n++) {
  task = DownloadTask(url: workingUrl, metData: 'task #$n'); // define task
  tq.add(task); // add to queue. The queue makes the FileDownloader().enqueue call
}
```

Because it is possible that an error occurs when the taskQueue eventually actually enqueues the task with the FileDownloader, you can listen to the `enqueueErrors` stream for tasks that failed to enqueue.

A common use for the `MemoryTaskQueue` is enqueueing a large number of tasks. This can 'choke' the downloader if done in a loop, but is easy to do when adding all tasks to a queue. The `minInterval` field of the `MemoryTaskQueue` ensures that the tasks are fed to the `FileDownloader` at a rate that does not grind your app to a halt.

The default `TaskQueue` is the `MemoryTaskQueue` which, as the  name suggests, keeps everything in memory. This is fine for most situations, but be aware that the queue may get dropped if the OS aggressively moves the app to the background. Tasks still waiting in the queue will not be enqueued, and will therefore be lost. If you want a `TaskQueue` with more persistence, or add different prioritization and concurrency roles, then subclass the `MemoryTaskQueue` and add your own persistence or logic.
In addition, if your app is suspended by the OS due to resource constraints, tasks waiting in the queue will not be enqueued to the native platform and will not run in the background. TaskQueues are therefore best for situations where you expect the queue to be emptied while the app is still in the foreground.

#### Holding queue
Use a holding queue to limit the number of tasks running concurrently. Calling `await FileDownloader().configure(globalConfig: (Config.holdingQueue, (3, 2, 1)))` activates the holding queue and sets the constraints `maxConcurrent` to 3, `maxConcurrentByHost` to 2, and `maxConcurrentByGroup` to 1. Pass `null` for no constraint for that parameter.

Using the holding queue adds a queue on the native side where tasks may have to wait before being enqueued with the Android WorkManager or iOS URLSessions. Because the holding queue lives on the native side (not Dart) tasks will continue to get pulled from the holding queue even when the app is suspended by the OS. This is different from the `TaskQueue`, which lives on the Dart side and suspends when the app is suspended by the OS 

When using a holding queue:
* Tasks will be taken out of the queue based on their priority and time of creation, provided they pass the constraints imposed by the `maxConcurrent` values
* Status messages will differ slightly. You will get the `TaskStatus.enqueued` update immediately upon enqueuing. Once the task gets enqueued with the Android WorkManager or iOS URLSessions you will not get another "enqueue" update, but if that enqueue fails the task will fail. Once the task starts running you will get `TaskStatus.running` as usual
* The holding queue and the native queues managed by the Android WorkManager or iOS URLSessions are treated as a single queue for queries like `taskForId` and `cancelTasksWithIds`. There is no way to determine whether a task is in the holding queue or already enqueued with the Android WorkManager or iOS URLSessions

### Changing WiFi requirements

By default, whether a task requires WiFi or not is determined by its `requireWiFi` property (iOS and Android only). To override this globally, call `FileDownloader().requireWifi` and pass one of the `RequireWiFi` enums:
* `asSetByTask` (default) lets the task's `requireWiFi` property determine if WiFi is required
* `forAllTasks` requires WiFi for all tasks
* `forNoTasks` does not require WiFi for any tasks

When calling `FileDownloader().requireWifi`, all enqueued tasks will be canceled and rescheduled with the appropriate WiFi requirement setting, and if the `rescheduleRunningTasks` parameter is true, all running tasks will be paused (if possible, independent of the task's `allowPause` property) or canceled and resumed/restarted with the new WiFi requirement. All newly enqueued tasks will follow this setting as well.

The global setting persists across application restarts. Check the current setting by calling `FileDownloader().getRequireWiFiSetting`.

## Authentication and pre- and post-execution callbacks

A task may be waiting a long time before it gets executed, or before it has finished, and you may need to modify the task before it actually starts (e.g. to refresh an access token) or do something when it finishes (e.g. conditionally call your server to confirm an upload has finished). The normal listener or registered callback approach does not enable that functionality, and does not execute when the app is in a suspended state.

To facilitate more complex task management functions, consider using "native" callbacks:
* `onTaskStart`: a callback called before a task starts executing. The callback receives the `Task` and returns `null` if it did not change anything, or a modified `Task` if it needs to use a different url or header. It is called after `onAuth` for token refresh, if that is set
* `onTaskFinished`: a callback called when the task has finished. The callback receives the final `TaskStatusUpdate`.
* `auth`: a class that facilitates management of authorization tokens and refresh tokens, and includes an `onAuth` callback similar to `onTaskStart`

To add a callback to a `Task`, set its `options` property, e.g. to add an onTaskStart callback:
```dart
final task = DownloadTask(url: 'https://google.com',
   options: TaskOptions(onTaskStart: myStartCallback));
```
where `myStartCallback` must be a top level or static function.

For most situations, using the event listeners or registered "regular" callbacks is recommended, as they run in the normal application context on the main isolate. Native callbacks are called directly from native code (iOS, Android or Desktop) and therefore behave differently:
* Native callbacks are called even when an application is suspended
* On iOS, the callbacks runs in the main isolate
* On Android, callbacks run in a shared background isolate, though there is no guarantee that every callback shares the same isolate as another callback
* On Desktop, callbacks run in the same isolate as the task, and every task has its own isolate

You should assume that the callback runs in an isolate, and has no access to application state or to plugins. Native callbacks are really only meant to perform simple "local" functions, operating only on the parameter passed into the callback function.

### OnTaskStart
Callback with signature`Future<Task?> Function(Task original)`, called just before the task starts executing. Your callback receives the `original` task about to start, and can modify this task if necessary. If you make modifications, you return the modified task - otherwise return null to continue execution with the original task. You can only change the task's `url` (including query parameters) and `headers` properties - making changes to any other property may lead to undefined behavior.

### OnTaskFinished
Callback with signature `Future<void> Function(TaskStatusUpdate taskStatusUpdate)`, called when the task has reached a final state (regardless of outcome). Your callback receives the final `TaskStatusUpdate` and can act on that.

### Authorization

The `Auth` object (which can be set as the `auth` property in `TaskOptions`) contains several properties that can optionally be set:
* `accessToken`: the token created by your auth mechanism to provide access.  It is typically passed as part of a request in the `Authorization` header, but different mechanisms exist
* `accessHeaders`: the headers specific to authorization. In these headers, the template `{accessToken}` will be replaced by the actual `accessToken` property, so a common value would be `{'Authorization': 'Bearer {accessToken}'`
* `accessQueryParams`: the query parameters specific to authorization. In these headers, the template `{accessToken}` will be replaced by the actual `accessToken` property
* `accessTokenExpiryTime`: the time at which the `accessToken` will expire.
* `refreshToken`, `refreshHeaders` and `refreshQueryParams` are similar to those for access (the template `{refreshToken}` will be replaced with the actual `refreshToken`)
* `refreshUrl`: url to use for refresh, including query parameters not related to the auth tokens
* `onAuth`: callback that will be called when token refresh is required

The downloader uses the `auth` object on the native side as follows:
* Just before the task starts, we check the `accessTokenExpiryTime`
* If it is close to this time, the downloader will call the `onAuth` callback (your code) to refresh the access token
  - A `defaultOnAuth` function is included that calls `auth.refreshAccessToken` using a common approach, but use your own `onAuth` callback if your auth mechanism differs
  - The `Task` returned by the `onAuth` call can change the `Auth` object itself (e.g. replace the `accessToken` with a refreshed one) and those values will be used to construct the task's request
* The `Task` request is built as follows:
  - Start with the headers and query parameters of the original task. You should have all headers and query parameters that are not related to authentication here
  - Add or replace every header and query parameter from the `accessHeaders` and `accessQueryParams` to the task's headers and query parameters, substituting the templates for `accessToken` and `refreshToken`
  - Construct the task's server request using these merged headers and query parameters

A typical way to construct a task with authorization and default `onAuth` refresh approach then is:
```dart
final auth = Auth(
    accessToken: 'initialAccessToken',
    accessHeaders: {'Authorization': 'Bearer {accessToken}'},
    refreshToken: 'initialRefreshToken',
    refreshUrl: 'https://your.server/refresh_endpoint',
    accessTokenExpiryTime: DateTime.now()
            .add(const Duration(minutes: 10)), // typically extracted from token
    onAuth: defaultOnAuth // to use typical default callback
);
final task = DownloadTask(
    url: 'https://your.server/download_endpoint',
    urlQueryParameters: {'param1': 'value1'},
    headers: {'Header1': 'value2'},
    filename: 'my_file.txt',
    options: TaskOptions(auth: auth));
```

There are limitations to the auth functionality, as the original task is not updated on the Dart side. For example, if a token refresh was performed and subsequently the task is paused, the resumed task with have the original accessToken and expiry time and will therefore trigger another token refresh.

__NOTE:__ The callback functionality is experimental for now, and its behavior may change without warning in future updates. Please provide feedback on callbacks.

## Server requests

To make a regular server request (e.g. to obtain a response from an API end point that you process directly in your app) use:
1. A `Request` object, for requests that are executed immediately, expecting an immediate return
2. A `DataTask` object, for requests that are scheduled on the background queue, similar to `DownloadTask`

### Request: immediate execution

A regular foreground request works similar to the `download` method, except you pass a `Request` object that has fewer fields than the `DownloadTask`, but is similar in structure.  You `await` the response, which will be a [Response](https://pub.dev/documentation/http/latest/http/Response-class.html) object as defined in the dart [http package](https://pub.dev/packages/http), and includes getters for the response body (as a `String` or as `UInt8List`), `statusCode` and `reasonPhrase`.

Because requests are meant to be immediate, they are not enqueued like a `Task` is, and do not allow for status/progress monitoring.

### DataTask: scheduled execution

To make a similar request using the background mechanism (e.g. if you want to wait for WiFi to be available), create and enqueue a `DataTask`.
A `DataTask` is similar to a `DownloadTask` except it:
* Does not accept file information, as there is no file involved
* Does not allow progress updates
* Accepts `post` data as a String, or
* Accepts `json` data, which will be converted to a String and posted as content type `application/json`
* Accepts `contentType` which will set the `Content-Type` header value
* Returns the server `responseBody`, `responseHeaders` and possible `taskException` in the final `TaskStatusUpdate` fields

Typically you would use `enqueue` to enqueue a `DataTask` and monitor the result using a listener or callback, but you can also use `transmit` to enqueue and wait for the final result of the `DataTask`.

## Cookies

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

## Optional parameters

The `DownloadTask`, `UploadTask` and `Request` objects all take several optional parameters that define how the task will be executed.  Note that a `Task` is a subclass of `Request`, and both `DownloadTask` and `UploadTask` are subclasses of `Task`, so what applies to a `Request` or `Task` will also apply to a `DownloadTask` and `UploadTask`.

### Request, DownloadTask & UploadTask

#### urlQueryParameters

If provided, these parameters (presented as a `Map<String, String>`) will be appended to the url as query parameters. Note that both the `url` and `urlQueryParameters` must be urlEncoded (e.g. a space must be encoded as %20).

#### Headers

Optionally, `headers` can be added to a `Request` or `Task`, which will be added to the HTTP request. This may be needed for authentication or session [cookies](#cookies).

#### HTTP request method

If provided, this request method will be used to make the request. By default, the request method is GET unless `post` is not null, or the `Task` is a `DownloadTask`, in which case it will be POST. Valid HTTP request methods are those listed in `Request.validHttpMethods`.

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

Note that certain failures can be resumed, and retries will therefore attempt to resume from a failure instead of retrying the task from scratch.

### DownloadTask & UploadTask

#### Requiring WiFi

On Android and iOS only: If the `requiresWiFi` field of a `Task` is set to true, the task won't start unless a WiFi network is available. By default `requiresWiFi` is false, and downloads/uploads will use the cellular (or metered) network if WiFi is not available, which may incur cost. Note that every task requires a working internet connection: local server connections that do not reach the internet may not work.

#### Priority

The `priority` field must be 0 <= priority <= 10 with 0 being the highest priority, and defaults to 5. On Desktop and iOS all priority levels are supported. On Android, priority levels <5 are handled as 'expedited', and >=5 is handled as a normal task.

#### Metadata and displayName

`metaData` and `displayName` can be added to a `Task`. They are ignored by the downloader but may be helpful when receiving an update about the task, and can be shown in notifications using `{metaData}` or `{displayName}`.

### UploadTask

#### File field

Set `fileField` to the field name the server expects for the file portion of a multi-part upload. Defaults to "file".

#### Mime type

Set `mimeType` to the MIME type of the file to be uploaded. By default the MIME type is derived from the filename extension, e.g. a .txt file has MIME type `text/plain`.

#### Form fields

Set `fields` to a `Map<String, String>` of name/value pairs to upload as "form fields" along with the file.

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

## Configuration

Several aspects of the downloader can be configured on startup:
* Setting the request timeout value and, for iOS only, the 'resourceTimeout'
* Checking available space before attempting a download
* Activating a holding queue to manage how many tasks are executed concurrently
* On Android, when to use the `cacheDir` for temporary files
* Setting a proxy
* Bypassing TLS Certificate validation (for debug mode only, Android and Desktop only)
* On Android, running tasks in 'foreground mode' to allow longer runs
* On Android, whether or not to use external storage
* On iOS, localizing the notification button texts

Please read the [configuration document](https://github.com/781flyingdutchman/background_downloader/blob/main/CONFIG.md) for details on how to configure.

## Limitations

* iOS 13.0 or greater; Android API 21 or greater
* On Android, downloads are by default limited to 9 minutes, after which the download will end with `TaskStatus.failed`. To allow for longer downloads, set the `DownloadTask.allowPause` field to true: if the task times out, it will pause and automatically resume, eventually downloading the entire file. Alternatively, [configure](#configuration) the downloader to allow tasks to run in the foreground
* On iOS, once enqueued (i.e. `TaskStatus.enqueued`), a background download must complete within 4 hours. [Configure](#configuration) 'resourceTimeout' to adjust.
* Redirects will be followed
* Background downloads and uploads are aggressively controlled by the native platform. You should therefore always assume that a task that was started may not complete, and may disappear without providing any status or progress update to indicate why. For example, if a user swipes your app up from the iOS App Switcher, all scheduled background downloads are terminated without notification    
