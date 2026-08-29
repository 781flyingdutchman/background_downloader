# Transfers

The **Transfer API** is the recommended, primary way to manage downloads, uploads, and server data tasks with `FileDownloader`.

Instead of manually managing raw streams, callbacks, or task IDs, starting a transfer returns a first-class [`Transfer`](../lib/src/transfer.dart) handle. A `Transfer` provides reactive `ValueNotifier`s for Flutter widgets, direct `Future`s for results, built-in pause/resume/cancel controls, notification tap handling, and automatic network stall detection.

---

## 1. Quick Start

On app startup (e.g. in `main()` or your top-level `initState()`), call `FileDownloader().start(autoCleanDatabase: true)`. 

> [!TIP]
> **Always use `autoCleanDatabase: true`**: While `autoCleanDatabase` defaults to `false` solely to preserve backward compatibility for legacy implementations, calling `FileDownloader().start(autoCleanDatabase: true)` is typically recommended. It automatically removes old, finished task records from the database and prevents it from growing indefinitely over time.

Then simply create a `DownloadTask` (or `UploadTask` / `DataTask`) and call `FileDownloader().startTransfer`:

```dart
// 1. Activate database tracking on app launch (recommended)
await FileDownloader().start(autoCleanDatabase: true);

// 2. Configure notifications (recommended, especially for userInitiated / UIDT tasks)
FileDownloader().configureNotification(
  running: const TaskNotification('Downloading', 'file: {filename}'),
  complete: const TaskNotification('Download complete', 'file: {filename}'),
  error: const TaskNotification('Download failed', 'file: {filename}'),
  progressBar: true,
  tapOpensFile: true,
);

// 3. Define the task with smart hints
final task = DownloadTask(
  url: 'https://example.com/large_video.mp4',
  filename: 'video.mp4',
  transferHints: {TransferHint.userInitiated, TransferHint.largeFile},
);

// 4. Start the transfer
final transfer = await FileDownloader().startTransfer(task);

// 5. Await the final completed File:
final file = await transfer.file;
print('Downloaded to: ${file.path}');

// Or await the result TaskStatusUpdate:
final result = await transfer.result;
if (result.status == TaskStatus.complete) {
  print('Transfer completed successfully!');
}
```

---

## 2. The `Transfer` Handle

When you call `startTransfer`, `startTransfers`, or `getOrStartTransfer`, you receive a `Transfer` object.

### Awaitable Futures
- **`transfer.result`**: `Future<TaskStatusUpdate>` completing when the transfer reaches any final state (`complete`, `failed`, `canceled`, `notFound`).
- **`transfer.file`**: `Future<File>` resolving to the downloaded or uploaded file once complete. Throws a `TaskException` if the transfer fails or is canceled.
- **`transfer.responseBody`**: `Future<String?>` resolving to the server response body (for `DataTask` or uploads).

