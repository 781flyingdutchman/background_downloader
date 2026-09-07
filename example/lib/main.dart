import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

void main() {
  Logger.root.onRecord.listen((LogRecord rec) {
    debugPrint(
      '${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}',
    );
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

  bool downloadWithError = false;
  Transfer? mainTransfer;
  bool loadAndOpenInProgress = false;
  bool loadABunchInProgress = false;
  String batchProgressMessage = '';

  @override
  void initState() {
    super.initState();

    // ---------------------------------------------------------------------------
    // 1. Initializing and configuring FileDownloader
    // ---------------------------------------------------------------------------
    // By default the downloader uses Localstore to persistently store data.
    // You can provide an alternative persistent storage backing by initializing
    // FileDownloader(persistentStorage: SqlitePersistentStorage()).
    //
    // Configure global, Android, and iOS settings:
    FileDownloader()
        .configure(
          globalConfig: [(Config.requestTimeout, const Duration(seconds: 100))],
          androidConfig: [(Config.useCacheDir, Config.whenAble)],
          iOSConfig: [
            (Config.localize, {'Cancel': 'StopIt'}),
          ],
        )
        .then((result) => debugPrint('Configuration result = $result'));

    // Register callback for system notification taps & configure notification layouts.
    FileDownloader()
        .registerCallbacks(
          taskNotificationTapCallback: myNotificationTapCallback,
        )
        .configureNotificationForGroup(
          FileDownloader.defaultGroup,
          // Notifications for default group downloads
          running: const TaskNotification(
            'Download {filename}',
            'File: {filename} - {progress} - speed {networkSpeed} and {timeRemaining} remaining',
          ),
          complete: const TaskNotification(
            '{displayName} download {filename}',
            'Download complete',
          ),
          error: const TaskNotification(
            'Download {filename}',
            'Download failed',
          ),
          paused: const TaskNotification(
            'Download {filename}',
            'Paused with metadata {metadata}',
          ),
          canceled: const TaskNotification('Download {filename}', 'Canceled'),
          progressBar: true,
        )
        .configureNotificationForGroup(
          'bunch',
          // Notifications for batch downloads
          running: const TaskNotification(
            '{numFinished} out of {numTotal}',
            'Progress = {progress}',
          ),
          complete: const TaskNotification("Done!", "Loaded {numTotal} files"),
          error: const TaskNotification(
            'Error',
            '{numFailed}/{numTotal} failed',
          ),
          progressBar: false,
          groupNotificationId: 'notGroup',
        )
        .configureNotification(
          // For the 'Download & Open' dog picture
          complete: const TaskNotification(
            'Download {filename}',
            'Download complete',
          ),
          tapOpensFile: true,
        );

    // ---------------------------------------------------------------------------
    // 2. Startup Best Practice: Activating Tracking & Picking Up In-Progress Transfers
    // ---------------------------------------------------------------------------
    // Calling FileDownloader().start(autoCleanDatabase: true) enables persistent tracking,
    // automatically handles tasks completed while suspended, reschedules killed tasks,
    // and cleans up old completed records.
    _initDownloaderAndResumeTransfers();
  }

  /// Initializes the downloader and picks up any transfers that are still in progress
  /// from previous app sessions or system restarts.
  ///
  /// BEST PRACTICE:
  /// When your app starts up, there might be downloads or uploads that are still running
  /// in the background (or tasks that were paused/waiting).
  /// Calling `FileDownloader().start(autoCleanDatabase: true)` activates database tracking.
  /// Then, querying `database.allRecords()` allows you to call `transfers.getOrStart(record.task)`
  /// for any non-final tasks. This re-attaches a `Transfer` handle and automatically populates
  /// `FileDownloader().transfers.notifier` so your UI instantly reflects running transfers.
  Future<void> _initDownloaderAndResumeTransfers() async {
    // 1. Start downloader with autoCleanDatabase: true
    await FileDownloader().start(autoCleanDatabase: true);

    // 2. Query persistent database for active tasks from previous sessions
    final records = await FileDownloader().database.allRecords();
    for (final record in records) {
      if (record.status.isNotFinalState) {
        log.info('Found in-progress task on startup: ${record.taskId}');
        // getOrStart reconnects to the existing active task without duplicating it
        final transfer = await FileDownloader().transfers.getOrStart(
          record.task,
        );

        // If this matches our primary sample download, bind it to mainTransfer
        if (record.task.filename == 'zipfile.zip') {
          if (mounted) {
            setState(() {
              mainTransfer = transfer;
            });
          }
        }
      }
    }
  }

  /// Process the user tapping on a notification by printing a message
  void myNotificationTapCallback(Task task, NotificationType notificationType) {
    debugPrint(
      'Tapped notification $notificationType for taskId ${task.taskId}',
    );
  }

  /// Creates a sample DownloadTask.
  ///
  /// Demonstrates `TransferHint`s:
  /// - `TransferHint.userInitiated`: Sets priority 0, satisfying Android 14+ UIDT
  ///   requirements and iOS high priority, and enables `allowPause`.
  /// - `TransferHint.largeFile`: Ensures pause capability and handles long downloads.
  DownloadTask _createMainDownloadTask() => DownloadTask(
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
    displayName: '5MB Test Archive',
    transferHints: {TransferHint.userInitiated, TransferHint.largeFile},
  );

  /// Starts or reconnects to the main download transfer.
  ///
  /// EXPLANATION OF `getOrStart` vs `start`:
  /// - `getOrStart`: Recommended best practice for persistent or screen-bound transfers.
  ///   If a transfer for this task is already running or completed, it returns the existing
  ///   `Transfer` handle instead of scheduling a duplicate download.
  /// - `start`: Creates and enqueues a new transfer every time it is called.
  ///   Ideal for simple, short, or one-off transfers (like downloading a thumbnail or photo).
  Future<void> processMainTransfer({bool useGetOrStart = true}) async {
    await getPermission(PermissionType.notifications);
    final task = _createMainDownloadTask();

    final transfer = useGetOrStart
        ? await FileDownloader().transfers.getOrStart(task)
        : await FileDownloader().transfers.start(task);

    if (mounted) {
      setState(() {
        mainTransfer = transfer;
      });
    }

    log.info(
      'Main transfer initialized (${useGetOrStart ? "getOrStart" : "start"}): ${transfer.taskId}',
    );
  }

  /// Process 'Load & Open' button.
  ///
  /// Demonstrates:
  /// 1. For simple, short, one-off downloads, calling `transfers.start` is completely fine and concise.
  /// 2. The `await transfer.file` getter provides a clean `Future<File>` that completes when the
  ///    download is finished, eliminating the need for manual status polling or stream subscriptions.
  Future<void> processLoadAndOpen() async {
    if (loadAndOpenInProgress) return;
    setState(() {
      loadAndOpenInProgress = true;
    });

    try {
      await getPermission(PermissionType.notifications);
      final task = DownloadTask(
        url: 'https://i2.wp.com/www.skiptomylou.org/wp-content/uploads/2019/06/dog-drawing.jpg',
        baseDirectory: BaseDirectory.applicationSupport,
        filename: 'dog.jpg',
        displayName: 'Dog Drawing',
        transferHints: {TransferHint.userInitiated},
      );

      // For simple one-off downloads, start is ideal:
      final transfer = await FileDownloader().transfers.start(task);

      // Cleanly await the downloaded File handle upon completion:
      final file = await transfer.file;
      log.info('Downloaded image to: ${file.path}');

      // Open the downloaded file in the native file viewer:
      await FileDownloader().openFile(filePath: file.path);

      // On iOS: Add to Photos Library
      if (Platform.isIOS) {
        var auth = await FileDownloader().permissions.status(
          PermissionType.iosChangePhotoLibrary,
        );
        if (auth != PermissionStatus.granted) {
          auth = await FileDownloader().permissions.request(
            PermissionType.iosChangePhotoLibrary,
          );
        }
        if (auth == PermissionStatus.granted) {
          final identifier = await FileDownloader().moveToSharedStorage(
            task,
            SharedStorage.images,
          );
          if (identifier != null) {
            final path = await FileDownloader().pathInSharedStorage(
              identifier,
              SharedStorage.images,
            );
            debugPrint(
              'iOS path to dog picture in Photos Library = ${path ?? "permission denied"}',
            );
          }
        }
      }

      // On Android: Move to Shared Storage (.images)
      if (Platform.isAndroid) {
        await Future.delayed(const Duration(seconds: 3));
        var auth = await FileDownloader().permissions.status(
          PermissionType.androidSharedStorage,
        );
        if (auth != PermissionStatus.granted) {
          auth = await FileDownloader().permissions.request(
            PermissionType.androidSharedStorage,
          );
        }
        if (auth == PermissionStatus.granted) {
          final path = await FileDownloader().moveToSharedStorage(
            task,
            SharedStorage.images,
          );
          debugPrint(
            'Android path to dog picture in .images = ${path ?? "permission denied"}',
          );
        }
      }
    } catch (e) {
      log.warning('Load and open error: $e');
    } finally {
      if (mounted) {
        setState(() {
          loadAndOpenInProgress = false;
        });
      }
    }
  }

  /// Starts a batch of multiple transfers concurrently using `FileDownloader().transfers.startAll`.
  ///
  /// Demonstrates:
  /// - Starting multiple transfers in a single call with batch enqueuing (`startAll`).
  /// - Monitoring aggregate progress via `onProgress: (succeeded, failed)`.
  /// - Automatic registration of each transfer in `FileDownloader().transfers.notifier`.
  Future<void> processLoadABunch() async {
    if (loadABunchInProgress) return;
    setState(() {
      loadABunchInProgress = true;
      batchProgressMessage = 'Starting batch...';
    });

    await getPermission(PermissionType.notifications);

    final tasks = List.generate(
      5,
      (i) => DownloadTask(
        url: 'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
        filename: 'Batch_File_${Random().nextInt(1000)}.zip',
        group: 'bunch',
        displayName: 'Batch Item #${i + 1}',
        updates: Updates.statusAndProgress,
        allowPause: true,
      ),
    );

    final transfers = await FileDownloader().transfers.startAll(
      tasks,
      onProgress: (succeeded, failed) {
        if (mounted) {
          setState(() {
            batchProgressMessage =
                'Batch progress: $succeeded completed, $failed failed of ${tasks.length}';
          });
        }
      },
    );

    log.info('Started batch of ${transfers.length} transfers');

    if (mounted) {
      setState(() {
        loadABunchInProgress = false;
      });
    }
  }

  /// Process destination directory picker on mobile using UriDownloadTask and transfers.start.
  Future<void> processPickDirectory() async {
    final uri = await FileDownloader().uri.pickDirectory();
    if (uri == null) {
      log.warning('Could not get a URI');
      return;
    }
    log.fine('Uri = $uri');
    final task = UriDownloadTask(
      url: 'https://i2.wp.com/www.skiptomylou.org/wp-content/uploads/2019/06/dog-drawing.jpg',
      directoryUri: uri,
      filename: '?',
      displayName: 'URI Downloaded Dog',
    );
    final transfer = await FileDownloader().transfers.start(task);
    final result = await transfer.result;
    final resultTask = result.task as UriDownloadTask;
    log.info('Download to URI completed with taskStatus ${result.status}');
    log.info('Downloaded file is at ${resultTask.fileUri}');
    log.info('Downloaded file name is ${resultTask.filename}');
  }

  /// Attempt to get permissions if not already granted
  Future<void> getPermission(PermissionType permissionType) async {
    var status = await FileDownloader().permissions.status(permissionType);
    if (status != PermissionStatus.granted) {
      if (await FileDownloader().permissions.shouldShowRationale(
        permissionType,
      )) {
        debugPrint('Showing some rationale');
      }
      status = await FileDownloader().permissions.request(permissionType);
      debugPrint('Permission for $permissionType was $status');
    }
  }

  @override
  Widget build(BuildContext context) {
    final onMobile = Platform.isAndroid || Platform.isIOS;
    final theme = Theme.of(context);

    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('background_downloader example'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Reset and clear transfers',
              onPressed: () async {
                await FileDownloader().transfers.clear(cancelActive: true);
                await FileDownloader().reset();
                setState(() {
                  mainTransfer = null;
                  batchProgressMessage = '';
                });
              },
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---------------------------------------------------------------
              // SECTION 1: Settings & Options
              // ---------------------------------------------------------------
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Transfer Settings',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Expanded(child: Text('Require Wi-Fi:')),
                          const RequireWiFiChoice(),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Force error (test failure & retry UI):',
                            ),
                          ),
                          Switch(
                            value: downloadWithError,
                            onChanged: (value) {
                              setState(() {
                                downloadWithError = value;
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ---------------------------------------------------------------
              // SECTION 2: Main Transfer & Plug-and-Play Widgets
              // ---------------------------------------------------------------
              Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.downloading,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Main Transfer Demo',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Demonstrates reactive widgets (TransferListTile, TransferProgressBar, '
                        'TransferButton) and the transfers.getOrStart best practice.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // If mainTransfer is active or tracked, display it directly with TransferListTile
                      if (mainTransfer != null) ...[
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              // Plug-and-Play ListTile: Automatically manages progress bar,
                              // transfer speed, status badges, and pause/resume/retry buttons.
                              TransferListTile(
                                transfer: mainTransfer!,
                                showSpeed: true,
                                showPercentage: true,
                              ),

                              // Reactive helper to override Wi-Fi restriction if held
                              ValueListenableBuilder<TransferHoldReason>(
                                valueListenable:
                                    mainTransfer!.holdReasonNotifier,
                                builder: (context, holdReason, _) {
                                  if (holdReason ==
                                      TransferHoldReason.waitingForWiFi) {
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        left: 16.0,
                                        right: 16.0,
                                        bottom: 12.0,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.wifi_off,
                                            size: 18,
                                            color: Colors.orange.shade800,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Waiting for Wi-Fi',
                                              style: TextStyle(
                                                color: Colors.orange.shade800,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          OutlinedButton(
                                            onPressed: () {
                                              // Allow transfer over cellular
                                              mainTransfer!.allowCellular();
                                            },
                                            child: const Text('Allow Cellular'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('New Transfer (start)'),
                              onPressed: () =>
                                  processMainTransfer(useGetOrStart: false),
                            ),
                          ],
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.download),
                                label: const Text('Start (getOrStart)'),
                                onPressed: () =>
                                    processMainTransfer(useGetOrStart: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: () =>
                                  processMainTransfer(useGetOrStart: false),
                              child: const Text('start'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ---------------------------------------------------------------
              // SECTION 3: Other Transfer Flows (Load & Open, Batch, URI)
              // ---------------------------------------------------------------
              Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.auto_awesome,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Additional Transfer Workflows',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Workflow 1: Load & Open (await transfer.file)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          Platform.isIOS
                              ? 'Load, open & add to Photos'
                              : Platform.isAndroid
                              ? 'Load, open & move to Gallery'
                              : 'Load & Open Image',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Uses transfers.start and clean await transfer.file',
                        ),
                        trailing: ElevatedButton(
                          onPressed: loadAndOpenInProgress
                              ? null
                              : processLoadAndOpen,
                          child: loadAndOpenInProgress
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Run'),
                        ),
                      ),
                      const Divider(),

                      // Workflow 2: Batch Transfers (startAll)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Load a Bunch (Batch Transfers)',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          batchProgressMessage.isNotEmpty
                              ? batchProgressMessage
                              : 'Uses transfers.startAll with aggregate progress',
                        ),
                        trailing: ElevatedButton(
                          onPressed: loadABunchInProgress
                              ? null
                              : processLoadABunch,
                          child: loadABunchInProgress
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Start 5'),
                        ),
                      ),

                      // Workflow 3: URI Directory Picker (Mobile only)
                      if (onMobile) ...[
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Pick Destination Directory',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text(
                            'Uses UriDownloadTask and transfers.start',
                          ),
                          trailing: ElevatedButton(
                            onPressed: processPickDirectory,
                            child: const Text('Pick & Save'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ---------------------------------------------------------------
              // SECTION 4: Live Tracked Transfers (FileDownloader.transfers.notifier)
              // ---------------------------------------------------------------
              Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValueListenableBuilder<List<Transfer>>(
                        valueListenable: FileDownloader().transfers.notifier,
                        builder: (context, transfers, _) => Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.list_alt,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Tracked Transfers (${transfers.length})',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            if (transfers.isNotEmpty)
                              TextButton(
                                onPressed: () async {
                                  await FileDownloader().transfers.clear(
                                    cancelActive: true,
                                  );
                                  await FileDownloader().reset();
                                  setState(() {
                                    mainTransfer = null;
                                    batchProgressMessage = '';
                                  });
                                },
                                child: const Text('Clear All'),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'All transfers tracked by FileDownloader automatically appear here. '
                        'Each row is a reactive TransferListTile with live speed and controls.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Reactive list of all transfers
                      ValueListenableBuilder<List<Transfer>>(
                        valueListenable: FileDownloader().transfers.notifier,
                        builder: (context, transfers, _) {
                          if (transfers.isEmpty) {
                            return Container(
                              padding: const EdgeInsets.all(24.0),
                              alignment: Alignment.center,
                              child: Text(
                                'No transfers yet. Start one using the buttons above!',
                                style: TextStyle(
                                  color: theme.colorScheme.outline,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            );
                          }

                          return ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: transfers.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final transfer = transfers[index];
                              return TransferListTile(
                                key: ValueKey(transfer.taskId),
                                transfer: transfer,
                                showSpeed: true,
                                showPercentage: true,
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// Segmented button for WiFi requirement configuration
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
      if (mounted) {
        setState(() {
          requireWiFi = value;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => SegmentedButton<RequireWiFi>(
    segments: const [
      ButtonSegment(value: RequireWiFi.asSetByTask, label: Text('Task')),
      ButtonSegment(value: RequireWiFi.forAllTasks, label: Text('All')),
      ButtonSegment(value: RequireWiFi.forNoTasks, label: Text('None')),
    ],
    selected: <RequireWiFi>{requireWiFi},
    onSelectionChanged: (Set<RequireWiFi> newSelection) {
      setState(() {
        requireWiFi = newSelection.first;
        unawaited(
          FileDownloader().requireWiFi(
            requireWiFi,
            rescheduleRunningTasks: true,
          ),
        );
      });
    },
  );
}
