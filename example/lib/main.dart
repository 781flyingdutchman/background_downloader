import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader_example/isolate.dart';
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
  bool loadBackgroundInProgress = false;
  String? loadBackgroundResult;

  @override
  void initState() {
    super.initState();
    // By default the downloader uses a modified version of the Localstore package
    // to persistently store data. You can provide an alternative persistent
    // storage backing that implements the [PersistentStorage] interface. You
    // must initialize the FileDownloader by passing that alternative storage
    // object on the first call to FileDownloader.
    // For example, add a dependency for background_downloader_sql to
    // pubspec.yaml which adds [SqlitePersistentStorage].
    // To try that SQLite version, uncomment the following line, which
    // will initialize the downloader with the SQLite storage solution.
    // FileDownloader(persistentStorage: SqlitePersistentStorage());

    // optional: configure the downloader with platform specific settings,
    // see CONFIG.md - some examples shown here
    FileDownloader().configure(globalConfig: [
      (Config.requestTimeout, const Duration(seconds: 100)),
    ], androidConfig: [
      (Config.useCacheDir, Config.whenAble),
    ], iOSConfig: [
      (Config.localize, {'Cancel': 'StopIt'}),
    ]).then((result) => debugPrint('Configuration result = $result'));

    // Registering a callback and configure notifications
    FileDownloader()
        .registerCallbacks(
            taskNotificationTapCallback: myNotificationTapCallback)
        .configureNotificationForGroup(FileDownloader.defaultGroup,
            // For the main download button
            // which uses 'enqueue' and a default group
            running: const TaskNotification('Download {filename}',
                'File: {filename} - {progress} - speed {networkSpeed} and {timeRemaining} remaining'),
            complete: const TaskNotification(
                '{displayName} download {filename}', 'Download complete'),
            error: const TaskNotification(
                'Download {filename}', 'Download failed'),
            paused: const TaskNotification(
                'Download {filename}', 'Paused with metadata {metadata}'),
            progressBar: true)
        .configureNotificationForGroup('bunch',
            running: const TaskNotification(
                '{numFinished} out of {numTotal}', 'Progress = {progress}'),
            complete:
                const TaskNotification("Done!", "Loaded {numTotal} files"),
            error: const TaskNotification(
                'Error', '{numFailed}/{numTotal} failed'),
            progressBar: false,
            groupNotificationId: 'notGroup')
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
        case TaskStatusUpdate():
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

        case TaskProgressUpdate():
          progressUpdateStream.add(update); // pass on to widget for indicator
      }
    });
    // Start the FileDownloader. Default start means database tracking and
    // proper handling of events that happened while the app was suspended,
    // and rescheduling of tasks that were killed by the user.
    // Start behavior can be configured with parameters
    FileDownloader().start();
  }

  /// Process the user tapping on a notification by printing a message
  void myNotificationTapCallback(Task task, NotificationType notificationType) {
    debugPrint(
        'Tapped notification $notificationType for taskId ${task.taskId}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,

        // Define the default brightness and colors.
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.purple,
          brightness: Brightness.light,
        ),
      ),
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
                  child: Column(
                    children: [
                      Text('RequireWiFi setting',
                          style: Theme.of(context).textTheme.titleLarge),
                      const RequireWiFiChoice(),
                    ],
                  ),
                ),
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
                  color: Colors.blueGrey,
                ),
                Center(
                    child: ElevatedButton(
                        onPressed:
                            loadAndOpenInProgress ? null : processLoadAndOpen,
                        child: Text(
                          Platform.isIOS
                              ? 'Load, open and add'
                              : Platform.isAndroid
                                  ? 'Load, open and move'
                                  : 'Load & Open',
                        ))),
                Center(
                    child: Text(
                  loadAndOpenInProgress ? 'Busy' : '',
                )),
                const Divider(
                  height: 30,
                  thickness: 5,
                  color: Colors.blueGrey,
                ),
                Center(
                    child: ElevatedButton(
                        onPressed:
                            loadABunchInProgress ? null : processLoadABunch,
                        child: const Text('Load a bunch'))),
                Center(child: Text(loadABunchInProgress ? 'Enqueueing' : '')),
                const Divider(
                  height: 30,
                  thickness: 5,
                  color: Colors.blueGrey,
                ),
                Center(
                  child: ElevatedButton(
                    onPressed:
                        loadBackgroundInProgress ? null : processLoadBackground,
                    child: const Text(
                      'Load in background',
                    ),
                  ),
                ),
                Center(
                  child: Text(
                    loadBackgroundInProgress
                        ? 'Working...'
                        : loadBackgroundResult ?? '',
                  ),
                ),
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
        await getPermission(PermissionType.notifications);
        backgroundDownloadTask = DownloadTask(
            url: downloadWithError
                ? 'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/get_current_app_data' // returns 403 status code
                : 'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
            filename: 'zipfile.zip',
            directory: 'my/directory',
            baseDirectory: BaseDirectory.applicationDocuments,
            updates: Updates.statusAndProgress,
            retries: 3,
            allowPause: true,
            metaData: '<example metaData>',
            displayName: 'My display name');
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
      await getPermission(PermissionType.notifications);
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
      if (Platform.isIOS) {
        // add to photos library and print path
        // If you need the path, ask full permissions beforehand by calling
        var auth = await FileDownloader()
            .permissions
            .status(PermissionType.iosChangePhotoLibrary);
        if (auth != PermissionStatus.granted) {
          auth = await FileDownloader()
              .permissions
              .request(PermissionType.iosChangePhotoLibrary);
        }
        if (auth == PermissionStatus.granted) {
          final identifier = await FileDownloader()
              .moveToSharedStorage(task, SharedStorage.images);
          if (identifier != null) {
            final path = await FileDownloader()
                .pathInSharedStorage(identifier, SharedStorage.images);
            debugPrint(
                'iOS path to dog picture in Photos Library = ${path ?? "permission denied"}');
          } else {
            debugPrint(
                'Could not add file to Photos Library, likely because permission denied');
          }
        } else {
          debugPrint('iOS Photo Library permission not granted');
        }
      }
      if (Platform.isAndroid) {
        // on Android we move, not add, so we first wat for the
        // openFile method to complete
        await Future.delayed(const Duration(seconds: 3));
        var auth = await FileDownloader()
            .permissions
            .status(PermissionType.androidSharedStorage);
        if (auth != PermissionStatus.granted) {
          auth = await FileDownloader()
              .permissions
              .request(PermissionType.androidSharedStorage);
        }
        if (auth == PermissionStatus.granted) {
          final path = await FileDownloader()
              .moveToSharedStorage(task, SharedStorage.images);
          debugPrint(
              'Android path to dog picture in .images = ${path ?? "permission denied"}');
        } else {
          debugPrint('androidSharedStorage permission not granted');
        }
      }
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
      await getPermission(PermissionType.notifications);
      for (var i = 0; i < 5; i++) {
        await FileDownloader().enqueue(DownloadTask(
            url:
                'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
            filename: 'File_${Random().nextInt(1000)}',
            group: 'bunch',
            updates: Updates.progress)); // must provide progress updates!
        await Future.delayed(const Duration(milliseconds: 500));
      }
      setState(() {
        loadABunchInProgress = false;
      });
    }
  }

  Future<void> processLoadBackground() async {
    if (!loadBackgroundInProgress) {
      setState(() {
        loadBackgroundInProgress = true;
      });
      await getPermission(PermissionType.notifications);
      final result = await testBackgroundUsage();
      setState(() {
        loadBackgroundResult = result;
        loadBackgroundInProgress = false;
      });
    }
  }

  /// Attempt to get permissions if not already granted
  Future<void> getPermission(PermissionType permissionType) async {
    var status = await FileDownloader().permissions.status(permissionType);
    if (status != PermissionStatus.granted) {
      if (await FileDownloader()
          .permissions
          .shouldShowRationale(permissionType)) {
        debugPrint('Showing some rationale');
      }
      status = await FileDownloader().permissions.request(permissionType);
      debugPrint('Permission for $permissionType was $status');
    }
  }
}

