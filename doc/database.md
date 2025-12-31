# Database & Central Monitoring

Instead of monitoring in the `download` call, you may want to use a centralized task monitoring approach, and/or keep track of tasks in a database. This is helpful for instance if:
1. You start download in multiple locations in your app, but want to monitor those in one place, instead of defining `onStatus` and `onProgress` for every call to `download`
2. You have different groups of tasks, and each group needs a different monitor
3. You want to keep track of the status and progress of tasks in a persistent database that you query
4. Your downloads take long, and your user may switch away from your app for a long time, which causes your app to get suspended by the operating system.

## Getting started

To use central monitoring and/or the database, call `FileDownloader().start()` at the start of your app (e.g. in `main` or in your `Home` widget) and register your callbacks or listener:

```dart
void main() async {
  // register a listener or callback to monitor tasks - see below
  FileDownloader().updates.listen((update) {
    print('Got update: $update');
  });

  // start the downloader. 
  // If you want to track tasks in the database and clean up old records:
  await FileDownloader().start(autoCleanDatabase: true);
  
  // OR if you don't want to use the database at all:
  // await FileDownloader().start(doTrackTasks: false);
  
  runApp(const MyApp());
}
```

**Important**: You must register your listener or callbacks *before* calling `start()`. The `start()` call triggers the processing of background updates (e.g., tasks that completed while the app was suspended), and if your listener is not registered yet, you will miss those updates.

## Monitoring tasks

You can monitor tasks centrally using **event listeners** or **callbacks**. In both cases, you will use `enqueue` instead of `download` or `upload` to start your tasks. `enqueue` returns almost immediately with a `bool` to indicate if the `Task` was successfully enqueued.

### Option 1: Using an event listener

Listen to updates from the downloader by listening to the `updates` stream.

```dart
    final subscription = FileDownloader().updates.listen((update) {
      switch(update) {
        case TaskStatusUpdate():
          print('Status update for ${update.task} with status ${update.status}');
        case TaskProgressUpdate():
          print('Progress update for ${update.task} with progress ${update.progress}');
      }
    });

    // enqueue a task
    final task = DownloadTask(
        url: 'https://google.com',
        filename: 'google.html',
        updates: Updates.statusAndProgress); // request both status and progress updates
        
    final successFullyEnqueued = await FileDownloader().enqueue(task);
```

Note that `successFullyEnqueued` only refers to the enqueueing of the download task, not its result, which must be monitored via the listener.

### Option 2: Using callbacks

Instead of listening to the `updates` stream you can register a callback for status updates, and/or a callback for progress updates. This may be the easiest way if you want different callbacks for different [groups](lifecycle.md#grouping-tasks).

```dart
// define callbacks
void taskStatusCallback(TaskStatusUpdate update) {
  print('taskStatusCallback for ${update.task) with status ${update.status}');
}

void taskProgressCallback(TaskProgressUpdate update) {
  print('taskProgressCallback for ${update.task} with progress ${update.progress}');
}

// register callbacks
FileDownloader().registerCallbacks(
    taskStatusCallback: taskStatusCallback,
    taskProgressCallback: taskProgressCallback);

// enqueue a task
final successFullyEnqueued = await FileDownloader().enqueue(
    DownloadTask(url: 'https://google.com', filename: 'google.html'));
```

You can unregister callbacks using `FileDownloader().unregisterCallbacks()`.

## The Database

The `FileDownloader` comes with a persistent database to track your tasks. By default, `start()` activates task tracking, which means every task you enqueue is stored in the database, and its status and progress is updated as it runs.

### Querying the database

You can query the database to get the status of a task, or to get a list of all tasks. The database returns [TaskRecord](https://pub.dev/documentation/background_downloader/latest/background_downloader/TaskRecord-class.html) objects.

```dart
// get a specific task record
final record = await FileDownloader().database.recordForId(taskId);

// get all task records
final allRecords = await FileDownloader().database.allRecords();
```

You can interact with the `database` using `allRecords`, `allRecordsOlderThan`, `recordForId`,`deleteAllRecords`, `deleteRecordWithId` etc. If you only want to track tasks in a specific [group](lifecycle.md#grouping-tasks), you can start the downloader with `await FileDownloader().trackTasksInGroup('myGroup')` instead of the default `trackTasks`.

### Listening to database updates

To listen to changes to the database (e.g. to update a UI list of downloads), use the `FileDownloader().database.updates` stream. This emits a `TaskRecord` every time a record is updated in the database.

```dart
FileDownloader().database.updates.listen((record) {
    print('Database record updated for task ${record.taskId} to status ${record.status}');
});
```

Note that database updates happen _after_ status or progress updates, so if you are listening to both, you will see the status update first, and then the database update.

### Database storage engines

By default, the downloader uses a modified version of the [localstore](https://pub.dev/packages/localstore) package. To use a different persistent storage solution (e.g. SQLite), create a class that implements the [PersistentStorage](https://pub.dev/documentation/background_downloader/latest/background_downloader/PersistentStorage-class.html) interface, and initialize the downloader by calling `FileDownloader(persistentStorage: MyPersistentStorage())` *before* the first use of the `FileDownloader`.

A SQLite implementation is available in the [background_downloader_sql](https://pub.dev/packages/background_downloader_sql) package.

### Automated database cleanup

If you use the `start()` method, you can pass `autoCleanDatabase: true` to automatically clean up the database (remove old records) and prevent it from growing indefinitely. The default is `false` to prevent breaking changes for existing users, but it is recommended for new users.

You can also manually call `FileDownloader().database.cleanUp()`. The `cleanUp()` method takes optional parameters `maxAge` (defaults to 10 days) and `maxRecordCount` (defaults to 500 records). If the database exceeds these limits, the oldest records are removed.

## Advanced: What `start()` does

The `FileDownloader().start()` method is a convenience method that calls several others to initialize the downloader and ensure it is ready to handle background tasks. Specifically, it:

1.  **Tracks tasks**: Calls `FileDownloader().trackTasks()` to enable database tracking (if `doTrackTasks` is true, which is the default).
2.  **Resumes from background**: Calls `FileDownloader().resumeFromBackground()` to process any events that happened while the app was suspended.
3.  **Reschedules killed tasks**: Calls `FileDownloader().rescheduleKilledTasks()` to retry tasks that may have been lost if the app was killed by the OS (if `doRescheduleKilledTasks` is true, which is the default).
4.  **Database cleanup**: Calls `FileDownloader().database.cleanUp()` to remove old records (if `autoCleanDatabase` is true, which is the default is `false`).

If you want more control, you can call these methods individually instead of calling `start()`.
