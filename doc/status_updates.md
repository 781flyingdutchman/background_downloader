# Status and Progress Updates

As tasks are executed, they provide updates on their status and (optionally) progress. These updates are emitted via the `FileDownloader().updates` stream, or via callbacks if you registered them (see [Database & Central Monitoring](database.md)).

There are two types of updates:
*   `TaskStatusUpdate`
*   `TaskProgressUpdate`

Both classes extend `TaskUpdate` and contain a `task` field pointing to the original task.

## TaskStatusUpdate

A `TaskStatusUpdate` is generated when the state of a task changes. The `status` field contains a `TaskStatus` enum value.

### TaskStatus

The possible states of a task are:

*   **`enqueued`**: Task is enqueued on the native platform and waiting to start. It may wait for resources, or for an appropriate network to become available before starting the actual download and changing state to `running`.
*   **`running`**: Task is running, i.e. actively downloading/uploading.
*   **`complete`**: Task has completed successfully. This is a final state.
*   **`notFound`**: Task has completed because the url was not found (HTTP status code 404). This is a final state.
*   **`failed`**: Task has failed due to an exception (e.g., connection issue, insufficient space, or HTTP error other than 404). This is a final state.
*   **`canceled`**: Task has been canceled by the user or the system. This is a final state.
*   **`waitingToRetry`**: Task failed, and is now waiting to retry. The task is held in this state until the exponential backoff time for this retry has passed, and will then be rescheduled on the native platform, switching state to `enqueued` and then `running`.
*   **`paused`**: Task is in a paused state and may be able to resume.

### Additional Fields in TaskStatusUpdate

Depending on the `status`, a `TaskStatusUpdate` may contain additional fields that provide more information. Note that most of these fields are only populated when the task reaches a **final state** (such as `complete` or `failed`).

*   **`exception`**: If the task `failed`, this field contains a `TaskException` object with details about the error. Note that if the failure is due to an HTTP error (e.g., a 401 Unauthorized or 403 Forbidden), this will be a `TaskHttpException` which has an `httpResponseCode` field.
*   **`responseStatusCode`**: The HTTP status code returned by the server upon **successful** completion (or when skipped due to existing files returning 304). *Important: This field is only populated for successful responses. For error responses like 401, this field is not set. You must inspect `exception.httpResponseCode` instead (as described above).*
*   **`responseHeaders`**: A Map of the HTTP headers returned by the server. Note that header names are converted to lowercase.
*   **`responseBody`**: The body of the HTTP response as a String. This is primarily useful for `DataTask` requests, or if the server returns error details in the body.
*   **`mimeType`**: The MIME type of the downloaded file, derived from the `Content-Type` header (if available).
*   **`charSet`**: The character set of the response, derived from the `Content-Type` header (if available).

### Example: Handling HTTP Errors

If you need to handle specific HTTP errors (like 401 Unauthorized), you must check the `exception` field when the task fails:

```dart
void myStatusCallback(TaskStatusUpdate update) {
  if (update.status == TaskStatus.failed) {
    if (update.exception is TaskHttpException) {
      final httpException = update.exception as TaskHttpException;
      if (httpException.httpResponseCode == 401) {
        // Handle unauthorized error (e.g., refresh token)
      }
    } else {
      // Handle other types of exceptions (connection error, filesystem error, etc.)
    }
  } else if (update.status == TaskStatus.complete) {
      print('Success! Status code: ${update.responseStatusCode}');
  }
}
```

## TaskProgressUpdate

If you request progress updates (by setting `updates` in your `Task` to `Updates.progress` or `Updates.statusAndProgress`), the downloader will emit `TaskProgressUpdate` objects as the task proceeds.

### TaskProgressUpdate Fields

*   **`progress`**: A `double` value indicating the current progress. During normal execution (`running`), this value will be between 0.0 and 1.0 (meaning 0% to 100%). A successfully completed task will always finish with a progress of 1.0.
*   **`expectedFileSize`**: The total size of the file in bytes, as reported by the server via the `Content-Length` header.
*   **`networkSpeed`**: The current download/upload speed in MB/s.
*   **`timeRemaining`**: A `Duration` object estimating the time left to complete the task.

### Missing Content-Length

If the server does not supply a `Content-Length` header, or provides an invalid one, the downloader cannot determine the total file size. In this situation:
*   Progress updates will not be emitted continuously, because a percentage cannot be calculated.
*   `expectedFileSize` will be `-1`.
*   `networkSpeed` will be `-1`.
*   `timeRemaining` will be `-1` second.

You can use the getters `hasExpectedFileSize`, `hasNetworkSpeed`, and `hasTimeRemaining` on the `TaskProgressUpdate` object to check if these fields contain valid data.

### Progress Values for Status States

In addition to normal percentage values (0.0 to 1.0), the `progress` field can also hold special negative values that map to specific final task states. These are useful if you are driving a UI progress bar directly from progress updates.

*   `progressComplete` (1.0): Task is `complete`
*   `progressRunning` (0.0): Task is `running`
*   `progressFailed` (-1.0): Task `failed`
*   `progressCanceled` (-2.0): Task was `canceled`
*   `progressNotFound` (-3.0): Task was `notFound`
*   `progressWaitingToRetry` (-4.0): Task is `waitingToRetry`
*   `progressPaused` (-5.0): Task is `paused`

For example, if you receive a `TaskProgressUpdate` with a `progress` of `-1.0` (`progressFailed`), you know the task has failed, and the UI can reflect an error state on the progress bar.
