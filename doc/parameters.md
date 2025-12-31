# Optional Parameters

The `DownloadTask`, `UploadTask` and `Request` objects all take several optional parameters that define how the task will be executed.  Note that a `Task` is a subclass of `Request`, and both `DownloadTask` and `UploadTask` are subclasses of `Task`, so what applies to a `Request` or `Task` will also apply to a `DownloadTask` and `UploadTask`.

## Request, DownloadTask & UploadTask

### urlQueryParameters

If provided, these parameters (presented as a `Map<String, String>`) will be appended to the url as query parameters. Note that both the `url` and `urlQueryParameters` must be urlEncoded (e.g. a space must be encoded as %20).

### Headers

Optionally, `headers` can be added to a `Request` or `Task`, which will be added to the HTTP request. This may be needed for authentication or session [cookies](requests.md#cookies).

### HTTP request method

If provided, this request method will be used to make the request. By default, the request method is GET unless `post` is not null, or the `Task` is a `DownloadTask`, in which case it will be POST. Valid HTTP request methods are those listed in `Request.validHttpMethods`.

### POST requests

For downloads, if the required server request is a HTTP POST request (instead of the default GET request) then set the `post` field of a `DownloadTask` to a `String` or `UInt8List` representing the data to be posted (for example, a JSON representation of an object). To make a POST request with no data, set `post` to an empty `String`.

For an `UploadTask` the POST field is used to request a binary upload, by setting it to 'binary'. By default, uploads are done using the form/multi-part format.

### Retries

To schedule automatic retries of failed requests/tasks (with exponential backoff), set the `retries` field to an
integer between 1 and 10. A normal `Task` (without the need for retries) will follow status
updates from `enqueued` -> `running` -> `complete` (or `notFound`). If `retries` has been set and
the task fails, the sequence will be `enqueued` -> `running` ->
`waitingToRetry` -> `enqueued` -> `running` -> `complete` (if the second try succeeds, or more
retries if needed).  A `Request` will behave similarly, except it does not provide intermediate status updates.

Note that certain failures can be resumed, and retries will therefore attempt to resume from a failure instead of retrying the task from scratch.

## DownloadTask & UploadTask

### Requiring WiFi

On Android and iOS only: If the `requiresWiFi` field of a `Task` is set to true, the task won't start unless a WiFi network is available. By default `requiresWiFi` is false, and downloads/uploads will use the cellular (or metered) network if WiFi is not available, which may incur cost. Note that every task requires a working internet connection: local server connections that do not reach the internet may not work.

### Priority

The `priority` field must be 0 <= priority <= 10 with 0 being the highest priority, and defaults to 5. On Desktop and iOS all priority levels are supported. On Android, priority levels <5 are handled as 'expedited', and >=5 is handled as a normal task. If priority is set to 0, has an associated notification, and the task is on Android 14 (API 34) or above, the downloader will use the User Initiated Data Transfer (UIDT) service, which does not have a 9 minute timeout and is less likely to be killed by the OS.

To use the UIDT service on Android 14+, you must add the following to your `AndroidManifest.xml`:
* The `RUN_USER_INITIATED_JOBS` permission:
  ```xml
  <uses-permission android:name="android.permission.RUN_USER_INITIATED_JOBS" />
  ```
* The UIDT JobService declaration (within the `<application>` tag):
  ```xml
  <service
      android:name="com.bbflight.background_downloader.UIDTJobService"
      android:permission="android.permission.BIND_JOB_SERVICE"
      android:exported="true"
      android:foregroundServiceType="dataSync" />
  ```

### Metadata and displayName

`metaData` and `displayName` can be added to a `Task`. They are ignored by the downloader but may be helpful when receiving an update about the task, and can be shown in notifications using `{metaData}` or `{displayName}`.

## UploadTask

### File field

Set `fileField` to the field name the server expects for the file portion of a multi-part upload. Defaults to "file".

### Mime type

Set `mimeType` to the MIME type of the file to be uploaded. By default the MIME type is derived from the filename extension, e.g. a .txt file has MIME type `text/plain`.

### Form fields

Set `fields` to a `Map<String, String>` of name/value pairs to upload as "form fields" along with the file.
