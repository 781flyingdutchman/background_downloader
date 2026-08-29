# Uploads

Uploads are configured similarly to downloads, using `UploadTask` or `MultiUploadTask`.

Like downloads, you can track progress and status of uploads - see [Status & Progress Updates](status_updates.md) for details.

There are two ways to upload a file to a server:
1. **Binary upload**: The file is sent directly as the raw POST/PUT request body (e.g. for S3 pre-signed URLs or REST endpoints). Use `post: 'binary'` or `TransferHint.binaryUpload`.
2. **Multipart/form-data upload**: The default format, uploading files along with form `fields`.

---

## 1. High-Level Transfer API (Recommended)

The easiest way to execute an upload is using `FileDownloader().startTransfer`:

```dart
final task = UploadTask(
  url: 'https://example.com/api/upload',
  filename: 'photo.jpg',
  baseDirectory: BaseDirectory.applicationDocuments,
  fields: {'userId': '12345'},
);

final transfer = await FileDownloader().startTransfer(task);

// Await the server response body:
final response = await transfer.responseBody;
print('Server response: $response');
```

---

## 2. Binary Uploads (`TransferHint.binaryUpload`)

To upload raw file bytes in the HTTP request body (ideal for cloud storage pre-signed URLs):

```dart
final binaryTask = UploadTask(
  url: 'https://my-bucket.s3.amazonaws.com/uploads/data.bin',
  filename: 'data.bin',
  baseDirectory: BaseDirectory.applicationDocuments,
  transferHints: {TransferHint.binaryUpload}, // sets post: 'binary'
);

final transfer = await FileDownloader().startTransfer(binaryTask);
await transfer.result;
```

For binary uploads, the `Content-Disposition` header sent to the server will be:
- Set to `'attachment; filename="filename"'` if `task.headers` does not contain `'Content-Disposition'`
- Omitted entirely if `task.headers['Content-Disposition'] == ''`
- Set to `task.headers['Content-Disposition']` in all other cases

---

## 3. Multipart Form Uploads

For multi-part uploads, specify name/value pairs in the `fields` property as a `Map<String, String>`:

```dart
final multipartTask = UploadTask(
  url: 'https://example.com/upload',
  filename: 'avatar.png',
  baseDirectory: BaseDirectory.applicationDocuments,
  fileField: 'avatar', // defaults to 'file'
  fields: {'username': 'johndoe', 'role': 'user'},
);

final transfer = await FileDownloader().startTransfer(multipartTask);
final result = await transfer.result;
```

---

## 4. Uploading Multiple Files (`MultiUploadTask`)

To upload multiple files in a single multipart request:

```dart
final multiTask = MultiUploadTask(
  url: 'https://example.com/upload-all',
  baseDirectory: BaseDirectory.applicationDocuments,
  files: [
    'file1.txt',                            // fileField: file1, mimeType: derived
    ('doc', 'contract.pdf'),                // fileField: doc, mimeType: derived
    ('img', 'photo.jpg', 'image/jpeg'),     // fileField: img, mimeType: image/jpeg
  ],
  fields: {'user': 'myUser'},
);

final transfer = await FileDownloader().startTransfer(multiTask);
await transfer.result;
```

---

## 5. Batch Uploads (`startTransfers` / `uploadBatch`)

To upload multiple files as separate requests in a batch:

```dart
final tasks = [
  UploadTask(url: 'https://example.com/upload', filename: 'file1.txt'),
  UploadTask(url: 'https://example.com/upload', filename: 'file2.txt'),
  UploadTask(url: 'https://example.com/upload', filename: 'file3.txt'),
];

final transfers = await FileDownloader().startTransfers(
  tasks,
  onProgress: (succeeded, failed) => print('Progress: $succeeded succeeded, $failed failed'),
);
```
