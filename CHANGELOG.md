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
