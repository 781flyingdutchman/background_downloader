import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';


void main() {
  test('TaskProgressUpdate', () {
    final task = DownloadTask(url: 'http://google.com');
    var update = TaskProgressUpdate(task, 0.1);
    expect(update.hasExpectedFileSize, isFalse);
    expect(update.hasDownloadSpeed, isFalse);
    expect(update.hasTimeRemaining, isFalse);
    update = TaskProgressUpdate(task, 0.1, 123, 0.2, const Duration(seconds: 30));
    expect(update.hasExpectedFileSize, isTrue);
    expect(update.hasDownloadSpeed, isTrue);
    expect(update.hasTimeRemaining, isTrue);
    expect(update.downloadSpeedAsString, equals('200 kB/s'));
    expect(update.timeRemainingAsString, equals('00:30'));
    update = TaskProgressUpdate(task, 0.1, 123, 2, const Duration(seconds: 90));
    expect(update.downloadSpeedAsString, equals('2 MB/s'));
    expect(update.timeRemainingAsString, equals('01:30'));
    update = TaskProgressUpdate(task, 0.1, 123, 1.1, const Duration(seconds: 3610));
    expect(update.downloadSpeedAsString, equals('1 MB/s'));
    expect(update.timeRemainingAsString, equals('1:00:10'));
  });
}