/// Segmented button with WiFi requirement states
class RequireWiFiChoice extends StatefulWidget {
  const RequireWiFiChoice({super.key});

  @override
  State<RequireWiFiChoice> createState() => _RequireWiFiChoiceState();
}

class _RequireWiFiChoiceState extends State<RequireWiFiChoice> {
  RequireWiFi requireWiFi = RequireWiFi.asSetByTask;

  @override
  void initState() {
    super.initState();
    FileDownloader().getRequireWiFiSetting().then((value) {
      setState(() {
        requireWiFi = value;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<RequireWiFi>(
      segments: const <ButtonSegment<RequireWiFi>>[
        ButtonSegment<RequireWiFi>(
            value: RequireWiFi.asSetByTask, label: Text('Task')),
        ButtonSegment<RequireWiFi>(
            value: RequireWiFi.forAllTasks, label: Text('All')),
        ButtonSegment<RequireWiFi>(
          value: RequireWiFi.forNoTasks,
          label: Text('None'),
        ),
      ],
      selected: <RequireWiFi>{requireWiFi},
      onSelectionChanged: (Set<RequireWiFi> newSelection) {
        setState(() {
          // By default there is only a single segment that can be
          // selected at one time, so its value is always the first
          // item in the selected set.
          requireWiFi = newSelection.first;
          unawaited(FileDownloader()
              .requireWiFi(requireWiFi, rescheduleRunningTasks: true));
        });
      },
    );
  }
}

enum ButtonState { download, cancel, pause, resume, reset }
