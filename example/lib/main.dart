import 'dart:async';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
// ignore: unused_import
import 'package:background_downloader_example/sqlite_storage.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

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
  StreamController<TaskProgressUpdate> progressUpdateStream =
      StreamController();

  bool loadAndOpenInProgress = false;
  bool loadABunchInProgress = false;

  @override
  void initState() {
    super.initState();
    // By default the downloader uses a modified version of the Localstore package
    // to persistently store data. You can provide an alternative persistent
    // storage backing that implements the [PersistentStorage] interface. You
    // must initialize the FileDownloader by passing that alternative storage
    // object on the first call to FileDownloader.
    // As an example, this example app has implemented a backing using
    // the sqflite package (works for Android/iOS only and isn't production
    // ready -> only use as an example).
    // To try that, uncomment the following line, which
    // will initialize the downloader with that storage solution.
    // FileDownloader(persistentStorage: SqlitePersistentStorage());

    // Configure the downloader by registering a callback and configuring
    // notifications
    FileDownloader()
        .registerCallbacks(
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

    // Listen to updates and process
    FileDownloader().updates.listen((update) {
      switch (update) {
        case TaskStatusUpdate _:
          if (update.task == backgroundDownloadTask) {
            buttonState = switch (update.status) {
              TaskStatus.running || TaskStatus.enqueued => ButtonState.pause,
              TaskStatus.paused => ButtonState.resume,
              _ => ButtonState.reset
            };
            setState(() {
              downloadTaskStatus = update.status;
            });
          }

        case TaskProgressUpdate _:
          progressUpdateStream.add(update); // pass on to widget for indicator
      }
    });
  }

  /// Process the user tapping on a notification by printing a message
  void myNotificationTapCallback(Task task, NotificationType notificationType) {
    debugPrint(
        'Tapped notification $notificationType for taskId ${task.taskId}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
                              style: Theme.of(context).textTheme.titleLarge)),
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
                const Divider(
                  height: 30,
                  thickness: 5,
                  color: Colors.grey,
                ),
                Center(
                    child: ElevatedButton(
                        onPressed:
                            loadAndOpenInProgress ? null : processLoadAndOpen,
                        child: Text(
                          'Load & Open',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(color: Colors.white),
                        ))),
                Center(
                    child: Text(
                  loadAndOpenInProgress ? 'Busy' : '',
                  style: Theme.of(context).textTheme.headlineSmall,
                )),
                const Divider(
                  height: 30,
                  thickness: 5,
                  color: Colors.grey,
                ),
                Center(
                    child: ElevatedButton(
                        onPressed:
                            loadABunchInProgress ? null : processLoadABunch,
                        child: Text(
                          'Load a bunch',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(color: Colors.white),
                        ))),
                Center(
                    child: Text(
                  loadABunchInProgress ? 'Enqueueing' : '',
                  style: Theme.of(context).textTheme.headlineSmall,
                )),
              ],
            ),
          )),
          bottomSheet: DownloadProgressIndicator(progressUpdateStream.stream,
              showPauseButton: true,
              showCancelButton: true,
              backgroundColor: Colors.grey,
              maxExpandable: 3)),
    );
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

  Future<void> processLoadABunch() async {
    if (!loadABunchInProgress) {
      setState(() {
        loadABunchInProgress = true;
      });
      for (var i = 0; i < 5; i++) {
        await FileDownloader().enqueue(DownloadTask(
            url:
                'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
            filename: 'File_${Random().nextInt(1000)}',
            updates: Updates.progress)); // must provide progress updates!
        await Future.delayed(const Duration(milliseconds: 500));
      }
      setState(() {
        loadABunchInProgress = false;
      });
    }
  }
}

enum ButtonState { download, cancel, pause, resume, reset }
