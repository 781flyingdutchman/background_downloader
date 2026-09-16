import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/background_downloader.dart';

class InMemoryPersistentStorage implements PersistentStorage {
  final Map<String, TaskRecord> records = {};
  final Map<String, Task> pausedTasks = {};
  final Map<String, ResumeData> resumeData = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    records[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async =>
      records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();

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
  Future<void> removePausedTask(String? taskId) async {
    if (taskId == null) {
      pausedTasks.clear();
    } else {
      pausedTasks.remove(taskId);
    }
  }

  @override
  Future<void> removeResumeData(String? taskId) async {
    if (taskId == null) {
      resumeData.clear();
    } else {
      resumeData.remove(taskId);
    }
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() async =>
      pausedTasks.values.toList();

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      resumeData.values.toList();

  @override
  Future<Task?> retrievePausedTask(String taskId) async => pausedTasks[taskId];

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async =>
      resumeData[taskId];

  @override
  Future<void> storePausedTask(Task task) async {
    pausedTasks[task.taskId] = task;
  }

  @override
  Future<void> storeResumeData(ResumeData resumeData) async {
    this.resumeData[resumeData.taskId] = resumeData;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryPersistentStorage testStorage;

  // Use smaller download file with content length and progress updates
  const testUrl = 'http://127.0.0.1:8080/files/1MB-test.bin';
  const testFilename = '1MB-test.bin';
  const testFileSize = 1048576; // 1 MB

  DownloadTask createTestTask({
    String? taskId,
    String group = FileDownloader.defaultGroup,
    Updates updates = Updates.statusAndProgress,
  }) => DownloadTask(
    taskId: taskId ?? 'task_${DateTime.now().microsecondsSinceEpoch}',
    url: testUrl,
    filename: testFilename,
    group: group,
    updates: updates,
  );

  void simulateDownloadLifecycle(
    Task task, {
    List<double> progressSteps = const [0.0, 0.25, 0.5, 0.75, 1.0],
    TaskStatus finalStatus = TaskStatus.complete,
    int expectedFileSize = testFileSize,
  }) {
    final downloader = FileDownloader().downloaderForTesting;
    downloader.processStatusUpdate(TaskStatusUpdate(task, TaskStatus.enqueued));
    downloader.processStatusUpdate(TaskStatusUpdate(task, TaskStatus.running));
    for (final progress in progressSteps) {
      downloader.processProgressUpdate(
        TaskProgressUpdate(
          task,
          progress,
          expectedFileSize,
          2.0, // 2.0 MB/s network speed
          Duration(seconds: ((1.0 - progress) * 2).round()),
        ),
      );
    }
    downloader.processStatusUpdate(TaskStatusUpdate(task, finalStatus));
  }

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
          (MethodCall call) async => switch (call.method) {
            'enqueue' || 'pause' || 'resume' || 'cancelTasksWithIds' => true,
            'enqueueAll' => (jsonDecode(
              call.arguments[0] as String,
            ) as List).map((_) => true).toList(),
            'reset' => 0,
            'platformVersion' => '34',
            'allTasks' => <dynamic>[],
            'taskForId' => null,
            'popResumeData' ||
            'popStatusUpdates' ||
            'popProgressUpdates' => '{}',
            _ => null,
          },
        );
    testStorage = InMemoryPersistentStorage();
    FileDownloader(persistentStorage: testStorage);
  });

  setUp(() {
    testStorage.records.clear();
    testStorage.pausedTasks.clear();
    testStorage.resumeData.clear();
    FileDownloader().destroy();
  });

  tearDown(() {
    FileDownloader().destroy();
  });

