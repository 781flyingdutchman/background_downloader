import 'dart:convert';
import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/json_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent initialization race condition', () async {
    // This test simulates multiple concurrent calls to JsonProcessor.decodeTask
    // to trigger the race condition in _ensureStarted.

    final task = DownloadTask(url: 'https://google.com', filename: 'test');
    final jsonString = jsonEncode(task.toJson());

    final futures = <Future>[];
    // Launch many concurrent requests.
    // Ideally, this hits the window where _isolate is not null but _sendPort is null.
    for (int i = 0; i < 100; i++) {
      futures.add(JsonProcessor().decodeTask(jsonString));
    }

    final results = await Future.wait(futures);
    expect(results.length, equals(100));
    for (var result in results) {
      expect(result, isA<DownloadTask>());
    }
  });
}
