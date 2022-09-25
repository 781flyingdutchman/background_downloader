import 'dart:async';


import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

void main() {
  Logger.root.onRecord.listen((LogRecord rec) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  runApp(const MyApp());
}

void myStatusCallback(BackgroundDownloadTask task, DownloadTaskStatus status) {
  print("in my callback with $task and $status");
}

void myProgressCallback(
BackgroundDownloadTask task, double progress) {
  print('In progress callback with $task and $progress');
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    int platformVersion = 100;

    FileDownloader.initialize(downloadStatusCallback: myStatusCallback, downloadProgressCallback: myProgressCallback);

    await FileDownloader.reset();

    for (var n = 0; n < 1; n++) {
      final backgroundDownloadTask = BackgroundDownloadTask(
          taskId: 'taskId$n',
          url: "http://speedtest.ftp.otenet.gr/files/test10Mb.db",
          filename: "filename$n",
          directory: "directory",
          baseDirectory: BaseDirectory.applicationDocuments,
      progressUpdates: DownloadTaskProgressUpdates.statusChange);
      await FileDownloader.enqueue(backgroundDownloadTask);
    }
    var taskIds = await FileDownloader.allTaskIds();
    print('All taskIds = $taskIds');
    // await FileDownloader.cancelTasksWithIds(taskIds.sublist(2));

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _platformVersion = 'Version $platformVersion';
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Text('Running on: $_platformVersion\n'),
        ),
      ),
    );
  }
}
