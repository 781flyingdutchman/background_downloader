import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/src/localstore/localstore.dart';
import 'package:flutter/foundation.dart';
import 'dart:math';

void main() {
  setUp(() async {
    Localstore.instance.clearCache();
  });

  tearDown(() async {
    Localstore.instance.clearCache();
  });

  test('Localstore sequential read/write/delete', () async {
    final stopwatch = Stopwatch()..start();
    final db = Localstore.instance;
    final collection = db.collection('test_collection_seq');

    for (var i = 0; i < 50; i++) {
      final id = 'seq_$i';
      final data = {
        'id': id,
        'value': 'test_$i',
        'ts': DateTime.now().toIso8601String()
      };

      // Write
      await collection.doc(id).set(data);

      // Read
      final readData = await collection.doc(id).get();
      expect(readData, equals(data));

      // Delete
      await collection.doc(id).delete();

      // Verify deletion
      final deletedData = await collection.doc(id).get();
      expect(deletedData, isNull);
    }
    stopwatch.stop();
    debugPrint(
        'Test "Localstore sequential read/write/delete" took ${stopwatch.elapsedMilliseconds}ms');
  });

  test('Localstore simultaneous stress test', () async {
    final stopwatch = Stopwatch()..start();
    final db = Localstore.instance;
    final collection = db.collection('test_collection_sim');
    final rng = Random();

    final futures = List<Future<void>>.generate(50, (index) async {
      final id = 'sim_$index';
      final data = {
        'id': id,
        'value': rng.nextInt(10000),
        'ts': DateTime.now().millisecondsSinceEpoch
      };

      // Write
      await collection.doc(id).set(data);

      // Read and verify
      final readData = await collection.doc(id).get();
      expect(readData, equals(data));

      // Delete
      await collection.doc(id).delete();

      // Verify deletion
      final deletedData = await collection.doc(id).get();
      expect(deletedData, isNull);
    });

    await Future.wait(futures);
    stopwatch.stop();
    debugPrint(
        'Test "Localstore simultaneous stress test" took ${stopwatch.elapsedMilliseconds}ms');
  });

  test('Localstore aggressive overwrite test', () async {
    final stopwatch = Stopwatch()..start();
    final db = Localstore.instance;
    final collection = db.collection('test_collection_overwrite');
    const id = 'overwrite_id';

    for (var i = 0; i < 100; i++) {
      final data = {'value': i};
      await collection.doc(id).set(data);

      final readData = await collection.doc(id).get();
      expect(readData, equals(data), reason: 'Failed at iteration $i');
    }
    stopwatch.stop();
    debugPrint(
        'Test "Localstore aggressive overwrite test" took ${stopwatch.elapsedMilliseconds}ms');
  });
}
