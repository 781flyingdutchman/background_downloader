import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/localstore/localstore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Mock path_provider to return a temporary directory
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        final directory = await Directory.systemTemp.createTemp('localstore_test');
        return directory.path;
      },
    );
  });

  test('Localstore concurrency test: multiple writes and reads', () async {
    final db = Localstore.instance;
    final collection = db.collection('concurrency_test');
    final docId = 'concurrent_record';
    final docRef = collection.doc(docId);

    // Initial write
    await docRef.set({'count': 0});

    final int operations = 50;
    final List<Future> futures = [];
    final random = Random();

    // Concurrent writes and reads
    for (int i = 0; i < operations; i++) {
      // Write operation
      futures.add(Future(() async {
        await Future.delayed(Duration(milliseconds: random.nextInt(10)));
        // Write significant data to ensure IO takes some time
        await docRef.set({
          'count': i,
          'data': 'x' * 5000 + i.toString(),
          'timestamp': DateTime.now().toIso8601String()
        });
      }));

      // Read operation
      futures.add(Future(() async {
        await Future.delayed(Duration(milliseconds: random.nextInt(10)));
        final data = await docRef.get();
        if (data != null) {
          // Check for data integrity (basic check)
          expect(data['data'], isNotNull);
          // Ensure we didn't read a partially written file (e.g. invalid JSON would throw before here)
        }
      }));
    }

    // Wait for all operations to complete
    await Future.wait(futures);

    // Verify final state is readable
    final finalData = await docRef.get();
    expect(finalData, isNotNull);
    expect(finalData!['data'], isNotNull);
    print('Concurrency test completed successfully.');
  });
}
