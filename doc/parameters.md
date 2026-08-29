# Optional Parameters

The `DownloadTask`, `UploadTask` and `Request` objects all take several optional parameters that define how the task will be executed. Note that a `Task` is a subclass of `Request`, and both `DownloadTask` and `UploadTask` are subclasses of `Task`, so what applies to a `Request` or `Task` will also apply to a `DownloadTask` and `UploadTask`.

---

## 1. Smart Hints & Transfer Configuration

### `transferHints`
Pass a `Set<TransferHint>` to auto-tune task properties based on intent:
- `TransferHint.userInitiated`: Sets `priority: 0` (activates Android 14+ UIDT & iOS max priority) and enables `allowPause: true`.
- `TransferHint.largeFile`: Enables `allowPause: true` to survive Android 9-minute execution timeouts via automatic pause/resume cycles.
- `TransferHint.smallFile`: Sets `updates: Updates.status` to minimize MethodChannel message traffic.
- `TransferHint.lowPriority`: Sets `priority: 10` for non-urgent background syncs.
- `TransferHint.useSuggestedFilename`: Sets `filename: DownloadTask.suggestedFilename` (`'?'`) to extract the filename from the server `Content-Disposition` header.
- `TransferHint.binaryUpload`: For `UploadTask`, sends raw file bytes directly in the HTTP body (sets `post: 'binary'`).

### `notificationConfig`
Associate a [`TaskNotificationConfig`](notifications.md) directly with an individual task:
```dart
final task = DownloadTask(
  url: 'https://example.com/asset.zip',
  notificationConfig: TaskNotificationConfig(
    running: TaskNotification('Downloading', '{displayName}'),
    complete: TaskNotification('Complete', '{displayName} ready!'),
    progressBar: true,
  ),
);
```

### `stallTimeout`
Set a `Duration` timeout for network activity. If an active transfer makes no progress for this duration while the app is in the foreground, the stall watchdog will kick or resume the transfer:
```dart
final task = DownloadTask(
  url: 'https://example.com/stream.bin',
  stallTimeout: Duration(seconds: 30),
);
```

---

## 2. General Request & Task Parameters

### `urlQueryParameters`
If provided, these parameters (`Map<String, String>`) will be appended to the URL as query parameters. Both `url` and `urlQueryParameters` must be properly URL-encoded.

### `headers`
Optionally, `headers` can be added to a `Request` or `Task` to pass authentication tokens, cookies, or custom HTTP headers.

### `httpRequestMethod`
The HTTP request method used (e.g. GET, POST, PUT, DELETE, PATCH). Defaults to GET for downloads and POST for uploads and data tasks with bodies.

### `post`
For downloads, if the server requires a POST request, set `post` to a `String` or `Uint8List` representing the POST body.
For uploads, setting `post: 'binary'` initiates a raw binary body upload instead of multipart.

### `retries`
To schedule automatic retries with exponential backoff on network failures, set `retries` (integer from 1 to 10). Failed tasks that can resume will attempt to resume rather than restart from scratch.

---

## 3. Background Execution Parameters

### `requiresWiFi`
When `true`, the task will only run over WiFi or unmetered connections. If WiFi is lost or unavailable, the transfer will be automatically held until WiFi returns.

### `priority`
Ranges from 0 (highest) to 10 (lowest), default 5.
- On iOS and Desktop, all priority levels are supported natively.
- On Android, priority < 5 is treated as expedited. If priority is 0, has an associated notification, and runs on Android 14+, the downloader uses the User Initiated Data Transfer (UIDT) service, removing the 9-minute background limit.

To use UIDT on Android 14+, declare the following in `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.RUN_USER_INITIATED_JOBS" />

<service
    android:name="com.bbflight.background_downloader.UIDTJobService"
    android:permission="android.permission.BIND_JOB_SERVICE"
    android:exported="true"
    android:foregroundServiceType="dataSync" />
```

### `allowPause`
When `true`, enables manual pausing via `transfer.pause()` or `FileDownloader().pause(task)`, and allows the downloader to recover and resume interrupted downloads when connectivity changes.

### `metaData` and `displayName`
Arbitrary strings attached to the task for application tracking, accessible in callbacks and expandable in notifications using `{metaData}` and `{displayName}`.

---

## 4. UploadTask Specifics

### `fileField`
The form field name for the uploaded file in multipart uploads (defaults to `"file"`).

### `mimeType`
The MIME type of the uploaded file. If omitted, derived from the file extension.

### `fields`
Form fields (`Map<String, String>`) sent alongside the file in multipart requests.
