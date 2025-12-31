# Downloads

## DownloadTask

The `DownloadTask` is the workhorse of this package. It defines what to download, from where, and where to store it.

```dart
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
```

The simplest way to execute a task is to call `.download` which returns a `Future` that completes when the task finishes (or fails).

```dart
final result = await FileDownloader().download(task);
```

For more complex scenarios, or when you have many tasks, use `.enqueue` (or `.enqueueAll`) and an event listener or callbacks - see [Database & Monitoring](database.md).

## Parallel downloads

Some servers may offer an option to download part of the same file from multiple URLs or have multiple parallel downloads of part of a large file using a single URL. This can speed up the download of large files.  To do this, create a `ParallelDownloadTask` instead of a regular `DownloadTask` and specify `chunks` (the number of pieces you want to break the file into, i.e. the number of downloads that will happen in parallel) and `urls` (as a list of URLs, or just one). For example, if you specify 4 chunks and 2 URLs, then the download will be broken into 8 pieces, four each for each URL.

```dart
final task = ParallelDownloadTask(
    urls: [
        'https://example.com/large_file.zip',
        'https://mirror.com/large_file.zip'
    ],
    chunks: 4,
    filename: 'large_file.zip');

final result = await FileDownloader().download(task);
```

Note that the implementation of this feature creates a regular `DownloadTask` for each chunk, with the group name 'chunk' which is now a reserved group. You will not get updates for this group, but you will get normal updates (status and/or progress) for the `ParallelDownloadTask`.

Parallel downloads do not support the use of URIs, and on Android the chunk downloads do not support the User Initiated Download Transfer service (so you must keep the chunks small enough that they do not exceed the 9 minute limit).

## Server suggested filenames

If you want the filename to be provided by the server (via the `Content-Disposition` header), you can use `DownloadTask.suggestedFilename`.

```dart
final task = DownloadTask(
    url: 'https://google.com',
    filename: DownloadTask.suggestedFilename);
```

In this case, the `Task` that is returned by the `download` method (or matches the status update) will have the correct filename, but the original task object you created will still have `DownloadTask.suggestedFilename` (which is `?`) as the filename.

Alternatively, you can call `withSuggestedFilename` on the task before downloading:

```dart
final task = await DownloadTask(url: 'https://google.com')
        .withSuggestedFilename(unique: true);
```

This will check the headers and return a new task with the filename set. If `unique` is true, it will append a counter to the filename if the file already exists.

