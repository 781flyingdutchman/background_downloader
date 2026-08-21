// ignore_for_file: avoid_print, empty_catches

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:path_provider/path_provider.dart';

import 'test_utils.dart';

/// Helper to get a unique custom temporary directory
Future<Directory> getCustomTempDir({String suffix = ''}) async {
  final base = await getTemporaryDirectory();
  final name = 'custom_temp_${DateTime.now().millisecondsSinceEpoch}$suffix';
  return Directory(join(base.path, name));
}

void main() {
  setUp(defaultSetup);

  tearDown(() async {
    // Reset tempFilePath config to default after each test
    await FileDownloader().configure(
      globalConfig: (Config.tempFilePath, Config.never),
    );
    await FileDownloader().configure(globalConfig: (Config.mTLS, false));
    await defaultTearDown();
  });

  group('Config.tempFilePath', () {
    test(
      'configure tempFilePath returns expected status per platform',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        final customDir = await getCustomTempDir();
        final customPath = customDir.path;

        // Test globalConfig
        final result = await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, customPath),
        );
        expect(result.length, equals(1));
        expect(result.first.$1, equals(Config.tempFilePath));
        if (Platform.isIOS) {
          expect(result.first.$2, equals('not implemented'));
        } else {
          expect(result.first.$2, equals(''));
        }

        // Test reset with Config.never
        final resetResultNever = await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, Config.never),
        );
        expect(resetResultNever.first.$1, equals(Config.tempFilePath));
        if (Platform.isIOS) {
          expect(resetResultNever.first.$2, equals('not implemented'));
        } else {
          expect(resetResultNever.first.$2, equals(''));
        }

        // Test reset with false
        final resetResultFalse = await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, false),
        );
        expect(resetResultFalse.first.$1, equals(Config.tempFilePath));
        if (Platform.isIOS) {
          expect(resetResultFalse.first.$2, equals('not implemented'));
        } else {
          expect(resetResultFalse.first.$2, equals(''));
        }

        // Test reset with empty string
        final resetResultEmpty = await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, ''),
        );
        expect(resetResultEmpty.first.$1, equals(Config.tempFilePath));
        if (Platform.isIOS) {
          expect(resetResultEmpty.first.$2, equals('not implemented'));
        } else {
          expect(resetResultEmpty.first.$2, equals(''));
        }

        // Test platform-specific configurations
        if (Platform.isAndroid) {
          final androidResult = await FileDownloader().configure(
            androidConfig: (Config.tempFilePath, customPath),
          );
          expect(androidResult.first.$1, equals(Config.tempFilePath));
          expect(androidResult.first.$2, equals(''));
        } else if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
          final desktopResult = await FileDownloader().configure(
            desktopConfig: (Config.tempFilePath, customPath),
          );
          expect(desktopResult.first.$1, equals(Config.tempFilePath));
          expect(desktopResult.first.$2, equals(''));
        } else if (Platform.isIOS) {
          final iOSResult = await FileDownloader().configure(
            iOSConfig: (Config.tempFilePath, customPath),
          );
          expect(iOSResult.first.$1, equals(Config.tempFilePath));
          expect(iOSResult.first.$2, equals('not implemented'));
        }
      },
    );

    testWidgets(
      'download completes successfully with tempFilePath configured',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        final customDir = await getCustomTempDir();
        if (!customDir.existsSync()) {
          customDir.createSync(recursive: true);
        }

        await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, customDir.path),
        );

        FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.status,
        );

        final docDir = await getApplicationDocumentsDirectory();
        final destinationFile = File(join(docDir.path, largeFilename));
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }

        final result = await FileDownloader().download(task);
        expect(result.status, equals(TaskStatus.complete));
        expect(destinationFile.existsSync(), isTrue);
        expect(
          destinationFile.lengthSync(),
          equals(urlWithContentLengthFileSize),
        );

        // Clean up
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }
        if (customDir.existsSync()) {
          customDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'temp file is placed in custom directory during pause and cleaned up on completion',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        final customDir = await getCustomTempDir();
        if (!customDir.existsSync()) {
          customDir.createSync(recursive: true);
        }

        await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, customDir.path),
        );

        FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback,
        );

        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.statusAndProgress,
          allowPause: true,
        );

        final docDir = await getApplicationDocumentsDirectory();
        final destinationFile = File(join(docDir.path, largeFilename));
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }

        expect(await FileDownloader().enqueue(task), isTrue);
        await someProgressCompleter.future;

        expect(await FileDownloader().pause(task), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));

        final downloader = FileDownloader().downloaderForTesting;
        final resumeData = await downloader.getResumeData(task.taskId);
        expect(resumeData, isNotNull);

        final tempFilePath = resumeData!.tempFilepath;
        expect(tempFilePath.startsWith(customDir.path), isTrue);
        expect(File(tempFilePath).existsSync(), isTrue);
        expect(
          File(tempFilePath).lengthSync(),
          equals(resumeData.requiredStartByte),
        );

        // Resume and verify completion cleans up temp file
        statusCallbackCompleter = Completer<void>();
        expect(await FileDownloader().resume(task), isTrue);
        await statusCallbackCompleter.future;
        expect(lastStatus, equals(TaskStatus.complete));

        expect(destinationFile.existsSync(), isTrue);
        expect(
          destinationFile.lengthSync(),
          equals(urlWithContentLengthFileSize),
        );
        expect(File(tempFilePath).existsSync(), isFalse);

        // Clean up
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }
        if (customDir.existsSync()) {
          customDir.deleteSync(recursive: true);
        }
      },
      skip: Platform.isIOS,
    );

    testWidgets(
      'custom temp directory is created automatically if it does not exist',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        final customDir = await getCustomTempDir(suffix: '_nonexistent/nested');
        if (customDir.existsSync()) {
          customDir.deleteSync(recursive: true);
        }
        expect(customDir.existsSync(), isFalse);

        await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, customDir.path),
        );

        FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback,
        );

        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.statusAndProgress,
          allowPause: true,
        );

        expect(await FileDownloader().enqueue(task), isTrue);
        await someProgressCompleter.future;

        expect(await FileDownloader().pause(task), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));

        // Verify directory was created
        expect(customDir.existsSync(), isTrue);

        final downloader = FileDownloader().downloaderForTesting;
        final resumeData = await downloader.getResumeData(task.taskId);
        expect(resumeData, isNotNull);

        final tempFilePath = resumeData!.tempFilepath;
        expect(tempFilePath.startsWith(customDir.path), isTrue);
        expect(File(tempFilePath).existsSync(), isTrue);

        // Cancel and verify cleanup
        expect(
          await FileDownloader().cancelTasksWithIds([task.taskId]),
          isTrue,
        );
        await Future.delayed(const Duration(milliseconds: 300));
        expect(lastStatus, equals(TaskStatus.canceled));
        expect(File(tempFilePath).existsSync(), isFalse);

        if (customDir.existsSync()) {
          customDir.deleteSync(recursive: true);
        }
      },
      skip: Platform.isIOS,
    );

    testWidgets(
      'task cancellation deletes temp file in custom directory',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        final customDir = await getCustomTempDir();
        if (!customDir.existsSync()) {
          customDir.createSync(recursive: true);
        }

        await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, customDir.path),
        );

        FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback,
        );

        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.statusAndProgress,
          allowPause: true,
        );

        expect(await FileDownloader().enqueue(task), isTrue);
        await someProgressCompleter.future;

        expect(await FileDownloader().pause(task), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));

        final downloader = FileDownloader().downloaderForTesting;
        final resumeData = await downloader.getResumeData(task.taskId);
        expect(resumeData, isNotNull);

        final tempFilePath = resumeData!.tempFilepath;
        expect(File(tempFilePath).existsSync(), isTrue);
        expect(tempFilePath.startsWith(customDir.path), isTrue);

        // Cancel task and verify temp file is deleted
        expect(
          await FileDownloader().cancelTasksWithIds([task.taskId]),
          isTrue,
        );
        await Future.delayed(const Duration(milliseconds: 300));
        expect(lastStatus, equals(TaskStatus.canceled));
        expect(File(tempFilePath).existsSync(), isFalse);

        if (customDir.existsSync()) {
          customDir.deleteSync(recursive: true);
        }
      },
      skip: Platform.isIOS,
    );

    testWidgets(
      'resetting tempFilePath reverts to default temp directory',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        final customDir = await getCustomTempDir();
        if (!customDir.existsSync()) {
          customDir.createSync(recursive: true);
        }

        // Configure custom path first
        await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, customDir.path),
        );

        // Then reset to default
        await FileDownloader().configure(
          globalConfig: (Config.tempFilePath, Config.never),
        );

        FileDownloader().registerCallbacks(
          taskStatusCallback: statusCallback,
          taskProgressCallback: progressCallback,
        );

        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.statusAndProgress,
          allowPause: true,
        );

        expect(await FileDownloader().enqueue(task), isTrue);
        await someProgressCompleter.future;

        expect(await FileDownloader().pause(task), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        expect(lastStatus, equals(TaskStatus.paused));

        final downloader = FileDownloader().downloaderForTesting;
        final resumeData = await downloader.getResumeData(task.taskId);
        expect(resumeData, isNotNull);

        final tempFilePath = resumeData!.tempFilepath;
        expect(File(tempFilePath).existsSync(), isTrue);
        // Verify it is NOT using the custom directory
        expect(tempFilePath.startsWith(customDir.path), isFalse);

        // Clean up task
        await FileDownloader().cancelTasksWithIds([task.taskId]);

        if (customDir.existsSync()) {
          customDir.deleteSync(recursive: true);
        }
      },
      skip: Platform.isIOS,
    );
  });

  group('Config.mTLS', () {
    test(
      'configure mTLS returns expected status per platform',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        const config = MTLSConfig(
          host: 'api.example.com',
          certificateBytes: [1, 2, 3, 4],
          privateKeyBytes: [5, 6, 7, 8],
        );

        // Test globalConfig
        final result = await FileDownloader().configure(
          globalConfig: (Config.mTLS, config),
        );
        expect(result.length, equals(1));
        expect(result.first.$1, equals(Config.mTLS));
        if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
          expect(result.first.$2, equals(''));
        } else {
          expect(result.first.$2, equals('not implemented'));
        }

        // Test reset with false
        final resetResultFalse = await FileDownloader().configure(
          globalConfig: (Config.mTLS, false),
        );
        expect(resetResultFalse.first.$1, equals(Config.mTLS));
        if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
          expect(resetResultFalse.first.$2, equals(''));
        } else {
          expect(resetResultFalse.first.$2, equals('not implemented'));
        }

        // Test reset with null
        final resetResultNull = await FileDownloader().configure(
          globalConfig: (Config.mTLS, null),
        );
        expect(resetResultNull.first.$1, equals(Config.mTLS));
        if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
          expect(resetResultNull.first.$2, equals(''));
        } else {
          expect(resetResultNull.first.$2, equals('not implemented'));
        }

        // Test platform-specific configurations
        if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
          final desktopResult = await FileDownloader().configure(
            desktopConfig: (Config.mTLS, config),
          );
          expect(desktopResult.first.$1, equals(Config.mTLS));
          expect(desktopResult.first.$2, equals(''));
        } else if (Platform.isAndroid) {
          final androidResult = await FileDownloader().configure(
            androidConfig: (Config.mTLS, config),
          );
          expect(androidResult.first.$1, equals(Config.mTLS));
          expect(androidResult.first.$2, equals('not implemented'));
        } else if (Platform.isIOS) {
          final iOSResult = await FileDownloader().configure(
            iOSConfig: (Config.mTLS, config),
          );
          expect(iOSResult.first.$1, equals(Config.mTLS));
          expect(iOSResult.first.$2, equals('not implemented'));
        }
      },
    );

    test(
      'configure multiple host-specific mTLS entries and reset per host',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        const configA = MTLSConfig(
          host: 'server-a.example.com',
          certificateBytes: [1, 2, 3],
          privateKeyBytes: [4, 5, 6],
        );
        const configB = MTLSConfig(
          host: 'server-b.example.com',
          certificateBytes: [7, 8, 9],
          privateKeyBytes: [10, 11, 12],
        );

        final result = await FileDownloader().configure(
          desktopConfig: [(Config.mTLS, configA), (Config.mTLS, configB)],
        );

        expect(result.length, equals(2));
        expect(result.every((r) => r.$1 == Config.mTLS && r.$2 == ''), isTrue);
        expect(DesktopDownloader.mtlsConfigs.length, equals(2));
        expect(
          DesktopDownloader.mtlsConfigs.map((c) => c.host),
          containsAll(['server-a.example.com', 'server-b.example.com']),
        );

        // Reset server-a only
        await FileDownloader().configure(
          desktopConfig: (
            Config.mTLS,
            const MTLSConfig(host: 'server-a.example.com'),
          ),
        );
        expect(DesktopDownloader.mtlsConfigs.length, equals(1));
        expect(
          DesktopDownloader.mtlsConfigs.first.host,
          equals('server-b.example.com'),
        );

        // Reset all with false
        await FileDownloader().configure(desktopConfig: (Config.mTLS, false));
        expect(DesktopDownloader.mtlsConfigs, isEmpty);
      },
      skip: !(Platform.isMacOS || Platform.isLinux || Platform.isWindows),
    );

    testWidgets(
      'download completes successfully when mTLS is configured for an unrelated host',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        const unrelatedConfig = MTLSConfig(
          host: 'unrelated.secure.example.com',
          certificateBytes: [1, 2, 3],
          privateKeyBytes: [4, 5, 6],
        );

        await FileDownloader().configure(
          desktopConfig: (Config.mTLS, unrelatedConfig),
        );

        FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.status,
        );

        final docDir = await getApplicationDocumentsDirectory();
        final destinationFile = File(join(docDir.path, largeFilename));
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }

        final result = await FileDownloader().download(task);
        expect(result.status, equals(TaskStatus.complete));
        expect(destinationFile.existsSync(), isTrue);
        expect(
          destinationFile.lengthSync(),
          equals(urlWithContentLengthFileSize),
        );

        // Clean up
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }
      },
      skip: !(Platform.isMacOS || Platform.isLinux || Platform.isWindows),
    );

    testWidgets(
      'download to host matching mTLS configuration uses dedicated mTLS HTTP client and applies SecurityContext',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        const localConfig = MTLSConfig(
          host: '127.0.0.1',
          certificateBytes: [1, 2, 3],
          privateKeyBytes: [4, 5, 6],
        );

        await FileDownloader().configure(
          desktopConfig: (Config.mTLS, localConfig),
        );

        FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.status,
        );

        final result = await FileDownloader().download(task);
        // Fails because [1, 2, 3] is invalid PKCS/X509 data, proving the mTLS client is used and SecurityContext is applied
        expect(result.status, equals(TaskStatus.failed));
        expect(result.exception?.description, contains('Certificate'));
      },
      skip: !(Platform.isMacOS || Platform.isLinux || Platform.isWindows),
    );

    testWidgets(
      'download completes successfully after mTLS is configured and reset',
      timeout: const Timeout(Duration(minutes: 2)),
      (widgetTester) async {
        const config = MTLSConfig(
          certificateBytes: [1, 2, 3],
          privateKeyBytes: [4, 5, 6],
        );

        await FileDownloader().configure(desktopConfig: (Config.mTLS, config));
        await FileDownloader().configure(desktopConfig: (Config.mTLS, false));

        FileDownloader().registerCallbacks(taskStatusCallback: statusCallback);
        task = DownloadTask(
          url: urlWithContentLength,
          filename: largeFilename,
          updates: Updates.status,
        );

        final docDir = await getApplicationDocumentsDirectory();
        final destinationFile = File(join(docDir.path, largeFilename));
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }

        final result = await FileDownloader().download(task);
        expect(result.status, equals(TaskStatus.complete));
        expect(destinationFile.existsSync(), isTrue);
        expect(
          destinationFile.lengthSync(),
          equals(urlWithContentLengthFileSize),
        );

        // Clean up
        if (destinationFile.existsSync()) {
          destinationFile.deleteSync();
        }
      },
      skip: !(Platform.isMacOS || Platform.isLinux || Platform.isWindows),
    );
  });
}