  group('Group 1: updates stream delivery (no registered group callbacks)', () {
    test('1.1 enqueue with trackTasks: false delivers all updates to stream and creates no DB record', () async {
      final receivedUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(receivedUpdates.add);

      final task = createTestTask(taskId: 'enqueue_notrack');
      final enqueued = await FileDownloader().enqueue(task);
      expect(enqueued, isTrue);

      simulateDownloadLifecycle(task);
      await Future.delayed(const Duration(milliseconds: 50));

      // Updates stream receives all status and progress updates
      expect(
        receivedUpdates.whereType<TaskStatusUpdate>().map((u) => u.status),
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      expect(
        receivedUpdates.whereType<TaskProgressUpdate>().map((u) => u.progress),
        equals([0.0, 0.25, 0.5, 0.75, 1.0]),
      );

      // Tracking is off -> no database record
      expect(testStorage.records[task.taskId], isNull);

      await subscription.cancel();
    });

    test('1.2 enqueue with trackTasks: true delivers all updates to stream and stores DB record', () async {
      final receivedUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(receivedUpdates.add);

      await FileDownloader().trackTasks();

      final task = createTestTask(taskId: 'enqueue_track');
      final enqueued = await FileDownloader().enqueue(task);
      expect(enqueued, isTrue);

      simulateDownloadLifecycle(task);
      await Future.delayed(const Duration(milliseconds: 50));

      // Updates stream receives all status and progress updates (issue #727 check)
      expect(
        receivedUpdates.whereType<TaskStatusUpdate>().map((u) => u.status),
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      expect(
        receivedUpdates.whereType<TaskProgressUpdate>().map((u) => u.progress),
        equals([0.0, 0.25, 0.5, 0.75, 1.0]),
      );

      // Tracking is on -> record created and updated with complete status
      final record = testStorage.records[task.taskId];
      expect(record, isNotNull);
      expect(record!.status, equals(TaskStatus.complete));
      expect(record.progress, equals(progressComplete));

      await subscription.cancel();
    });

    test('1.3 transfers.start with trackTasks: false delivers to stream and updates Transfer handle', () async {
      final receivedUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(receivedUpdates.add);

      final task = createTestTask(taskId: 'transfer_notrack');
      final transfer = await FileDownloader().transfers.start(task);

      simulateDownloadLifecycle(task);
      final result = await transfer.result;

      // Transfer handle updated
      expect(result.status, equals(TaskStatus.complete));
      expect(transfer.status, equals(TaskStatus.complete));
      expect(transfer.progress, equals(1.0));

      await Future.delayed(const Duration(milliseconds: 50));

      // Updates stream receives all status and progress updates (fixes #727)
      expect(
        receivedUpdates.whereType<TaskStatusUpdate>().map((u) => u.status),
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      expect(
        receivedUpdates.whereType<TaskProgressUpdate>().map((u) => u.progress),
        equals([0.0, 0.25, 0.5, 0.75, 1.0]),
      );

      await subscription.cancel();
    });

    test('1.4 transfers.start with trackTasks: true delivers to stream, updates Transfer handle, and persists record', () async {
      final receivedUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(receivedUpdates.add);

      await FileDownloader().trackTasks();

      final task = createTestTask(taskId: 'transfer_track');
      final transfer = await FileDownloader().transfers.start(task);

      simulateDownloadLifecycle(task);
      final result = await transfer.result;

      expect(result.status, equals(TaskStatus.complete));
      expect(transfer.status, equals(TaskStatus.complete));
      expect(transfer.progress, equals(1.0));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        receivedUpdates.whereType<TaskStatusUpdate>().map((u) => u.status),
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      expect(
        receivedUpdates.whereType<TaskProgressUpdate>().map((u) => u.progress),
        equals([0.0, 0.25, 0.5, 0.75, 1.0]),
      );

      final record = testStorage.records[task.taskId];
      expect(record, isNotNull);
      expect(record!.status, equals(TaskStatus.complete));
      expect(record.progress, equals(progressComplete));

      await subscription.cancel();
    });

    test('1.5 download with trackTasks: false completes directly and does not emit to updates stream', () async {
      final receivedUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(receivedUpdates.add);

      final statusEvents = <TaskStatus>[];
      final progressEvents = <double>[];

      final task = createTestTask(taskId: 'download_notrack');
      final downloadFuture = FileDownloader().download(
        task,
        onStatus: statusEvents.add,
        onProgress: progressEvents.add,
      );

      simulateDownloadLifecycle(task);
      final result = await downloadFuture;

      expect(result.status, equals(TaskStatus.complete));
      expect(
        statusEvents,
        containsAllInOrder([TaskStatus.running, TaskStatus.complete]),
      );
      expect(progressEvents, equals([0.0, 0.25, 0.5, 0.75, 1.0]));

      await Future.delayed(const Duration(milliseconds: 50));

      // download awaits internally via awaitTasks, so updates stream receives 0 updates
      expect(receivedUpdates, isEmpty);
      expect(testStorage.records[task.taskId], isNull);

      await subscription.cancel();
    });

    test('1.6 download with trackTasks: true completes directly, does not emit to stream, and stores DB record', () async {
      final receivedUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(receivedUpdates.add);

      await FileDownloader().trackTasks();

      final task = createTestTask(taskId: 'download_track');
      final downloadFuture = FileDownloader().download(task);

      simulateDownloadLifecycle(task);
      final result = await downloadFuture;

      expect(result.status, equals(TaskStatus.complete));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(receivedUpdates, isEmpty);

      final record = testStorage.records[task.taskId];
      expect(record, isNotNull);
      expect(record!.status, equals(TaskStatus.complete));
      expect(record.progress, equals(progressComplete));

      await subscription.cancel();
    });
  });

  group(
    'Group 2: registered callbacks (registerCallbacks) and stream suppression',
    () {
      test('2.1 enqueue with registered callbacks routes to callbacks and suppresses updates stream (trackTasks: false)', () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        final callbackStatusUpdates = <TaskStatusUpdate>[];
        final callbackProgressUpdates = <TaskProgressUpdate>[];

        FileDownloader().registerCallbacks(
          taskStatusCallback: callbackStatusUpdates.add,
          taskProgressCallback: callbackProgressUpdates.add,
        );

        final task = createTestTask(taskId: 'enqueue_cb_notrack');
        await FileDownloader().enqueue(task);

        simulateDownloadLifecycle(task);
        await Future.delayed(const Duration(milliseconds: 50));

        // Registered callbacks received all updates
        expect(
          callbackStatusUpdates.map((u) => u.status),
          equals([
            TaskStatus.enqueued,
            TaskStatus.running,
            TaskStatus.complete,
          ]),
        );
        expect(
          callbackProgressUpdates.map((u) => u.progress),
          equals([0.0, 0.25, 0.5, 0.75, 1.0]),
        );

        // CRITICAL CONTRACT: Updates stream receives ZERO updates because registered callbacks consumed them
        expect(receivedStreamUpdates, isEmpty);
        expect(testStorage.records[task.taskId], isNull);

        await subscription.cancel();
      });

      test('2.2 enqueue with registered callbacks routes to callbacks, suppresses stream, and updates DB (trackTasks: true)', () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        final callbackStatusUpdates = <TaskStatusUpdate>[];
        final callbackProgressUpdates = <TaskProgressUpdate>[];

        await FileDownloader().trackTasks();
        FileDownloader().registerCallbacks(
          taskStatusCallback: callbackStatusUpdates.add,
          taskProgressCallback: callbackProgressUpdates.add,
        );

        final task = createTestTask(taskId: 'enqueue_cb_track');
        await FileDownloader().enqueue(task);

        simulateDownloadLifecycle(task);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          callbackStatusUpdates.map((u) => u.status),
          equals([
            TaskStatus.enqueued,
            TaskStatus.running,
            TaskStatus.complete,
          ]),
        );
        expect(
          callbackProgressUpdates.map((u) => u.progress),
          equals([0.0, 0.25, 0.5, 0.75, 1.0]),
        );

        // Stream is suppressed
        expect(receivedStreamUpdates, isEmpty);

        // Tracking still functions independently
        final record = testStorage.records[task.taskId];
        expect(record, isNotNull);
        expect(record!.status, equals(TaskStatus.complete));
        expect(record.progress, equals(progressComplete));

        await subscription.cancel();
      });

      test('2.3 transfers.start with registered callbacks routes to callbacks, updates Transfer handle, and suppresses stream (trackTasks: false)', () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        final callbackStatusUpdates = <TaskStatusUpdate>[];
        final callbackProgressUpdates = <TaskProgressUpdate>[];

        FileDownloader().registerCallbacks(
          taskStatusCallback: callbackStatusUpdates.add,
          taskProgressCallback: callbackProgressUpdates.add,
        );

        final task = createTestTask(taskId: 'transfer_cb_notrack');
        final transfer = await FileDownloader().transfers.start(task);

        simulateDownloadLifecycle(task);
        final result = await transfer.result;

        // Transfer handle received updates
        expect(result.status, equals(TaskStatus.complete));
        expect(transfer.status, equals(TaskStatus.complete));
        expect(transfer.progress, equals(1.0));

        await Future.delayed(const Duration(milliseconds: 50));

        // User registered callbacks received updates
        expect(
          callbackStatusUpdates.map((u) => u.status),
          equals([
            TaskStatus.enqueued,
            TaskStatus.running,
            TaskStatus.complete,
          ]),
        );
        expect(
          callbackProgressUpdates.map((u) => u.progress),
          equals([0.0, 0.25, 0.5, 0.75, 1.0]),
        );

        // CRITICAL CONTRACT: Updates stream receives ZERO updates
        expect(receivedStreamUpdates, isEmpty);

        await subscription.cancel();
      });

      test('2.4 transfers.start with registered callbacks routes to callbacks, updates Transfer handle, suppresses stream, and updates DB (trackTasks: true)', () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        final callbackStatusUpdates = <TaskStatusUpdate>[];
        final callbackProgressUpdates = <TaskProgressUpdate>[];

        await FileDownloader().trackTasks();
        FileDownloader().registerCallbacks(
          taskStatusCallback: callbackStatusUpdates.add,
          taskProgressCallback: callbackProgressUpdates.add,
        );

        final task = createTestTask(taskId: 'transfer_cb_track');
        final transfer = await FileDownloader().transfers.start(task);

        simulateDownloadLifecycle(task);
        final result = await transfer.result;

        expect(result.status, equals(TaskStatus.complete));
        expect(transfer.status, equals(TaskStatus.complete));
        expect(transfer.progress, equals(1.0));

        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          callbackStatusUpdates.map((u) => u.status),
          equals([
            TaskStatus.enqueued,
            TaskStatus.running,
            TaskStatus.complete,
          ]),
        );
        expect(
          callbackProgressUpdates.map((u) => u.progress),
          equals([0.0, 0.25, 0.5, 0.75, 1.0]),
        );

        // Stream suppressed
        expect(receivedStreamUpdates, isEmpty);

        // DB record persisted
        final record = testStorage.records[task.taskId];
        expect(record, isNotNull);
        expect(record!.status, equals(TaskStatus.complete));
        expect(record.progress, equals(progressComplete));

        await subscription.cancel();
      });

      test('2.5 download with registered callbacks completes and suppresses updates stream (trackTasks: false)', () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        FileDownloader().registerCallbacks(
          taskStatusCallback: (_) {},
          taskProgressCallback: (_) {},
        );

        final task = createTestTask(taskId: 'download_cb_notrack');
        final downloadFuture = FileDownloader().download(task);

        simulateDownloadLifecycle(task);
        final result = await downloadFuture;

        expect(result.status, equals(TaskStatus.complete));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(receivedStreamUpdates, isEmpty);
        expect(testStorage.records[task.taskId], isNull);

        await subscription.cancel();
      });

      test('2.6 download with registered callbacks completes, suppresses stream, and updates DB (trackTasks: true)', () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        await FileDownloader().trackTasks();
        FileDownloader().registerCallbacks(
          taskStatusCallback: (_) {},
          taskProgressCallback: (_) {},
        );

        final task = createTestTask(taskId: 'download_cb_track');
        final downloadFuture = FileDownloader().download(task);

        simulateDownloadLifecycle(task);
        final result = await downloadFuture;

        expect(result.status, equals(TaskStatus.complete));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(receivedStreamUpdates, isEmpty);

        final record = testStorage.records[task.taskId];
        expect(record, isNotNull);
        expect(record!.status, equals(TaskStatus.complete));
        expect(record.progress, equals(progressComplete));

        await subscription.cancel();
      });
    },
  );

  group('Group 3: unregistering callbacks (unregisterCallbacks)', () {
    test(
      '3.1 enqueue: unregistering callbacks restores updates stream delivery',
      () async {
        final receivedStreamUpdates = <TaskUpdate>[];
        final subscription = FileDownloader().updates.listen(
          receivedStreamUpdates.add,
        );

        final callbackStatusUpdates = <TaskStatusUpdate>[];
        final callbackProgressUpdates = <TaskProgressUpdate>[];

        void onStatus(TaskStatusUpdate u) => callbackStatusUpdates.add(u);
        void onProgress(TaskProgressUpdate u) => callbackProgressUpdates.add(u);

        FileDownloader().registerCallbacks(
          taskStatusCallback: onStatus,
          taskProgressCallback: onProgress,
        );

        // Phase 1: Task A runs with registered callbacks active
        final taskA = createTestTask(taskId: 'unreg_enqueue_taskA');
        await FileDownloader().enqueue(taskA);
        simulateDownloadLifecycle(taskA);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(callbackStatusUpdates, isNotEmpty);
        expect(receivedStreamUpdates, isEmpty);

        // Phase 2: Unregister callbacks
        FileDownloader().unregisterCallbacks();
        callbackStatusUpdates.clear();
        callbackProgressUpdates.clear();

        // Phase 3: Task B runs after unregistering -> updates stream receives events
        final taskB = createTestTask(taskId: 'unreg_enqueue_taskB');
        await FileDownloader().enqueue(taskB);
        simulateDownloadLifecycle(taskB);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(callbackStatusUpdates, isEmpty);
        expect(
          receivedStreamUpdates
              .whereType<TaskStatusUpdate>()
              .where((u) => u.task.taskId == taskB.taskId)
              .map((u) => u.status),
          equals([
            TaskStatus.enqueued,
            TaskStatus.running,
            TaskStatus.complete,
          ]),
        );

        await subscription.cancel();
      },
    );

    test('3.2 transfers: unregistering callbacks restores updates stream delivery for subsequent transfers', () async {
      final receivedStreamUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(
        receivedStreamUpdates.add,
      );

      final callbackStatusUpdates = <TaskStatusUpdate>[];
      final callbackProgressUpdates = <TaskProgressUpdate>[];

      FileDownloader().registerCallbacks(
        taskStatusCallback: callbackStatusUpdates.add,
        taskProgressCallback: callbackProgressUpdates.add,
      );

      // Phase 1: Transfer A runs with registered callbacks
      final taskA = createTestTask(taskId: 'unreg_trans_taskA');
      final transferA = await FileDownloader().transfers.start(taskA);
      simulateDownloadLifecycle(taskA);
      await transferA.result;
      await Future.delayed(const Duration(milliseconds: 50));

      expect(callbackStatusUpdates, isNotEmpty);
      expect(callbackProgressUpdates, isNotEmpty);
      expect(receivedStreamUpdates, isEmpty);

      // Phase 2: Unregister user callbacks
      FileDownloader().unregisterCallbacks();
      callbackStatusUpdates.clear();
      callbackProgressUpdates.clear();

      // Phase 3: Transfer B runs -> stream receives updates, Transfer B handle receives updates
      final taskB = createTestTask(taskId: 'unreg_trans_taskB');
      final transferB = await FileDownloader().transfers.start(taskB);
      simulateDownloadLifecycle(taskB);
      final resultB = await transferB.result;

      expect(resultB.status, equals(TaskStatus.complete));
      expect(callbackStatusUpdates, isEmpty);
      expect(callbackProgressUpdates, isEmpty);

      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        receivedStreamUpdates
            .whereType<TaskStatusUpdate>()
            .where((u) => u.task.taskId == taskB.taskId)
            .map((u) => u.status),
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      expect(
        receivedStreamUpdates
            .whereType<TaskProgressUpdate>()
            .where((u) => u.task.taskId == taskB.taskId)
            .map((u) => u.progress),
        equals([0.0, 0.25, 0.5, 0.75, 1.0]),
      );

      await subscription.cancel();
    });
  });

  group('Group 4: group scoping and isolation', () {
    test('4.1 registered callbacks for custom_group do not suppress defaultGroup stream updates', () async {
      final defaultStreamUpdates = <TaskUpdate>[];
      final subscription = FileDownloader().updates.listen(
        defaultStreamUpdates.add,
      );

      final customGroupStatusUpdates = <TaskStatusUpdate>[];
      final customGroupProgressUpdates = <TaskProgressUpdate>[];
      FileDownloader().registerCallbacks(
        group: 'custom_group',
        taskStatusCallback: customGroupStatusUpdates.add,
        taskProgressCallback: customGroupProgressUpdates.add,
      );

      // Task in defaultGroup (no registered callbacks)
      final taskDefault = createTestTask(
        taskId: 'task_default',
        group: FileDownloader.defaultGroup,
      );
      await FileDownloader().enqueue(taskDefault);
      simulateDownloadLifecycle(taskDefault);

      // Task in custom_group (has registered callbacks)
      final taskCustom = createTestTask(
        taskId: 'task_custom',
        group: 'custom_group',
      );
      await FileDownloader().enqueue(taskCustom);
      simulateDownloadLifecycle(taskCustom);

      await Future.delayed(const Duration(milliseconds: 50));

      // defaultGroup task emitted to updates stream
      final defaultStatuses = defaultStreamUpdates
          .whereType<TaskStatusUpdate>()
          .where((u) => u.task.taskId == taskDefault.taskId)
          .map((u) => u.status)
          .toList();
      expect(
        defaultStatuses,
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      final defaultProgresses = defaultStreamUpdates
          .whereType<TaskProgressUpdate>()
          .where((u) => u.task.taskId == taskDefault.taskId)
          .map((u) => u.progress)
          .toList();
      expect(defaultProgresses, equals([0.0, 0.25, 0.5, 0.75, 1.0]));

      // custom_group task was intercepted by callbacks and NOT emitted to updates stream
      final customStreamEvents = defaultStreamUpdates
          .where((u) => u.task.taskId == taskCustom.taskId)
          .toList();
      expect(customStreamEvents, isEmpty);

      expect(
        customGroupStatusUpdates.map((u) => u.status),
        equals([TaskStatus.enqueued, TaskStatus.running, TaskStatus.complete]),
      );
      expect(
        customGroupProgressUpdates.map((u) => u.progress),
        equals([0.0, 0.25, 0.5, 0.75, 1.0]),
      );

      await subscription.cancel();
    });
  });

  group('Group 5: parameterized matrix equivalence across all approaches', () {
    for (final approach in ['enqueue', 'download', 'transfers']) {
      for (final trackTasks in [false, true]) {
        for (final withCallback in [false, true]) {
          test(
            'Matrix: approach=$approach, trackTasks=$trackTasks, withCallback=$withCallback',
            () async {
              final streamUpdates = <TaskUpdate>[];
              final subscription = FileDownloader().updates.listen(
                streamUpdates.add,
              );

              if (trackTasks) {
                await FileDownloader().trackTasks();
              }

              final callbackStatusUpdates = <TaskStatusUpdate>[];
              final callbackProgressUpdates = <TaskProgressUpdate>[];
              if (withCallback) {
                FileDownloader().registerCallbacks(
                  taskStatusCallback: callbackStatusUpdates.add,
                  taskProgressCallback: callbackProgressUpdates.add,
                );
              }

              final task = createTestTask(
                taskId: 'matrix_${approach}_t${trackTasks}_c$withCallback',
              );

              // Execute based on approach
              TaskStatus finalStatus;
              if (approach == 'enqueue') {
                await FileDownloader().enqueue(task);
                simulateDownloadLifecycle(task);
                finalStatus = TaskStatus.complete;
              } else if (approach == 'download') {
                final downloadFuture = FileDownloader().download(task);
                simulateDownloadLifecycle(task);
                final result = await downloadFuture;
                finalStatus = result.status;
              } else {
                final transfer = await FileDownloader().transfers.start(task);
                simulateDownloadLifecycle(task);
                final result = await transfer.result;
                finalStatus = result.status;
              }

              expect(finalStatus, equals(TaskStatus.complete));
              await Future.delayed(const Duration(milliseconds: 50));

              // Verification 1: Callback routing & stream suppression
              if (approach == 'download') {
                // download is awaited in-place via awaitTasks, so stream is always empty
                expect(streamUpdates, isEmpty);
              } else if (withCallback) {
                // Registered callbacks intercepted updates -> stream is empty
                expect(callbackStatusUpdates, isNotEmpty);
                expect(callbackProgressUpdates, isNotEmpty);
                expect(streamUpdates, isEmpty);
              } else {
                // No callback -> stream receives updates
                expect(callbackStatusUpdates, isEmpty);
                expect(callbackProgressUpdates, isEmpty);
                expect(
                  streamUpdates.whereType<TaskStatusUpdate>().map(
                    (u) => u.status,
                  ),
                  contains(TaskStatus.complete),
                );
                expect(
                  streamUpdates.whereType<TaskProgressUpdate>().map(
                    (u) => u.progress,
                  ),
                  equals([0.0, 0.25, 0.5, 0.75, 1.0]),
                );
              }

              // Verification 2: Database tracking
              if (trackTasks || approach == 'transfers') {
                // Transfers always tracks its group; explicit trackTasks tracks all
                final record = testStorage.records[task.taskId];
                expect(record, isNotNull);
                expect(record!.status, equals(TaskStatus.complete));
              } else {
                expect(testStorage.records[task.taskId], isNull);
              }

              await subscription.cancel();
            },
          );
        }
      }
    }
  });
}
