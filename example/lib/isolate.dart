import 'dart:isolate';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';

/// This is the entry point for the background isolate.
/// It downloads a single file and then waits a bit.
@pragma('vm:entry-point')
Future<void> backgroundIsolateEntryPoint(RootIsolateToken rootIsolateToken) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  await download();
  await Future<void>.delayed(const Duration(seconds: 2));
}

/// Downloads a file
Future<void> download() async {
  await FileDownloader()
      .enqueue(
        DownloadTask(
          url:
              'https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP',
          filename: 'File_${Random().nextInt(1000)}',
          group: 'bunch',
          updates: Updates.statusAndProgress,
        ),
      )
      .timeout(const Duration(seconds: 2));
}

Future<String> testBackgroundUsage() async {
  try {
    // Download a file in foreground
    await download();
  } catch (e) {
    return 'failure 1st: $e';
  }

  // Download a file in background
  try {
    final rootIsolateToken = RootIsolateToken.instance!;
    await Isolate.run(() => backgroundIsolateEntryPoint(rootIsolateToken));
  } catch (e) {
    return 'failure background: $e';
  }

  try {
    // Download another file in foreground
    await download();
    return 'success';
  } catch (e) {
    return 'failure 2nd: $e';
  }
}
