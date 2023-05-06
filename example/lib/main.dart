import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

import 'widgets.dart';

void main() {
  Logger.root.onRecord.listen((LogRecord rec) {
    debugPrint(
        '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final log = Logger('ExampleApp');
  final buttonTexts = ['Download', 'Cancel', 'Pause', 'Resume', 'Reset'];

  ButtonState buttonState = ButtonState.download;
  bool downloadWithError = false;
  TaskStatus? downloadTaskStatus;
  DownloadTask? backgroundDownloadTask;
  StreamController<DownloadProgressIndicatorUpdate> updateStream =
      StreamController();

  // for the 'Load & Open' button
  bool loadAndOpenInProgress = false;

  @override
  void initState() {
    super.initState();
    FileDownloader()
        .registerCallbacks(
            taskStatusCallback: myDownloadStatusCallback,
            taskProgressCallback: myDownloadProgressCallback,
            taskNotificationTapCallback: myNotificationTapCallback)
        .configureNotificationForGroup(FileDownloader.defaultGroup,
            // For the main download button
            // which uses 'enqueue' and a default group
            running: const TaskNotification(
                'Download {filename}', 'File: {filename} - {progress}'),
            complete: const TaskNotification(
                'Download {filename}', 'Download complete'),
            error: const TaskNotification(
                'Download {filename}', 'Download failed'),
            paused: const TaskNotification(
                'Download {filename}', 'Paused with metadata {metadata}'),
            progressBar: true)
        .configureNotification(
            // for the 'Download & Open' dog picture
            // which uses 'download' which is not the .defaultGroup
            // but the .await group so won't use the above config
            complete: const TaskNotification(
                'Download {filename}', 'Download complete'),
            tapOpensFile: true); // dog can also open directly from tap
  }

  /// Process the status updates coming from the downloader
  ///
  /// Stores the task status
  void myDownloadStatusCallback(TaskStatusUpdate update) {
    if (update.task == backgroundDownloadTask) {
      switch (update.status) {
        case TaskStatus.enqueued:
        case TaskStatus.notFound:
        case TaskStatus.failed:
        case TaskStatus.canceled:
        case TaskStatus.waitingToRetry:
          buttonState = ButtonState.reset;
          break;
        case TaskStatus.running:
          buttonState = ButtonState.pause;
          break;
        case TaskStatus.complete:
          buttonState = ButtonState.reset;
          break;
        case TaskStatus.paused:
          buttonState = ButtonState.resume;
          break;
      }
      setState(() {
        downloadTaskStatus = update.status;
      });
    }
  }

  /// Process the progress updates coming from the downloader
  ///
  /// Adds an update object to the stream that the main UI listens to
  void myDownloadProgressCallback(TaskProgressUpdate update) {
    updateStream.add(
        DownloadProgressIndicatorUpdate(update.task.filename, update.progress));
  }

  /// Process the user tapping on a notification by printing a message
  void myNotificationTapCallback(Task task, NotificationType notificationType) {
    debugPrint(
        'Tapped notification $notificationType for taskId ${task.taskId}');
  }

  @override
  Widget build(BuildContext context) {
    return StreamProvider<DownloadProgressIndicatorUpdate>.value(
        value: updateStream.stream,
        initialData: DownloadProgressIndicatorUpdate('', 1),
        child: MaterialApp(
          home: Scaffold(
              appBar: AppBar(
                title: const Text('background_downloader example app'),
              ),
              body: Center(
                  child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text('Force error',
                                  style:
                                      Theme.of(context).textTheme.titleLarge)),
                          Switch(
                              value: downloadWithError,
                              onChanged: (value) {
                                setState(() {
                                  downloadWithError = value;
                                });
                              })
                        ],
                      ),
                    ),
                    Center(
                        child: ElevatedButton(
                      onPressed: processButtonPress,
                      child: Text(
                        buttonTexts[buttonState.index],
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(color: Colors.white),
                      ),
                    )),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          const Expanded(child: Text('File download status:')),
                          Text('${downloadTaskStatus ?? "undefined"}')
                        ],
                      ),
                    ),
                    Center(
                        child: ElevatedButton(
                            onPressed: loadAndOpenInProgress
                                ? null
                                : processLoadAndOpen,
                            child: Text(
                              'Load & Open',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium
                                  ?.copyWith(color: Colors.white),
                            ))),
                    Center(
                        child: Text(
                      loadAndOpenInProgress ? 'Loading' : '',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ))
                  ],
                ),
              )),
              bottomSheet: const DownloadProgressIndicator()),
        ));
  }

  /// Process center button press (initially 'Download' but the text changes
  /// based on state)
  Future<void> processButtonPress() async {
    switch (buttonState) {
      case ButtonState.download:
        // start download
        backgroundDownloadTask = DownloadTask(
            url: downloadWithError
                ? 'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/get_current_app_data' // returns 403 status code
                : 'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
            filename: 'zipfile.zip',
            directory: 'my/directory',
            baseDirectory: BaseDirectory.applicationDocuments,
            updates: Updates.statusAndProgress,
            allowPause: true,
            metaData: '<example metaData>');
        await FileDownloader().enqueue(backgroundDownloadTask!);
        break;
      case ButtonState.cancel:
        // cancel download
        if (backgroundDownloadTask != null) {
          await FileDownloader()
              .cancelTasksWithIds([backgroundDownloadTask!.taskId]);
        }
        break;
      case ButtonState.reset:
        downloadTaskStatus = null;
        buttonState = ButtonState.download;
        break;
      case ButtonState.pause:
        if (backgroundDownloadTask != null) {
          await FileDownloader().pause(backgroundDownloadTask!);
        }
        break;
      case ButtonState.resume:
        if (backgroundDownloadTask != null) {
          await FileDownloader().resume(backgroundDownloadTask!);
        }
        break;
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Process 'Load & Open' button
  ///
  /// Loads a JPG of a dog and launches viewer using [openFile]
  Future<void> processLoadAndOpen() async {
    if (!loadAndOpenInProgress) {
      var task = DownloadTask(
          url:
              'https://i2.wp.com/www.skiptomylou.org/wp-content/uploads/2019/06/dog-drawing.jpg',
          baseDirectory: BaseDirectory.applicationSupport,
          filename: 'dog.jpg');
      setState(() {
        loadAndOpenInProgress = true;
      });
      await FileDownloader().download(task);
      await FileDownloader().openFile(task: task);
      setState(() {
        loadAndOpenInProgress = false;
      });
    }
  }
}

enum ButtonState { download, cancel, pause, resume, reset }
