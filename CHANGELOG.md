## 1.4.2

Added note to README referring to an issue (and [fix](https://github.com/firebase/flutterfire/issues/9689#issuecomment-1304491789)) where the firebase plugin interferes with the downloader 

## 1.4.1

Improved example app, updated documentation and fixed minor Android bug

## 1.4.0

Added `downloadBatch` method to enqueue and wait for completion of a batch of downloads

## 1.3.0

Added option to use an event listener instead of (or in addition to) callbacks

## 1.2.0

Added FileDownloader.download as a convenience method for simple downloads. This method's Future completes only after the download has completed or failed, and can be used for simple downloads where status and progress checking is not required.

## 1.1.0

Added headers and metaData fields to the BackgroundDownloadTask. Headers will be added to the request, and metaData is ignored but may be helpful to the user

## 1.0.2

Replaced Ktor client with a basic Kotlin implementation


## 1.0.0

Initial release
