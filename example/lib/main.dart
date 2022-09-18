import 'package:file_downloader/file_downloader.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import 'package:logging/logging.dart';


void main() {
  runApp(const MyApp());
}

void myCallback(String taskId, bool success) {
  print("in my callback with $taskId and $success");
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

    FileDownloader.initialize(callback: myCallback);
    FileDownloader.initialize();

    await FileDownloader.resetDownloadWorker();

      for (var n = 0; n < 5; n++) {
        final backgroundDownloadTask = BackgroundDownloadTask(
            taskId: 'taskId$n',
            url: "https://google.com",
            filename: "filename$n",
            directory: "directory",
            baseDirectory: BaseDirectory.applicationDocuments);
        FileDownloader.enqueue(backgroundDownloadTask);
      }




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
