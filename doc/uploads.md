# Uploads

Uploads are very similar to downloads, except:
* define an `UploadTask` object instead of a `DownloadTask`
* the file location now refers to the file you want to upload
* call `upload` instead of `download`, or `uploadBatch` instead of `downloadBatch`

There are two ways to upload a file to a server: binary upload (where the file is included in the POST body) and form/multi-part upload. Which type of upload is appropriate depends on the server you are uploading to. The upload will be done using the binary upload method only if you have set the `post` field of the `UploadTask` to 'binary'.

For binary uploads, the `Content-Disposition` header sent to the server will be:
- set to 'attachment = "filename"' if the task.headers field does not contain an entry for 'Content-Disposition' (with 'filename' replaced by the actual filename)
- not set at all (i.e. omitted) if the task.headers field contains an entry for 'Content-Disposition' with the value '' (an empty string)
- set to the value of `task.headers['Content-Disposition']` in all other cases

## Single file upload

If you already have a `File` object, you can create your `UploadTask` using `UploadTask.fromFile`, though note that this will create a task with an absolute path reference and `BaseDirectory.root`, which can cause problems on mobile platforms (absolute paths may change between app restarts). Preferably, use `Task.split` to break your `File` or filePath into appropriate baseDirectory, directory and filename and use that to create your `UploadTask`.

For multi-part uploads you can specify name/value pairs in the `fields` property of the `UploadTask` as a `Map<String, String>`. These will be uploaded as form fields along with the file. To specify multiple values for a single name, format the value as `'"value1", "value2", "value3"'` (note the double quotes and the comma to separate the values).

You can also set the field name used for the file itself by setting `fileField` (default is "file") and override the mimeType by setting `mimeType` (default is derived from filename extension).

## Multiple file upload

If you need to upload multiple files in a single request, create a [MultiUploadTask](https://pub.dev/documentation/background_downloader/latest/background_downloader/MultiUploadTask-class.html) instead of an `UploadTask`. It has similar parameters as the `UploadTask`, except you specify a list of files to upload as the `files` argument of the constructor, and do not use `fileName`, `fileField` and `mimeType`. Each element in the `files` list is either:
* a filename (e.g. `"file1.txt"`). The `fileField` for that file will be set to the base name (i.e. "file1" for "file1.txt") and the mime type will be derived from the extension (i.e. "text/plain" for "file1.txt")
* a record containing `(fileField, filename)`, e.g. `("document", "file1.txt")`. The `fileField` for that file will be set to "document" and the mime type derived from the file extension (i.e. "text/plain" for "file1.txt")
* a record containing `(filefield, filename, mimeType)`, e.g. `("document", "file1.txt", "text/plain")`

The `baseDirectory` and `directory` fields of the `MultiUploadTask` determine the expected location of the file referenced, unless the filename used in any of the 3 formats above is an absolute path (e.g. "/data/user/0/com.my_app/file1.txt"). In that case, the absolute path is used and the `baseDirectory` and `directory` fields are ignored for that element of the list.

If you are using URIs to locate your files (see [working with URIs](URI.md)) then you can replace the `filename` with the Uri (as `Uri` type, not `String`) in each of the formats mentioned above.

Once the `MultiUpoadTask` is created, the fields `fileFields`, `filenames` and `mimeTypes` will contain the parsed items, and the fields `fileField`, `filename` and `mimeType` contain those lists encoded as a JSON string.

Use the `MultiTaskUpload` object in the `upload` and `enqueue` methods as you would a regular `UploadTask`.

For partial uploads, set the byte range by adding a "Range" header to your binary `UploadTask`, e.g. a value of "bytes=100-149" will upload 50 bytes starting at byte 100. You can omit the range end (but not the "-") to upload from the indicated start byte to the end of the file.  The "Range" header will not be passed on to the server. Note that on iOS an invalid range will cause enqueue to fail, whereas on Android and Desktop the task will fail when attempting to start.

## Code Examples

### Single File Upload (Binary)
To upload a file as a binary stream (POST body), set `post: 'binary'`.
```dart
final binaryTask = UploadTask(
    url: 'https://my.server.com/upload',
    filename: 'my_data.bin',
    baseDirectory: BaseDirectory.applicationDocuments,
    post: 'binary',
    updates: Updates.statusAndProgress
);
await FileDownloader().upload(binaryTask);
```

### Single File Upload (Multipart)
To upload a file as a multipart/form-data request, add `fields` and optionally set `fileField`.
```dart
final multipartTask = UploadTask(
    url: 'https://my.server.com/upload',
    filename: 'my_image.jpg',
    baseDirectory: BaseDirectory.applicationDocuments,
    fileField: 'image',
    fields: {'user_id': '12345', 'description': 'Vacation photo'},
    updates: Updates.statusAndProgress
);
await FileDownloader().upload(multipartTask);
```

### Uploading an Existing File
When uploading an existing file (e.g. from an image picker), use `Task.split` to ensure the file path is handled correctly across platform restarts (especially on iOS/Android).
```dart
// Assuming you have a filePath from a picker
final String filePath = '/path/to/my/file.txt';

// Split the path into baseDirectory, directory and filename
final (baseDir, directory, filename) = await Task.split(filePath: filePath);

final existingFileTask = UploadTask(
    url: 'https://my.server.com/upload',
    filename: filename,
    baseDirectory: baseDir,
    directory: directory,
    updates: Updates.statusAndProgress
);

await FileDownloader().upload(existingFileTask);
```

### Batch Upload
To upload multiple separate files in a batch (different from `MultiUploadTask` which uploads multiple files in a single request):
```dart
final tasks = [
    UploadTask(url: 'https://server.com/upload', filename: 'file1.txt'),
    UploadTask(url: 'https://server.com/upload', filename: 'file2.txt'),
    UploadTask(url: 'https://server.com/upload', filename: 'file3.txt')
];

// Monitor batch progress
await FileDownloader().uploadBatch(
    tasks,
    batchProgressCallback: (status, progress) => print('Batch progress: $progress')
);
```

### iOS Background Setup
To ensure background uploads work correctly on iOS:
1.  **Capabilities**: Enable "Background Modes" -> "Background Fetch" in Xcode.
2.  **Safe File Locations**: Ensure files are located in safe directories like `BaseDirectory.applicationDocuments` or `BaseDirectory.temporary`. Avoid using absolute paths (`BaseDirectory.root`) unless necessary, as these paths can change between app restarts. Using `Task.split` as shown above helps manage this automatically.
