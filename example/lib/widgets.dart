import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DownloadProgressIndicatorUpdate {
  final String filename;
  final double progress;

  DownloadProgressIndicatorUpdate(this.filename, this.progress);

  bool get busy => progress >= 0 && progress < 1;
}

/// Displays progress indicator for FileDownloader download
///
/// Also listens to internet connectivity state, and adjusts widget
/// accordingly
class DownloadProgressIndicator extends StatefulWidget {
  const DownloadProgressIndicator({Key? key}) : super(key: key);

  @override
  State<DownloadProgressIndicator> createState() =>
      _DownloadProgressIndicatorState();
}

class _DownloadProgressIndicatorState extends State<DownloadProgressIndicator> {
  late StreamSubscription<ConnectivityResult>? connectivityStatusSubscription;
  ValueNotifier<bool> haveConnection = ValueNotifier(false);
  bool showProgress = false;

  @override
  void initState() {
    super.initState();
    // monitor data connection
    Connectivity().checkConnectivity().then(
        (result) => haveConnection.value = result != ConnectivityResult.none);
    connectivityStatusSubscription = Connectivity()
        .onConnectivityChanged
        .listen((result) =>
            haveConnection.value = result != ConnectivityResult.none);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadProgressIndicatorUpdate>(
        builder: (context, update, _) {
      showProgress = update.busy;
      return ValueListenableBuilder(
          valueListenable: haveConnection,
          builder: (context, bool connected, _) {
            if (connected) {
              return AnimatedContainer(
                  height: showProgress ? 35 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8.0, right: 8.0),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            'Downloading ${update.filename}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: update.progress,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('${(update.progress * 100).round()}%'),
                        )
                      ],
                    ),
                  ));
            } else {
              // no connection, show earning if progress indicator would
              // otherwise be visible
              return showProgress
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Container(
                        decoration: BoxDecoration(
                            border: Border.all(color: Colors.red, width: 1),
                            borderRadius: BorderRadius.circular(4)),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(
                            'Download required - will resume once data connection has been restored',
                            style: Theme.of(context).textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ))
                  : Container();
            }
          });
    });
  }

  @override
  void dispose() {
    connectivityStatusSubscription?.cancel();
    super.dispose();
  }
}
