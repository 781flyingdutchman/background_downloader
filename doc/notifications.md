# Notifications

On iOS and Android, for downloads and uploads, the downloader can generate notifications to keep the user informed of progress also when the app is in the background, and allow pause/resume and cancellation of an ongoing download from those notifications.

Configure notifications by calling `FileDownloader().configureNotification` and supply a
`TaskNotification` object for different states. For example, the following configures
notifications to show only when actively running (i.e. download in progress), disappearing when
the download completes or ends with an error. It will also show a progress bar and a 'cancel'
button, and will substitute {filename} with the actual filename of the file being downloaded.
```dart
FileDownloader().configureNotification(
    running: TaskNotification('Downloading', 'file: {filename}'),
    progressBar: true);
```

To also show a notifications for other states, add a `TaskNotification` for `complete`, `error`, `paused` and/or `canceled`. If `paused` is configured and the task can be paused, a 'Pause' button will
show for the `running` notification, next to the 'Cancel' button. To open the downloaded file
when the user taps the `complete` notification, add `tapOpensFile: true` to your call to
`configureNotification`

There are four possible substitutions of the text in the `title` or `body` of a `TaskNotification`:
* {filename} is replaced with the `filename` field of the `Task`
* {displayName} is replaced with the `displayName` field of the `Task`
* {progress} is substituted by a progress percentage, or '--%' if progress is unknown
* {metadata} is substituted by the `metaData` field of the `Task`

Notifications on iOS follow Apple's [guidelines](https://developer.apple.com/design/human-interface-guidelines/components/system-experiences/notifications/), notably:
* No progress bar is shown, and the {progress} substitution always substitutes to an empty string. In other words: only a single `running` notification is shown and it is not updated until the download/upload state changes
* When the app is in the foreground, on iOS 14 and above the notification will not be shown but will appear in the NotificationCenter. On older iOS versions the notification will be shown also in the foreground. Apple suggests showing progress and download/upload controls within the app when it is in the foreground

No notifications will be generated:
* On desktop platforms, as there is no true background mode, and progress updates and indicators can be shown within the app
* For a `DataTask`, as those are meant for short data exchanges

The `configureNotification` call configures notification behavior for all tasks. You can specify a separate configuration for a `group` of tasks by calling `configureNotificationForGroup` and for a single task by calling `configureNotificationForTask`. A `Task` configuration overrides a `group` configuration, which overrides the default configuration.

Make sure to check for, and if necessary request, permission to display notifications - see [permissions](permissions.md). For Android, starting with API 33, you need to add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` to your app's `AndroidManifest.xml`. Also on Android you can localize the button text by overriding string resources `bg_downloader_cancel`, `bg_downloader_pause`, `bg_downloader_resume` and descriptions `bg_downloader_notification_channel_name`, `bg_downloader_notification_channel_description`. Localization on iOS can be done through [configuration](CONFIG.md).

## Grouping notifications

If you download or upload multiple files simultaneously, you may not want a notification for every task, but one notification representing the group of tasks.  To do this, set the `groupNotificationId` field in a `notificationConfig` and use that configuration for all tasks in this group. It is easiest to combine this with the `group` field of the task, e.g.:
```dart
FileDownloader().configureNotificationForGroup('bunchOfFiles', // refers to the Task.group field
            running: const TaskNotification(
                '{numFinished} out of {numTotal}', 'Progress = {progress}'),
            complete:
                const TaskNotification('Done!', 'Loaded {numTotal} files'),
            error: const TaskNotification(
                'Error', '{numFailed}/{numTotal} failed'),
            progressBar: true,
            groupNotificationId: 'myGroupNotification'); // unique ID for notification group
            
// start every task like this
await FileDownloader().enqueue(DownloadTask(
            url: 'https://your_url.com',
            filename: 'your_filename',
            group: 'bunchOfFiles'));
```

All tasks in group `bunchOfFiles` will now use the notification group configuration with ID `myNotificationGroup`. Any other task that uses a configuration with `groupNotificationId` set to 'myGroupNotification' will also be added to that group notification. Notification tap detection is not implemented for notification groups.

__On iOS__: If your `running` group notification contains a dynamic item (such as `{numFinished}` in the example above) then a new notification will be issued every time the notification message changes (different from Android, where the existing notification is updated so does not trigger a new one).

## Tapping a notification
To respond to the user tapping a notification, register a callback that takes `Task` and `NotificationType` as parameters:

```dart
FileDownloader().registerCallbacks(
  taskNotificationTapCallback: myNotificationTapCallback);

void myNotificationTapCallback(Task task, NotificationType notificationType) {
  print('Tapped notification $notificationType for taskId ${task.taskId}');
}
```

## Opening a downloaded file

To open a file (e.g. in response to the user tapping a notification), call `FileDownloader().openFile` and supply either a `Task` or a full `filePath` (but not both) and optionally a `mimeType` to assist the Platform in choosing the right application to use to open the file.
The file opening behavior is platform dependent, and while you should check the return value of the call to `openFile`, error checking is not fully consistent.

Note that on Android, files stored in the `BaseDirectory.applicationDocuments` cannot be opened. You need to download to a different base directory (e.g. `.applicationSupport`) or move the file to shared storage before attempting to open it.

If all you want to do on notification tap is to open the file, you can simplify the process by
adding `tapOpensFile: true` to your call to `configureNotifications`, and you don't need to
register a `taskNotificationTapCallback`.


## Setup for notifications

__On iOS__: Add the following to your `AppDelegate.swift`:
```swift
UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
```
or if using Objective C, add to `AppDelegate.m`:
```objective-c
[UNUserNotificationCenter currentNotificationCenter].delegate = (id<UNUserNotificationCenterDelegate>) self;
```

__On Android__: Starting with API 33, you need to add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` to your app's `AndroidManifest.xml`

If needed, localize the button text by overriding string resources `bg_downloader_cancel`, `bg_downloader_pause`, `bg_downloader_resume` and descriptions `bg_downloader_notification_channel_name`, `bg_downloader_notification_channel_description`. Optionally, supply your own notification icons by creating a version of the icons defined in `android/src/main/res/drawable`, e.g. `outline_download_done_24.xml`, and add those to your own app's `android/src/main/res/drawable` under the same name.
