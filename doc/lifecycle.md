# Lifecycle & Queue Management

## Managing tasks and the queue

## Canceling, pausing and resuming tasks

To enable pausing, set the `allowPause` field of the `Task` to `true`. This may also cause the task to `pause` un-commanded. For example, the OS may choose to pause the task if someone walks out of WiFi coverage.

To cancel, pause or resume a task, call:
* `cancel` to cancel a task
* `cancelAll` to cancel all tasks currently running, a specific list of tasks, or all tasks in a `group`.
* `cancelTaskWithId` to cancel the tasks with that taskId
* `cancelTasksWithIds` to cancel all tasks with a `taskId` in the provided list of taskIds
* `pause` to attempt to pause a task. Pausing is only possible for download GET requests, only if the `Task.allowPause` field is true, and only if the server supports pause/resume. Soon after the task is running (`TaskStatus.running`) you can call `taskCanResume` which will return a Future that resolves to `true` if the server appears capable of pause & resume. If it is not, then `pause` will have no effect and return false
* `pauseAll` to attempt to pause a all tasks currently running, a specific list of tasks, or all tasks in a `group`. Returns a list of tasks that were paused
* `resume` to resume a previously paused task (or certain failed tasks), which returns true if resume appears feasible. The task status will follow the same sequence as a newly enqueued task. If resuming turns out to be not feasible (e.g. the operating system deleted the temp file with the partial download) then the task will either restart as a normal download, or fail.
* `resumeAll` to resume all tasks currently paused, a specific list of tasks, or all tasks in a `group`. Returns a list of tasks that were resumed


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

## Grouping tasks

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

## Task queues and Holding queues
Once you `enqueue` a task with the `FileDownloader` it is added to an internal queue that is managed by the native platform you're running on (e.g. Android). Once enqueued, you have limited control over the execution order, the number of tasks running in parallel, etc, because all that is managed by the platform.  If you want more control over the queue, you need to use a `TaskQueue` or a `HoldingQueue`:
* A `TaskQueue` is a Dart object that you can add to the `FileDownloader`. You can create this object yourself (implementing the `TaskQueue` interface) or use the bundled `MemoryTaskQueue` implementation. This queue sits "in front of" the `FileDownloader` and instead of using the `enqueue` and `download` methods directly, you now simply `add` your tasks to the `TaskQueue`. Because this is a Dart object, the queue will suspend when the OS suspends your application, and if the app gets killed, tasks held in the `TaskQueue` will be lost (unless you have implemented persistence)
* A `HoldingQueue` is native to the OS and can be configured using `FileDownloader().configure` to limit the number of concurrent tasks that are executed (in total, by host or by group). When using this queue you do not change how you interact with the FileDownloader, but you cannot implement your own holding queue. Because this queue is native, it will continue to run when your app is suspended by the OS, but if the app is killed then tasks held in the holding queue will be lost (unlike tasks already enqueued natively, which persist)

### TaskQueue
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

Before the introduction of `enqueueAll`, a common use for the `TaskQueue` was enqueueing a large number of tasks without 'choking' the downloader if done in a loop. The current recommended method for that scenario is to use `enqueuAll`, though the `TaskQueue` can be used if not all tasks are available at the time of enqueue.  Use property `minInterval` to pace the rate at which tasks are enqueued using the `TaskQueue`. 

The default `TaskQueue` is the `MemoryTaskQueue` which, as the  name suggests, keeps everything in memory. This is fine for most situations, but be aware that the queue may get dropped if the OS aggressively moves the app to the background. Tasks still waiting in the queue will not be enqueued, and will therefore be lost. If you want a `TaskQueue` with more persistence, or add different prioritization and concurrency roles, then subclass the `MemoryTaskQueue` and add your own persistence or logic.
In addition, if your app is suspended by the OS due to resource constraints, tasks waiting in the queue will not be enqueued to the native platform and will not run in the background. TaskQueues are therefore best for situations where you expect the queue to be emptied while the app is still in the foreground.

### Holding queue
Use a holding queue to limit the number of tasks running concurrently. Calling `await FileDownloader().configure(globalConfig: (Config.holdingQueue, (3, 2, 1)))` activates the holding queue and sets the constraints `maxConcurrent` to 3, `maxConcurrentByHost` to 2, and `maxConcurrentByGroup` to 1. Pass `null` for no constraint for that parameter.

Using the holding queue adds a queue on the native side where tasks may have to wait before being enqueued with the Android WorkManager or iOS URLSessions. Because the holding queue lives on the native side (not Dart) tasks will continue to get pulled from the holding queue even when the app is suspended by the OS. This is different from the `TaskQueue`, which lives on the Dart side and suspends when the app is suspended by the OS 

