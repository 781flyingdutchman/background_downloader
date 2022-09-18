import 'package:flutter/material.dart';
import 'dart:async';
import 'package:file_downloader/file_downloader.dart';

void main() {
  runApp(const MyApp());
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

    FileDownloader.initialize();
    await FileDownloader.resetDownloadWorker();
    // await FlutterDownloader.initializeDownloadWorker();
    await FileDownloader.enqueueSomeTasks();
    // await Future.delayed(const Duration(seconds: 5));
    // await FlutterDownloader.moveToBackground();



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
