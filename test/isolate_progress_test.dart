import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/isolate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('calculateTimeRemaining', () {
    test('returns negative duration for non-positive or non-finite speed', () {
      const unknown = Duration(seconds: -1);
      for (final speed in [
        0.0,
        -0.0,
        -1.0,
        -0.5,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          calculateTimeRemaining(
            progress: 0.5,
            expectedFileSize: 1000,
            networkSpeed: speed,
          ),
          equals(unknown),
        );
      }
    });

    test('returns negative duration for invalid file size or progress', () {
      const unknown = Duration(seconds: -1);
      expect(
        calculateTimeRemaining(
          progress: 0.5,
          expectedFileSize: -1,
          networkSpeed: 1.0,
        ),
        equals(unknown),
      );
      expect(
        calculateTimeRemaining(
          progress: 0.5,
          expectedFileSize: 0,
          networkSpeed: 1.0,
        ),
        equals(unknown),
      );
      expect(
        calculateTimeRemaining(
          progress: 1.2,
          expectedFileSize: 1000,
          networkSpeed: 1.0,
        ),
        equals(unknown),
      );
    });

    test(
      'returns negative duration when scaled microseconds overflow int64',
      () {
        const unknown = Duration(seconds: -1);
        expect(
          calculateTimeRemaining(
            progress: 0.5,
            expectedFileSize: 1000000000000,
            networkSpeed: 1e-12,
          ),
          equals(unknown),
        );
      },
    );

    test('calculates valid positive duration', () {
      expect(
        calculateTimeRemaining(
          progress: 0.5,
          expectedFileSize: 2000000,
          networkSpeed: 1.0,
        ),
        equals(const Duration(seconds: 1)),
      );
    });
  });

  group('processProgressUpdateInIsolate', () {
    setUp(() {
      bytesTotal = 0;
      bytesTotalAtLastProgressUpdate = 0;
      lastProgressUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
      networkSpeed = 0.0;
    });

    test(
      'does not throw when byte delta is zero after initial unknown speed',
      () async {
        final task = DownloadTask(
          url: 'https://example.com/file',
          updates: Updates.progress,
        );
        final port = ReceivePort();
        final events = <dynamic>[];
        final sub = port.listen(events.add);

        // First update (>1h since epoch): sets speed to -1.0 and updates timestamp
        bytesTotal = 0;
        processProgressUpdateInIsolate(task, 0.1, port.sendPort, 1000);

        // Second update within same millisecond or with zero bytes transferred
        processProgressUpdateInIsolate(task, 0.2, port.sendPort, 1000);

        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        port.close();

        expect(events.length, equals(2));
        final second =
            events[1] as (String, Task, double, int, double, Duration);
        expect(second.$6.isNegative, isTrue);
      },
    );
  });
}
