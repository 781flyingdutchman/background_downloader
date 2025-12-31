# Topic Index

Use this index to find documentation for specific topics and keywords.

## A
*   **Absolute path**: [File Storage & Locations](storage.md#specifying-the-location-of-the-file) - why to avoid them on mobile
*   **Authentication**: [Callbacks & Auth](lifecycle.md#authentication-and-pre--and-post-execution-callbacks) - managing tokens and auth headers

## B
*   **Background execution**: [README](../README.md#a-background-file-downloader-and-uploader-for-ios-android-macos-windows-and-linux) - general introduction
*   **BaseDirectory**: [File Storage & Locations](storage.md#specifying-the-location-of-the-file) - choosing where to store files
*   **Batch**: [Downloads](downloads.md) - enqueueing multiple files (see `enqueueAll` in [Database & Monitoring](database.md))
*   **Bypassing permissions**: [Permissions](permissions.md#bypassing-permissions-on-ios) - for iOS compile time

## C
*   **Cache directory**: [Configuration](CONFIG.md#android-when-to-use-the-cache-directory) - correct usage on Android
*   **Cancel**: [Lifecycle](lifecycle.md#canceling-pausing-and-resuming-tasks) - canceling tasks
*   **Callbacks**: [Database & Monitoring](database.md#using-callbacks) - using callbacks for status updates
*   **Central monitoring**: [Database & Monitoring](database.md) - monitoring all tasks in one place
*   **Cleanup**: [Database & Monitoring](database.md#automated-database-cleanup) - managing database size
*   **Configuration**: [Configuration](CONFIG.md) - global settings
*   **Content-Disposition**: [Downloads](downloads.md#server-suggested-filenames) - using server suggested filenames
*   **Content URI**: [URIs](URI.md#android) - working with Android content providers
*   **Cookies**: [Requests](requests.md#cookies) - handling session cookies

## D
*   **Database**: [Database & Monitoring](database.md) - persistent task tracking
*   **DataTask**: [Requests](requests.md#datatask-scheduled-execution) - background server requests (no file)
*   **Debug**: [Configuration](CONFIG.md#android-desktop-bypassing-https-tls-certificate-validation) - bypassing TLS for local testing
*   **Directory**: [File Storage & Locations](storage.md) - specifying subdirectories
*   **DownloadTask**: [Downloads](downloads.md#downloadtask) - creating a download task

## E
*   **Enqueue**: [Database & Monitoring](database.md) - starting background tasks
*   **External storage**: [Configuration](CONFIG.md#android-use-external-storage) - using SD cards on Android

## F
*   **Filename**: [File Storage & Locations](storage.md) - naming your files
*   **File Picker**: [URIs](URI.md#key-concepts) - letting users choose files
*   **Foreground service**: [Configuration](CONFIG.md#android-run-task-in-foreground-removes-9-minute-timeout-and-may-improve-chances-of-task-surviving-background) - long running tasks on Android
*   **Form fields**: [Uploads](uploads.md#form-fields) - uploading data with files

## G
*   **Group**: [Lifecycle](lifecycle.md#grouping-tasks) - managing bunches of tasks together

## H
*   **Headers**: [Parameters](parameters.md#headers) - adding HTTP headers
*   **Holding Queue**: [Lifecycle](lifecycle.md#holding-queue) - limiting concurrency

## I
*   **iOS**: [README](../README.md#ios) - setup and info

## L
*   **Listeners**: [Database & Monitoring](database.md#using-an-event-listener) - streaming status updates
*   **Localization**: [Configuration](CONFIG.md#ios-localization) - translating notification buttons

## M
*   **Metadata**: [Parameters](parameters.md#metadata-and-displayname) - storing user data with tasks
*   **Mime type**: [Uploads](uploads.md#mime-type) - specifying file types
*   **Monitoring**: [Database & Monitoring](database.md) - tracking progress and status
*   **Multi-part upload**: [Uploads](uploads.md#multiple-file-upload) - uploading multiple files

## N
*   **Notifications**: [Notifications](notifications.md) - showing status to users

## O
*   **Open file**: [Notifications](notifications.md#opening-a-downloaded-file) - opening files on tap

## P
*   **Parallel downloads**: [Downloads](downloads.md#parallel-downloads) - chunked downloads
*   **Parameters**: [Parameters](parameters.md) - optional task settings
*   **Pause**: [Lifecycle](lifecycle.md#canceling-pausing-and-resuming-tasks) - pausing downloads
*   **Permissions**: [Permissions](permissions.md) - handling user permissions
*   **Pickers**: [URIs](URI.md) - file and directory pickers
*   **Post**: [Parameters](parameters.md#post-requests) - sending data with requests
*   **Priority**: [Parameters](parameters.md#priority) - task priority and UIDT
*   **Progress**: [Database & Monitoring](database.md) - tracking progress
*   **Proxy**: [Configuration](CONFIG.md#http-proxy) - setting a network proxy

## Q
*   **Queue**: [Lifecycle](lifecycle.md#managing-tasks-and-the-queue) - managing the task queue

## R
*   **Request**: [Requests](requests.md#server-requests) - simple HTTP requests
*   **Resume**: [Lifecycle](lifecycle.md#canceling-pausing-and-resuming-tasks) - resuming downloads
*   **Retries**: [Parameters](parameters.md#retries) - automatic retries

## S
*   **Shared storage**: [File Storage & Locations](storage.md#shared-and-scoped-storage) - Photos, Downloads, etc.
*   **Server suggested filename**: [Downloads](downloads.md#server-suggested-filenames) - using names from headers
*   **Start**: [Database & Monitoring](database.md#annotated-example-with-database) - initializing the downloader
*   **Storage**: [File Storage & Locations](storage.md) - where files go

## T
*   **Task**: [Downloads](downloads.md) - base object for all operations
*   **Timeout**: [Configuration](CONFIG.md#timeouts) - setting timeouts
*   **Tracking**: [Database & Monitoring](database.md) - tracking tasks
*   **TLS**: [Configuration](CONFIG.md#android-desktop-bypassing-https-tls-certificate-validation) - certificate validation

## U
*   **UIDT**: [Parameters](parameters.md#priority) - User Initiated Data Transfer (Android 14+)
*   **UploadTask**: [Uploads](uploads.md) - creating an upload task
*   **URI**: [URIs](URI.md) - working with URIs instead of files

## W
*   **WiFi**: [Parameters](parameters.md#requiring-wifi) - restricting to WiFi
