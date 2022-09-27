import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

import 'widgets.dart';

void main() {
  Logger.root.onRecord.listen((LogRecord rec) {
    print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final buttonTexts = ['Download', 'Cancel', 'Reset'];

  ButtonState buttonState = ButtonState.download;
  bool downloadWithError = false;
  DownloadTaskStatus downloadTaskStatus = DownloadTaskStatus.undefined;
  BackgroundDownloadTask? backgroundDownloadTask;
  StreamController<DownloadProgressIndicatorUpdate> updateStream =
      StreamController();

  @override
  void initState() {
    super.initState();
    FileDownloader.initialize(
        downloadStatusCallback: myDownloadStatusCallback,
        downloadProgressCallback: myDownloadProgressCallback);
  }

  /// Process the status updates coming from the downloader
  ///
  /// Stores the task status
  void myDownloadStatusCallback(
      BackgroundDownloadTask task, DownloadTaskStatus status) {
    if (task == backgroundDownloadTask) {
      buttonState = status == DownloadTaskStatus.running
          ? ButtonState.cancel
          : ButtonState.reset;
      setState(() {
        downloadTaskStatus = status;
      });
    }
  }

  /// Process the progress updates coming from the downloader
  ///
  /// Adds an update object to the stream that the main UI listens to
  void myDownloadProgressCallback(
      BackgroundDownloadTask task, double progress) {
    updateStream.add(DownloadProgressIndicatorUpdate(task.filename, progress));
  }

  @override
  Widget build(BuildContext context) {
    return StreamProvider<DownloadProgressIndicatorUpdate>.value(
        value: updateStream.stream,
        initialData: DownloadProgressIndicatorUpdate('', 1),
        child: MaterialApp(
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
                                  style:
                                      Theme.of(context).textTheme.headline6)),
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
                            .headline4
                            ?.copyWith(color: Colors.white),
                      ),
                    )),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          const Expanded(child: Text('File download status:')),
                          Text('$downloadTaskStatus')
                        ],
                      ),
                    )
                  ],
                ),
              )),
              bottomSheet: const DownloadProgressIndicator()),
        ));
  }

  Future<void> processButtonPress() async {
    switch (buttonState) {
      case ButtonState.download:
        // start download
        backgroundDownloadTask = BackgroundDownloadTask(
            url: downloadWithError
                ? 'https://sitethatdoesnotexist.com'
                : 'https://github.com/yourkin/fileupload-fastapi/raw/a85a697cab2f887780b3278059a0dd52847d80f3/tests/data/test-5mb.bin',
            filename: 'zipfile.zip',
            directory: 'my/directory',
            baseDirectory: BaseDirectory.applicationDocuments,
            progressUpdates:
                DownloadTaskProgressUpdates.statusChangeAndProgressUpdates);
        await FileDownloader.enqueue(backgroundDownloadTask!);
        break;
      case ButtonState.cancel:
        // cancel download
        if (backgroundDownloadTask != null) {
          await FileDownloader.cancelTasksWithIds(
              [backgroundDownloadTask!.taskId]);
        }
        break;
      case ButtonState.reset:
        downloadTaskStatus = DownloadTaskStatus.undefined;
        buttonState = ButtonState.download;
        break;
    }
    if (mounted) {
      setState(() {});
    }
  }
}

enum ButtonState { download, cancel, reset }
