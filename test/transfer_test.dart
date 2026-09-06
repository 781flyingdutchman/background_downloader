import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/background_downloader.dart';

class InMemoryPersistentStorage implements PersistentStorage {
  final Map<String, TaskRecord> records = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    records[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async => records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async => records.values.toList();

  @override
  Future<void> removeTaskRecord(String? taskId) async {
    if (taskId == null) {
      records.clear();
    } else {
      records.remove(taskId);
    }
  }

  @override
  (String, int) get currentDatabaseVersion => ('', 0);

  @override
  Future<(String, int)> get storedDatabaseVersion async => ('', 0);

  @override
  Future<void> removePausedTask(String? taskId) async {}

  @override
  Future<void> removeResumeData(String? taskId) async {}

  @override
  Future<List<Task>> retrieveAllPausedTasks() async => [];

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async => [];

  @override
  Future<Task?> retrievePausedTask(String taskId) async => null;

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async => null;

  @override
  Future<void> storePausedTask(Task task) async {}

  @override
  Future<void> storeResumeData(ResumeData resumeData) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryPersistentStorage testStorage;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => '/tmp',
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (MethodCall call) async => ['wifi'],
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.bbflight.background_downloader'),
          (MethodCall call) async {
            switch (call.method) {
              case 'enqueue':
              case 'pause':
              case 'resume':
              case 'cancelTasksWithIds':
                return true;
              case 'enqueueAll':
                final tasksJson =
                    jsonDecode(call.arguments[0] as String) as List;
                return tasksJson.map((_) => true).toList();
              case 'reset':
                return 0;
              case 'platformVersion':
                return '34';
              case 'allTasks':
                return <dynamic>[];
              case 'taskForId':
                return null;
              default:
                return null;
            }
          },
        );
    testStorage = InMemoryPersistentStorage();
    FileDownloader(persistentStorage: testStorage);
  });

  setUp(() {
    testStorage.records.clear();
  });

  tearDown(() {
    FileDownloader().destroy();
  });

  group('Namespacing & Group Isolation on FileDownloader', () {
    test('FileDownloader.scoped returns cached multiton per namespace', () {
      final defaultDownloader = FileDownloader();
      expect(defaultDownloader.hasNamespace, isFalse);
      expect(defaultDownloader.namespace, isNull);

      final downloaderA1 = FileDownloader.scoped('pkg_a');
      final downloaderA2 = FileDownloader.scoped('pkg_a');
      final downloaderB = FileDownloader.scoped('pkg_b');

      expect(downloaderA1.hasNamespace, isTrue);
      expect(downloaderA1.namespace, equals('pkg_a'));
      expect(identical(downloaderA1, downloaderA2), isTrue);
      expect(identical(downloaderA1, downloaderB), isFalse);
      expect(identical(downloaderA1, defaultDownloader), isFalse);
    });

    test('namespacedGroup correctly scopes default and custom groups', () {
      final defaultDownloader = FileDownloader();
      expect(defaultDownloader.namespacedGroup(null), equals('default'));
      expect(defaultDownloader.namespacedGroup('default'), equals('default'));
      expect(defaultDownloader.namespacedGroup('models'), equals('models'));
      expect(defaultDownloader.originalGroup('default'), equals('default'));
      expect(defaultDownloader.originalGroup('models'), equals('models'));

      final downloaderA = FileDownloader.scoped('pkg_a');
      final downloaderB = FileDownloader.scoped('pkg_b');

      expect(downloaderA.namespacedGroup(null), equals('pkg_a.default'));
      expect(downloaderA.namespacedGroup('default'), equals('pkg_a.default'));
      expect(downloaderA.namespacedGroup('models'), equals('pkg_a.models'));

      expect(downloaderB.namespacedGroup(null), equals('pkg_b.default'));
      expect(downloaderB.namespacedGroup('models'), equals('pkg_b.models'));

      expect(downloaderA.originalGroup('pkg_a.default'), equals('default'));
      expect(downloaderA.originalGroup('pkg_a.models'), equals('models'));
    });

    test(
      'withNamespacedGroup modifies task group without altering other fields',
      () {
        final defaultDownloader = FileDownloader();
        final standardTask = DownloadTask(
          url: 'https://example.com/file.bin',
          filename: 'file.bin',
          group: 'my_group',
        );
        expect(
          defaultDownloader.withNamespacedGroup(standardTask).group,
          equals('my_group'),
        );
        expect(
          defaultDownloader.withoutNamespacedGroup(standardTask).group,
          equals('my_group'),
        );

        final scopedDownloader = FileDownloader.scoped('ai_engine');
        final task = DownloadTask(
          url: 'https://example.com/weights.bin',
          filename: 'weights.bin',
          group: 'weights',
          metaData: 'meta_data_123',
          displayName: 'Gemma 2B Weights',
        );

        final namespacedTask = scopedDownloader.withNamespacedGroup(task);
        expect(namespacedTask.group, equals('ai_engine.weights'));
        expect(namespacedTask.url, equals(task.url));
        expect(namespacedTask.filename, equals(task.filename));
        expect(namespacedTask.metaData, equals(task.metaData));
        expect(namespacedTask.displayName, equals(task.displayName));
      },
    );

    test('Two scoped downloaders remain strictly isolated', () {
      final downloaderA = FileDownloader.scoped('namespace_a');
      final downloaderB = FileDownloader.scoped('namespace_b');

      final taskA = DownloadTask(
        taskId: 'task_a',
        url: 'https://example.com/file_a.bin',
        filename: 'file_a.bin',
        group: 'common_group',
      );
      final taskB = DownloadTask(
        taskId: 'task_b',
        url: 'https://example.com/file_b.bin',
        filename: 'file_b.bin',
        group: 'common_group',
      );

      final nTaskA = downloaderA.withNamespacedGroup(taskA);
      final nTaskB = downloaderB.withNamespacedGroup(taskB);

      expect(nTaskA.group, equals('namespace_a.common_group'));
      expect(nTaskB.group, equals('namespace_b.common_group'));
      expect(nTaskA.group, isNot(equals(nTaskB.group)));
    });
  });

  group('Transfer Object & Lifecycle', () {
    late FileDownloader downloader;
    late DownloadTask task;

    setUp(() {
      downloader = FileDownloader.scoped('e2e_sim');
      task = DownloadTask(
        taskId: 'sim_task_1',
        url: 'https://example.com/dataset.tar.gz',
        filename: 'dataset.tar.gz',
        displayName: 'Training Dataset',
      );
    });

    test(
      'Full lifecycle: enqueued -> running -> progress -> complete',
      () async {
        final transfer = await downloader.transfers.start(task);
        expect(transfer.status, equals(TaskStatus.enqueued));
        expect(transfer.progress, isNull);

        final progressValues = <double>[];
        transfer.progressNotifier.addListener(() {
          if (transfer.progress != null) progressValues.add(transfer.progress!);
        });

        // Simulate native platform progress
        transfer.updateStatus(
          TaskStatusUpdate(transfer.task, TaskStatus.running),
        );
        expect(transfer.status, equals(TaskStatus.running));

        transfer.updateProgress(
          TaskProgressUpdate(
            transfer.task,
            0.25,
            10000000,
            1.2,
            const Duration(seconds: 8),
          ),
        );
        expect(transfer.progress, equals(0.25));
        expect(transfer.networkSpeed, equals(1.2));
        expect(
          transfer.timeRemainingNotifier.value,
          equals(const Duration(seconds: 8)),
        );

        transfer.updateProgress(
          TaskProgressUpdate(
            transfer.task,
            0.50,
            10000000,
            1.5,
            const Duration(seconds: 5),
          ),
        );
        expect(transfer.progress, equals(0.50));

        transfer.updateProgress(
          TaskProgressUpdate(
            transfer.task,
            0.75,
            10000000,
            1.8,
            const Duration(seconds: 2),
          ),
        );
        expect(transfer.progress, equals(0.75));

        transfer.updateProgress(
          TaskProgressUpdate(transfer.task, 1.0, 10000000, 2.0, Duration.zero),
        );
        transfer.updateStatus(
          TaskStatusUpdate(transfer.task, TaskStatus.complete),
        );

        expect(transfer.status, equals(TaskStatus.complete));
        expect(transfer.progress, equals(1.0));

        final result = await transfer.result;
        expect(result.status, equals(TaskStatus.complete));
        expect(progressValues, containsAllInOrder([0.25, 0.50, 0.75, 1.0]));
      },
    );

    test(
      'Simulated fatal error completes transfer with failure status',
      () async {
        final transfer = await downloader.transfers.start(task);
        transfer.updateStatus(
          TaskStatusUpdate(transfer.task, TaskStatus.running),
        );

        final exception = TaskHttpException('404 Not Found', 404);
        transfer.updateStatus(
          TaskStatusUpdate(transfer.task, TaskStatus.notFound, exception),
        );

        expect(transfer.status, equals(TaskStatus.notFound));
        expect(transfer.exception, equals(exception));

        final result = await transfer.result;
        expect(result.status, equals(TaskStatus.notFound));
        expect(result.exception, equals(exception));
      },
    );

    test('Simulated pause and resume lifecycle', () async {
      final transfer = await downloader.transfers.start(task);
      transfer.updateStatus(
        TaskStatusUpdate(transfer.task, TaskStatus.running),
      );
      transfer.updateProgress(TaskProgressUpdate(transfer.task, 0.40));

      // Pause
      transfer.updateStatus(TaskStatusUpdate(transfer.task, TaskStatus.paused));
      expect(transfer.status, equals(TaskStatus.paused));
      expect(transfer.progress, equals(0.40));

      // Resume
      transfer.updateStatus(
        TaskStatusUpdate(transfer.task, TaskStatus.running),
      );
      transfer.updateProgress(TaskProgressUpdate(transfer.task, 0.80));
      expect(transfer.status, equals(TaskStatus.running));
      expect(transfer.progress, equals(0.80));

      transfer.updateStatus(
        TaskStatusUpdate(transfer.task, TaskStatus.complete),
      );
      expect(transfer.status, equals(TaskStatus.complete));
      expect(transfer.progress, equals(1.0));
    });

    test('Native enqueuing when requiring Wi-Fi on cellular connection', () async {
      downloader.isWiFi = false;
      downloader.isConnected = true;

      final wifiTask = DownloadTask(
        taskId: 'wifi_task_1',
        url: 'https://example.com/big_file.zip',
        filename: 'big_file.zip',
        requiresWiFi: true,
      );

      final transfer = await downloader.transfers.start(wifiTask);
      expect(transfer.status, equals(TaskStatus.enqueued));
      expect(transfer.holdReason, equals(TransferHoldReason.waitingForWiFi));
      expect(transfer.isWaitingForWiFi, isTrue);

      // Transition to running clears hold reason
      transfer.updateStatus(TaskStatusUpdate(transfer.task, TaskStatus.running));
      expect(transfer.holdReason, equals(TransferHoldReason.none));
      expect(transfer.isWaitingForWiFi, isFalse);

      // Reset
      downloader.isWiFi = true;
    });

    test('Native enqueuing when offline and dynamic hold reason on connection loss', () async {
      downloader.isConnected = false;

      final offlineTask = DownloadTask(
        taskId: 'offline_task_1',
        url: 'https://example.com/offline.zip',
        filename: 'offline.zip',
      );

      final transfer = await downloader.transfers.start(offlineTask);
      expect(transfer.status, equals(TaskStatus.enqueued));
      expect(transfer.holdReason, equals(TransferHoldReason.offline));
      expect(transfer.isOffline, isTrue);

      // Transition to running clears hold reason
      transfer.updateStatus(TaskStatusUpdate(transfer.task, TaskStatus.running));
      expect(transfer.holdReason, equals(TransferHoldReason.none));

      // Network loss while running transitions to waitingToRetry and sets offline hold reason
      transfer.updateStatus(TaskStatusUpdate(transfer.task, TaskStatus.waitingToRetry));
      expect(transfer.holdReason, equals(TransferHoldReason.offline));
      expect(transfer.isOffline, isTrue);

      // Reset
      downloader.isConnected = true;
    });
  });

  group('getOrStart & Transfer Lookups', () {
    late FileDownloader downloader;

    setUp(() {
      downloader = FileDownloader.scoped('model_cache');
    });

    test(
      'Matches existing completed transfer by physical destination across random taskIds',
      () async {
        final originalTask = DownloadTask(
          taskId: 'original_session_task_id',
          url: 'https://example.com/gemma-2b.bin',
          filename: 'gemma-2b.bin',
        );

        final transfer = await downloader.transfers.start(originalTask);
        transfer.updateStatus(
          TaskStatusUpdate(transfer.task, TaskStatus.complete),
        );
        expect(transfer.status, equals(TaskStatus.complete));

        final newTaskWithRandomId = DownloadTask(
          taskId: 'new_random_id_54321',
          url: 'https://example.com/gemma-2b.bin',
          filename: 'gemma-2b.bin',
        );

        final matchedTransfer = await downloader.transfers.getOrStart(
          newTaskWithRandomId,
        );
        expect(matchedTransfer.taskId, equals(originalTask.taskId));
        expect(matchedTransfer.status, equals(TaskStatus.complete));
        expect(matchedTransfer.progress, equals(1.0));
      },
    );

    test('Matches by custom matchBy predicate', () async {
      final task = DownloadTask(
        taskId: 'model_abc',
        url: 'https://example.com/model.bin',
        filename: 'model.bin',
        metaData: 'model_v2_quantized',
      );

      final transfer = await downloader.transfers.start(task);
      transfer.updateStatus(
        TaskStatusUpdate(transfer.task, TaskStatus.running),
      );

      final matched = downloader.transfers.forTask(
        DownloadTask(url: 'https://other.com/temp.bin', filename: 'temp.bin'),
        matchBy: (existing) => existing.metaData == 'model_v2_quantized',
      );

      expect(matched, isNotNull);
      expect(matched!.taskId, equals('model_abc'));
    });

    test('Lookups by URL, ID, and indexing operator', () async {
      final task = DownloadTask(
        taskId: 'lookup_id_1',
        url: 'https://example.com/video.mp4',
        filename: 'video.mp4',
      );

      final transfer = await downloader.transfers.start(task);

      expect(
        downloader.transfers.forUrl('https://example.com/video.mp4'),
        equals(transfer),
      );
      expect(downloader.transfers.forId('lookup_id_1'), equals(transfer));
      expect(downloader.transfers['lookup_id_1'], equals(transfer));
      expect(downloader.transfers.forUrl('https://nonexistent.com'), isNull);
    });

    test(
      'Simulated app restart: getOrStart and rehydrateFromDatabase restore transfer from database',
      () async {
        await downloader.trackTasks();

        final persistedTask = DownloadTask(
          taskId: 'persisted_task_42',
          url: 'https://example.com/database_model.bin',
          filename: 'database_model.bin',
          group: 'models',
        );

        final namespacedTask = downloader.withNamespacedGroup(persistedTask);
        final record = TaskRecord(
          namespacedTask,
          TaskStatus.complete,
          1.0,
          1048576,
        );
        await downloader.database.updateRecord(record);

        // Simulate app termination by clearing in-memory state
        await downloader.transfers.clear();
        expect(downloader.transfers.all(), isEmpty);
        expect(downloader.transfers.forId('persisted_task_42'), isNull);

        // getOrStart should find record in database and rehydrate it
        final rehydratedTransfer = await downloader.transfers.getOrStart(
          persistedTask,
        );
        expect(rehydratedTransfer.taskId, equals('persisted_task_42'));
        expect(rehydratedTransfer.status, equals(TaskStatus.complete));
        expect(rehydratedTransfer.progress, equals(1.0));
        expect(downloader.transfers.forId('persisted_task_42'), equals(rehydratedTransfer));

        // Clear again and test rehydrateFromDatabase
        await downloader.transfers.clear();
        expect(downloader.transfers.all(), isEmpty);

        final rehydratedList = await downloader.transfers.rehydrateFromDatabase();
        expect(rehydratedList.length, equals(1));
        expect(rehydratedList.first.taskId, equals('persisted_task_42'));
        expect(downloader.transfers.all().length, equals(1));
        expect(downloader.transfers.completed().length, equals(1));
      },
    );
  });

  group('startAll & startOrGetAll (Batch)', () {
    late FileDownloader downloader;

    setUp(() {
      downloader = FileDownloader.scoped('batch_test');
    });

    test(
      'startAll tracks aggregate progress across multiple transfers',
      () async {
        final tasks = List.generate(
          3,
          (i) => DownloadTask(
            taskId: 'batch_task_$i',
            url: 'https://example.com/part_$i.bin',
            filename: 'part_$i.bin',
          ),
        );

        final progressEvents = <(int, int)>[];
        final transfers = await downloader.transfers.startAll(
          tasks,
          onProgress: (succeeded, failed) {
            progressEvents.add((succeeded, failed));
          },
        );

        expect(transfers.length, equals(3));

        // Complete transfer 0
        transfers[0].updateStatus(
          TaskStatusUpdate(transfers[0].task, TaskStatus.complete),
        );
        await Future.delayed(const Duration(milliseconds: 10));
        expect(progressEvents.last, equals((1, 0)));

        // Complete transfer 1
        transfers[1].updateStatus(
          TaskStatusUpdate(transfers[1].task, TaskStatus.complete),
        );
        await Future.delayed(const Duration(milliseconds: 10));
        expect(progressEvents.last, equals((2, 0)));

        // Fail transfer 2
        transfers[2].updateStatus(
          TaskStatusUpdate(transfers[2].task, TaskStatus.failed),
        );
        await Future.delayed(const Duration(milliseconds: 10));
        expect(progressEvents.last, equals((2, 1)));
      },
    );

    test('startOrGetAll reuses existing and starts remaining', () async {
      final task1 = DownloadTask(
        taskId: 'part_1',
        url: 'https://example.com/p1.bin',
        filename: 'p1.bin',
      );
      final task2 = DownloadTask(
        taskId: 'part_2',
        url: 'https://example.com/p2.bin',
        filename: 'p2.bin',
      );

      // Start and complete task1 first
      final t1 = await downloader.transfers.start(task1);
      t1.updateStatus(TaskStatusUpdate(task1, TaskStatus.complete));

      // Now call startOrGetAll with task1 (completed) and task2 (new)
      final allResults = await downloader.transfers.startOrGetAll([task1, task2]);
      expect(allResults.length, equals(2));
      expect(allResults[0], equals(t1));
      expect(allResults[0].status, equals(TaskStatus.complete));
      expect(allResults[1].taskId, equals('part_2'));
    });

    test('start and startAll automatically ensure providesStatusUpdates', () async {
      final task = DownloadTask(
        taskId: 'progress_only_task',
        url: 'https://example.com/test.bin',
        filename: 'test.bin',
        updates: Updates.progress,
      );
      final transfer = await downloader.transfers.start(task);
      expect(transfer.task.updates, equals(Updates.statusAndProgress));
      expect(transfer.task.providesStatusUpdates, isTrue);
      expect(transfer.task.providesProgressUpdates, isTrue);

      final batchTask = DownloadTask(
        taskId: 'none_task',
        url: 'https://example.com/none.bin',
        filename: 'none.bin',
        updates: Updates.none,
      );
      final batchTransfers = await downloader.transfers.startAll([batchTask]);
      expect(batchTransfers.first.task.updates, equals(Updates.status));
      expect(batchTransfers.first.task.providesStatusUpdates, isTrue);
    });
  });

  group('Transfer Collections & transfers.notifier', () {
    late FileDownloader downloader;

    setUp(() {
      downloader = FileDownloader.scoped('queries_test');
    });

    test(
      'active, completed, and notifier react to state transitions',
      () async {
        var notifyCount = 0;
        downloader.transfers.notifier.addListener(() {
          notifyCount++;
        });

        final task1 = DownloadTask(
          taskId: 'q_1',
          url: 'https://example.com/1.bin',
          filename: '1.bin',
        );
        final task2 = DownloadTask(
          taskId: 'q_2',
          url: 'https://example.com/2.bin',
          filename: '2.bin',
        );

        final transfer1 = await downloader.transfers.start(task1);
        final transfer2 = await downloader.transfers.start(task2);

        expect(downloader.transfers.all().length, equals(2));
        expect(downloader.transfers.active().length, equals(2));
        expect(downloader.transfers.completed().length, equals(0));

        // Transition transfer 1 to complete
        transfer1.updateStatus(
          TaskStatusUpdate(transfer1.task, TaskStatus.complete),
        );
        expect(downloader.transfers.active().length, equals(1));
        expect(downloader.transfers.completed().length, equals(1));
        expect(downloader.transfers.completed().first.taskId, equals('q_1'));

        // Transition transfer 2 to failed
        transfer2.updateStatus(
          TaskStatusUpdate(transfer2.task, TaskStatus.failed),
        );
        expect(downloader.transfers.active().length, equals(0));
        expect(downloader.transfers.completed().length, equals(1));

        expect(notifyCount, greaterThan(0));
      },
    );

    test('clear removes transfers and resets notifier', () async {
      final task = DownloadTask(
        taskId: 'clr_1',
        url: 'https://example.com/c1.bin',
        filename: 'c1.bin',
      );
      await downloader.transfers.start(task);
      expect(downloader.transfers.all(), isNotEmpty);
      expect(downloader.transfers.notifier.value, isNotEmpty);

      await downloader.transfers.clear();
      expect(downloader.transfers.all(), isEmpty);
      expect(downloader.transfers.notifier.value, isEmpty);
    });
  });

  group('TransferHint & Smart Task Tuning on Task', () {
    test('TransferHint tuning in Task constructors', () {
      final userTask = DownloadTask(
        url: 'https://example.com/user.bin',
        filename: 'user.bin',
        transferHints: {TransferHint.userInitiated},
      );
      expect(userTask.priority, equals(0));
      expect(userTask.allowPause, isTrue);

      final lowTask = DownloadTask(
        url: 'https://example.com/low.bin',
        filename: 'low.bin',
        transferHints: {TransferHint.lowPriority},
      );
      expect(lowTask.priority, equals(10));

      final uploadTask = UploadTask(
        url: 'https://example.com/upload',
        filename: 'upload.bin',
        transferHints: {TransferHint.binaryUpload},
      );
      expect(uploadTask.post, equals('binary'));
    });
  });

  group('UI Widgets for Transfer', () {
    late FileDownloader downloader;
    late DownloadTask task;
    late Transfer transfer;

    setUp(() {
      downloader = FileDownloader.scoped('ui_ns');
      task = DownloadTask(
        url: 'https://example.com/sample.mp4',
        filename: 'sample.mp4',
        displayName: 'Sample Video',
      );
      transfer = Transfer(task, downloader);
    });

    testWidgets(
      'TransferProgressBar renders correctly and updates reactively',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TransferProgressBar(transfer: transfer)),
          ),
        );

        expect(find.text('Enqueued'), findsOneWidget);

        // Transition to running with progress
        transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.running));
        transfer.updateProgress(
          TaskProgressUpdate(
            task,
            0.75,
            1024 * 1024,
            0.5,
            const Duration(seconds: 5),
          ),
        );
        await tester.pump();

        expect(find.text('Transferring'), findsOneWidget);
        expect(find.text('75%'), findsOneWidget);
        expect(find.text('500 kB/s'), findsOneWidget);

        // Set hold reason to waiting for Wi-Fi
        transfer.holdReasonNotifier.value = TransferHoldReason.waitingForWiFi;
        await tester.pump();
        expect(find.text('Waiting for Wi-Fi'), findsOneWidget);

        // Set hold reason to offline
        transfer.holdReasonNotifier.value = TransferHoldReason.offline;
        await tester.pump();
        expect(find.text('Waiting for network'), findsOneWidget);

        // Complete
        transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.complete));
        await tester.pump();

        expect(find.text('Complete'), findsOneWidget);
      },
    );

    testWidgets('TransferButton updates icon based on transfer status', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TransferButton(transfer: transfer))),
      );

      // Enqueued / Running -> Pause button
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);

      // Paused -> Play button
      transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.paused));
      await tester.pump();
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);

      // Complete -> Check icon
      transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.complete));
      await tester.pump();
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('TransferListTile renders title, progress bar and controls', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TransferListTile(transfer: transfer))),
      );

      expect(find.text('Sample Video'), findsOneWidget);
      expect(find.byType(TransferProgressBar), findsOneWidget);
      expect(find.byType(TransferButton), findsOneWidget);
    });
  });
}
