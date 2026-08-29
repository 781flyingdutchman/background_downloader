# Downloads

## DownloadTask

The `DownloadTask` defines what to download, where to store it, and how to configure execution.

```dart
final task = DownloadTask(
  url: 'https://example.com/file.zip',
  filename: 'my_file.zip',
  directory: 'downloads',
  baseDirectory: BaseDirectory.applicationDocuments,
  transferHints: {TransferHint.userInitiated, TransferHint.largeFile},
  requiresWiFi: false,
  retries: 3,
  metaData: 'custom_id_123',
);
```

---

## 1. High-Level Transfer API (Recommended)

The recommended way to execute a download is via `FileDownloader().startTransfer`, which returns a [`Transfer`](transfers.md) handle.

```dart
final transfer = await FileDownloader().startTransfer(task);

// Await the downloaded File directly:
final file = await transfer.file;
print('File ready at: ${file.path}');

// Or bind reactive notifiers to Flutter widgets:
// transfer.progressNotifier, transfer.statusNotifier, etc.
```

For batch downloads across multiple files, use `startTransfers`:
```dart
final transfers = await FileDownloader().startTransfers(
  [task1, task2, task3],
  onProgress: (succeeded, failed) => print('Progress: $succeeded done, $failed failed'),
);
```

👉 **[See the Transfers Guide for full details on UI widgets, controls, and notifiers](transfers.md)**

---

## 2. Direct Awaitable Download (`download`)

If you want a simple synchronous-style `Future` without using a `Transfer` object, call `.download`:

```dart
final result = await FileDownloader().download(
  task,
  onProgress: (progress) => print('Progress: ${progress * 100}%'),
  onStatus: (status) => print('Status: $status'),
);

if (result.status == TaskStatus.complete) {
  print('Download succeeded!');
}
```

---

## 3. Central Queueing (`enqueue` / `enqueueAll`)

For pipeline architectures where tasks are enqueued asynchronously and monitored centrally via callbacks or the global `FileDownloader().updates` stream:

```dart
FileDownloader().start(); // activates database tracking

final enqueued = await FileDownloader().enqueue(task);
// Or enqueue hundreds of tasks at once:
final results = await FileDownloader().enqueueAll(taskList);
```

See [Database & Monitoring](database.md) and [Status & Progress Updates](status_updates.md) for details on central event handling.

---

## 4. Parallel Downloads

Some servers offer higher speeds when downloading chunks of a large file in parallel from multiple connections or mirrors. To use parallel chunked downloading, create a `ParallelDownloadTask`:

```dart
final task = ParallelDownloadTask(
  urls: [
    'https://example.com/large_file.zip',
    'https://mirror.com/large_file.zip',
  ],
  chunks: 4,
  filename: 'large_file.zip',
);

final transfer = await FileDownloader().startTransfer(task);
final file = await transfer.file;
```

* Parallel downloads create internal chunk tasks in a reserved group named `'chunk'`.
* Status and progress updates are aggregated seamlessly onto the parent `ParallelDownloadTask`.
* Parallel downloads do not support URIs or Android UIDT.

---

## 5. Server-Suggested Filenames

If you want the downloaded filename to be determined by the server's `Content-Disposition` header:

```dart
final task = DownloadTask(
  url: 'https://example.com/download',
  filename: DownloadTask.suggestedFilename, // or '?'
);
```
Or use `TransferHint.useSuggestedFilename`:
```dart
final task = DownloadTask(
  url: 'https://example.com/download',
  transferHints: {TransferHint.useSuggestedFilename},
);
```

Alternatively, resolve the suggested filename before starting:
```dart
final task = await DownloadTask(url: 'https://example.com/download')
    .withSuggestedFilename(unique: true); // triggers a HEAD call
```