### Reactive ValueNotifiers (Flutter UI Ready)
Bind directly to UI elements using `ValueListenableBuilder` or the bundled [Transfer Widgets](#8-plug-and-play-ui-widgets):
- **`transfer.statusNotifier`**: Emits `TaskStatus` (`enqueued`, `running`, `paused`, `complete`, `failed`, `canceled`, etc.).
- **`transfer.progressNotifier`**: Emits a clean `double` progress between `0.0` and `1.0` (or `null` if indeterminate).
- **`transfer.networkSpeedNotifier`**: Emits transfer speed in MB/s (or `-1.0` if unavailable).
- **`transfer.timeRemainingNotifier`**: Emits estimated `Duration` remaining.
- **`transfer.holdReasonNotifier`**: Emits `TransferHoldReason.none`, `waitingForWiFi`, or `offline`.
- **`transfer.exceptionNotifier`**: Emits the `TaskException?` if an error occurred.
- **`transfer.notificationTapNotifier`**: Emits the `NotificationType?` when the user taps a system notification for this transfer.

### Action Methods
Control the individual transfer directly without having to pass task IDs or groups:
```dart
await transfer.pause();          // Pauses the transfer (if supported)
await transfer.resume();         // Resumes a paused transfer
await transfer.cancel();         // Cancels the transfer
await transfer.allowCellular();  // Overrides WiFi restriction if held waiting for WiFi
```

---

## 3. Notification Tap Handling

`Transfer` makes it easy to react when a user taps a system notification:

### 1. Direct Transfer Tap Listener
Every `Transfer` exposes `notificationTapNotifier` (and getter `transfer.notificationTap`):

```dart
transfer.notificationTapNotifier.addListener(() {
  final tapType = transfer.notificationTap;
  if (tapType == NotificationType.complete) {
    // Navigate to viewer or open custom modal
    print('User tapped complete notification for ${transfer.task.filename}');
  }
});
```

### 2. Auto-Open File (`tapOpensFile`)
If your only goal on tapping a completed notification is to open the file, set `tapOpensFile: true` in your notification configuration:
```dart
FileDownloader().configureNotification(
  complete: const TaskNotification('Done', 'Tap to open {filename}'),
  tapOpensFile: true,
);
```

---

## 4. Starting Transfers

### Single Transfer (`startTransfer`)
```dart
final transfer = await FileDownloader().startTransfer(task);
```
Auto-enqueues the task, initializes monitoring, and applies any `notificationConfig` or `transferHints`.

### Batch Transfers (`startTransfers`)
Use `startTransfers` to launch multiple transfers concurrently using `enqueueAll` with aggregate progress tracking:
```dart
final tasks = [
  DownloadTask(url: 'https://example.com/item1.zip', filename: 'item1.zip'),
  DownloadTask(url: 'https://example.com/item2.zip', filename: 'item2.zip'),
  DownloadTask(url: 'https://example.com/item3.zip', filename: 'item3.zip'),
];

final transfers = await FileDownloader().startTransfers(
  tasks,
  onProgress: (succeeded, failed) {
    print('Batch progress: $succeeded succeeded, $failed failed out of ${tasks.length}');
  },
);

// Wait for all transfers to complete:
final results = await Future.wait(transfers.map((t) => t.result));
```

### Resume / Reconnection (`getOrStartTransfer`)
If your app restarts or a screen reloads, `getOrStartTransfer` finds an existing active or completed transfer (by task ID, target destination, or custom matcher) so you don't duplicate transfers:

```dart
// Returns existing Transfer if active or already completed; otherwise enqueues fresh
final transfer = await FileDownloader().getOrStartTransfer(task);

// Or match by custom metadata / predicate:
final transfer = await FileDownloader().getOrStartTransfer(
  task,
  matchBy: (existingTask) => existingTask.metaData == 'my_unique_id',
);
```

---

## 5. Transfer Collections & Queries

`FileDownloader` provides reactive collections of managed transfers:

```dart
// Reactive list of all transfers (re-emits on state changes)
ValueListenable<List<Transfer>> notifier = FileDownloader().transfersNotifier;

// Query current transfers
List<Transfer> all = FileDownloader().allTransfers();
List<Transfer> active = FileDownloader().activeTransfers();
List<Transfer> completed = FileDownloader().completedTransfers();

// Look up specific transfer
Transfer? transfer = FileDownloader().transferForId('task123');
Transfer? transfer = FileDownloader().transferForTask(task);
Transfer? transfer = FileDownloader().transferForUrl('https://example.com/file.zip');
```

---

## 6. Smart Tuning with `TransferHint` & Android 14+ UIDT

Pass `transferHints` to any `Task` constructor to automatically configure optimal priority, pause capability, and update settings based on your intent:

| `TransferHint` | Effect |
| :--- | :--- |
| `TransferHint.userInitiated` | Sets `priority: 0` (activates Android 14+ UIDT & iOS max priority 1.0) and enables `allowPause: true`. |
| `TransferHint.largeFile` | Ensures `allowPause: true` (enables Android 9-minute auto-resume cycles and pause resilience). |
| `TransferHint.smallFile` | Sets `updates: Updates.status` to reduce unnecessary MethodChannel overhead. |
| `TransferHint.lowPriority` | Sets `priority: 10` (lowest priority) so background syncing doesn't contend with interactive tasks. |
| `TransferHint.useSuggestedFilename` | Uses server `Content-Disposition` headers (`filename: '?'`). |
| `TransferHint.binaryUpload` | For `UploadTask`, sends raw binary bytes directly instead of multipart/form-data. |

### ⚠️ Important: Notifications Required for `TransferHint.userInitiated` (UIDT)

Under Android 14+ (API 34+) system requirements, **User-Initiated Data Transfer (UIDT)** jobs require an active, user-visible notification while running. If a task requests UIDT (`priority: 0` or `TransferHint.userInitiated`) without a notification, the Android system may fail to schedule it as UIDT or cancel it.

**Best Practice:** Whenever using `TransferHint.userInitiated` (or `priority: 0`), ensure the task includes a notification:

1. **Option A: Globally or per group (recommended)**
   ```dart
   FileDownloader().configureNotification(
     running: const TaskNotification('Downloading', '{filename}'),
     complete: const TaskNotification('Done', '{filename}'),
     error: const TaskNotification('Error', '{filename}'),
     progressBar: true,
   );
   ```

2. **Option B: Specifically on the Task**
   ```dart
   final task = DownloadTask(
     url: 'https://example.com/large_video.mp4',
     filename: 'video.mp4',
     transferHints: {TransferHint.userInitiated, TransferHint.largeFile},
     notificationConfig: const NotificationConfig(
       running: TaskNotification('Downloading', '{filename}'),
       complete: TaskNotification('Complete', '{filename}'),
       progressBar: true,
     ),
   );
   ```

---

## 7. Scoping with `FileDownloader.scoped`

If you are developing a package, plugin, or modular feature, you can isolate all tasks and callbacks using a **scoped namespace**:

```dart
// Isolated downloader instance for your module
final downloader = FileDownloader.scoped('my_audio_player');

final transfer = await downloader.startTransfer(task);

// downloader.allTransfers(), downloader.reset(), and callbacks only affect 'my_audio_player'
```

- Each call to `FileDownloader.scoped('namespace')` returns the same cached instance for that namespace.
- Task groups are prefixed under the hood (`"my_audio_player.default"`), ensuring no conflicts with the main application or other packages.
- All callbacks and queries automatically strip the namespace prefix so your code works with clean group names.

---

## 8. Plug-and-Play UI Widgets

The package includes pre-built, reactive Flutter widgets designed specifically for `Transfer`:

### `TransferProgressBar`
A linear progress bar that automatically reacts to `progressNotifier`, `statusNotifier`, and speed updates:

```dart
TransferProgressBar(
  transfer: transfer,
  showSpeed: true,
  showPercentage: true,
  showStatusText: true,
)
```

### `TransferButton`
An action button that dynamically switches icons between pause, resume, cancel, and completed checkmark:

```dart
TransferButton(
  transfer: transfer,
  onCancel: () => print('Cancelled'),
)
```

### `TransferListTile`
A complete material list tile combining the display name, subtitle, progress bar, and action button:

```dart
TransferListTile(
  transfer: transfer,
  showSpeed: true,
  showPercentage: true,
)
```

---

## 9. Network-Aware Offline Resilience & Stall Watchdog

1. **Smart Network Holding**: When a transfer is running and the device loses network connectivity (or drops off Wi-Fi when `requiresWiFi` is set), the transfer is automatically paused or held in `tasksWaitingToRetry` without decrementing retries. `transfer.holdReasonNotifier` emits `TransferHoldReason.offline` or `TransferHoldReason.waitingForWiFi`. Once connectivity is restored, it resumes automatically.
2. **Stall Watchdog**: Set `stallTimeout` on your task (e.g. `stallTimeout: Duration(seconds: 30)`). If a running transfer experiences no network progress within that window while the app is active, the watchdog will automatically kick or resume the transfer.
