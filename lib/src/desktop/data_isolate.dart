import 'dart:async';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../../background_downloader.dart';
import 'desktop_downloader.dart';
import 'download_isolate.dart';
import 'isolate.dart';

/// Do the data task
///
/// Sends updates via the [sendPort] and can be commanded to cancel via
/// the [messagesToIsolate] queue
Future<void> doDataTask(DataTask task, SendPort sendPort) async {
  final client = DesktopDownloader.httpClient;
  var request = http.Request(task.httpRequestMethod, Uri.parse(task.url));
  request.headers.addAll(task.headers);
  if (task.post is String) {
    request.body = task.post!;
  }
  var resultStatus = TaskStatus.failed;
  try {
    final response = await client.send(request);
    if (!isCanceled) {
      responseHeaders = response.headers;
      responseStatusCode = response.statusCode;
      extractContentType(response.headers);
      responseBody = await responseContent(response);
      if (okResponses.contains(response.statusCode)) {
        resultStatus = TaskStatus.complete;
      } else {
        if (response.statusCode == 404) {
          resultStatus = TaskStatus.notFound;
        } else {
          taskException = TaskHttpException(
              responseBody?.isNotEmpty == true
                  ? responseBody!
                  : response.reasonPhrase ?? 'Invalid HTTP Request',
              response.statusCode);
        }
      }
    }
  } catch (e) {
    logError(task, e.toString());
    setTaskError(e);
  }
  if (isCanceled) {
    // cancellation overrides other results
    resultStatus = TaskStatus.canceled;
  }
  processStatusUpdateInIsolate(task, resultStatus, sendPort);
}