When using a holding queue:
* Tasks will be taken out of the queue based on their priority and time of creation, provided they pass the constraints imposed by the `maxConcurrent` values
* Status messages will differ slightly. You will get the `TaskStatus.enqueued` update immediately upon enqueuing. Once the task gets enqueued with the Android WorkManager or iOS URLSessions you will not get another "enqueue" update, but if that enqueue fails the task will fail. Once the task starts running you will get `TaskStatus.running` as usual
* The holding queue and the native queues managed by the Android WorkManager or iOS URLSessions are treated as a single queue for queries like `taskForId` and `cancelTasksWithIds`. There is no way to determine whether a task is in the holding queue or already enqueued with the Android WorkManager or iOS URLSessions

## Changing WiFi requirements

By default, whether a task requires WiFi or not is determined by its `requireWiFi` property (iOS and Android only). To override this globally, call `FileDownloader().requireWifi` and pass one of the `RequireWiFi` enums:
* `asSetByTask` (default) lets the task's `requireWiFi` property determine if WiFi is required
* `forAllTasks` requires WiFi for all tasks
* `forNoTasks` does not require WiFi for any tasks

When calling `FileDownloader().requireWifi`, all enqueued tasks will be canceled and rescheduled with the appropriate WiFi requirement setting, and if the `rescheduleRunningTasks` parameter is true, all running tasks will be paused (if possible, independent of the task's `allowPause` property) or canceled and resumed/restarted with the new WiFi requirement. All newly enqueued tasks will follow this setting as well.

The global setting persists across application restarts. Check the current setting by calling `FileDownloader().getRequireWiFiSetting`.

## Authentication and pre- and post-execution callbacks

A task may be waiting a long time before it gets executed, or before it has finished, and you may need to modify the task before it actually starts (e.g. to refresh an access token) or do something when it finishes (e.g. conditionally call your server to confirm an upload has finished). The normal listener or registered callback approach does not enable that functionality, and does not execute when the app is in a suspended state.

To facilitate more complex task management functions, consider using "native" callbacks:
* `beforeTaskStart`: a callback called before a task starts executing. The callback receives the `Task` and returns `null` if the task should continue, or a `TaskStatusUpdate` if it should not start - in which case the `TaskStatusUpdate` is posted as the last state update for the task
* `onTaskStart`: a callback called before a task starts executing, after `beforeTaskStart`. The callback receives the `Task` and returns `null` if it did not change anything, or a modified `Task` if it needs to use a different url or header. It is called after `onAuth` for token refresh, if that is set
* `onTaskFinished`: a callback called when the task has finished. The callback receives the final `TaskStatusUpdate`.
* `auth`: a class that facilitates management of authorization tokens and refresh tokens, and includes an `onAuth` callback similar to `onTaskStart`

To add a callback to a `Task`, set its `options` property, e.g. to add an onTaskStart callback:
```dart
final task = DownloadTask(url: 'https://google.com',
   options: TaskOptions(onTaskStart: myStartCallback));
```
where `myStartCallback` must be a top level or static function, and must be annotated with `@pragma("vm:entry-point")` to ensure it can be called from native code.

For most situations, using the event listeners or registered "regular" callbacks is recommended, as they run in the normal application context on the main isolate. Native callbacks are called directly from native code (iOS, Android or Desktop) and therefore behave differently:
* Native callbacks are called even when an application is suspended
* On iOS, the callbacks runs in the main isolate
* On Android, callbacks run in a shared background isolate, though there is no guarantee that every callback shares the same isolate as another callback
* On Desktop, callbacks run in the same isolate as the task, and every task has its own isolate

You should assume that the callback runs in an isolate, and has no access to application state or to plugins. Native callbacks are really only meant to perform simple "local" functions, operating only on the parameter passed into the callback function.

### BeforeTaskStart
Callback with signature `Future<TaskStatusUpdate?> Function(Task task)`, called just before the task starts executing. Your callback receives the `task` and should return `null` if the task should proceed. If the task should end before it is started, return a `TaskStatusUpdate` object, which will be returned. The `TaskStatusUpdate` object must be consistent with normal updates of that type, e.g. an update with `status` set to `.canceled` cannot contain an `exception` or `responseStatusCode`. 

### OnTaskStart
Callback with signature`Future<Task?> Function(Task original)`, called just before the task starts executing, immediately after `BeforeTaskStart`. Your callback receives the `original` task about to start, and can modify this task if necessary. If you make modifications, you return the modified task - otherwise return null to continue execution with the original task. You can only change the task's `url` (including query parameters) and `headers` properties - making changes to any other property may lead to undefined behavior.

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
