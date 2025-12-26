import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Benchmark script to compare Sync vs Async IO for Localstore-like patterns.
/// Run with `dart test/benchmark_io.dart` (requires Dart SDK).

void main() async {
  print('Starting IO Benchmark...');
  final tempDir = Directory.systemTemp.createTempSync('benchmark_io_');
  print('Temp directory: ${tempDir.path}');

  final count = 1000;
  final data = {'key': 'value', 'index': 0, 'large_field': 'x' * 100};

  try {
    // 1. Benchmark Synchronous Write
    final syncWriteStart = DateTime.now();
    for (var i = 0; i < count; i++) {
      await _writeFileSync(data, '${tempDir.path}/sync_$i.json');
    }
    final syncWriteDuration = DateTime.now().difference(syncWriteStart);
    print('Sync Write ($count files): ${syncWriteDuration.inMilliseconds}ms');

    // 2. Benchmark Asynchronous Write
    final asyncWriteStart = DateTime.now();
    await Future.wait(List.generate(count, (i) {
      return _writeFileAsync(data, '${tempDir.path}/async_$i.json');
    }));
    final asyncWriteDuration = DateTime.now().difference(asyncWriteStart);
    print('Async Write ($count files): ${asyncWriteDuration.inMilliseconds}ms');

    // 3. Benchmark Synchronous Read
    final syncReadStart = DateTime.now();
    for (var i = 0; i < count; i++) {
      final file = File('${tempDir.path}/sync_$i.json');
      final raf = file.openSync(mode: FileMode.read);
      _readFileSync(raf);
      raf.closeSync();
    }
    final syncReadDuration = DateTime.now().difference(syncReadStart);
    print('Sync Read ($count files): ${syncReadDuration.inMilliseconds}ms');

    // 4. Benchmark Asynchronous Read
    final asyncReadStart = DateTime.now();
    await Future.wait(List.generate(count, (i) async {
      final file = File('${tempDir.path}/async_$i.json');
      final raf = await file.open(mode: FileMode.read);
      await _readFileAsync(raf);
      await raf.close();
    }));
    final asyncReadDuration = DateTime.now().difference(asyncReadStart);
    print('Async Read ($count files): ${asyncReadDuration.inMilliseconds}ms');

    print('\nSummary:');
    print('Write Speedup: ${(syncWriteDuration.inMilliseconds / asyncWriteDuration.inMilliseconds).toStringAsFixed(2)}x');
    print('Read Speedup: ${(syncReadDuration.inMilliseconds / asyncReadDuration.inMilliseconds).toStringAsFixed(2)}x');

  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

// --- Sync Implementations ---

Future<void> _writeFileSync(Map<String, dynamic> data, String path) async {
  // Simulating async wrapper around sync IO as in original code
  await Future.delayed(Duration.zero);
  final serialized = json.encode(data);
  final buffer = utf8.encode(serialized);
  final file = File(path);
  final randomAccessFile = file.openSync(mode: FileMode.append);
  randomAccessFile.lockSync();
  randomAccessFile.setPositionSync(0);
  randomAccessFile.writeFromSync(buffer);
  randomAccessFile.truncateSync(buffer.length);
  randomAccessFile.unlockSync();
  randomAccessFile.closeSync();
}

Map<String, dynamic> _readFileSync(RandomAccessFile file) {
  final length = file.lengthSync();
  file.setPositionSync(0);
  final buffer = Uint8List(length);
  file.readIntoSync(buffer);
  final contentText = utf8.decode(buffer);
  return json.decode(contentText) as Map<String, dynamic>;
}

// --- Async Implementations ---

Future<void> _writeFileAsync(Map<String, dynamic> data, String path) async {
  final serialized = json.encode(data);
  final buffer = utf8.encode(serialized);
  final file = File(path);
  final randomAccessFile = await file.open(mode: FileMode.append);
  await randomAccessFile.lock();
  await randomAccessFile.setPosition(0);
  await randomAccessFile.writeFrom(buffer);
  await randomAccessFile.truncate(buffer.length);
  await randomAccessFile.unlock();
  await randomAccessFile.close();
}

Future<Map<String, dynamic>> _readFileAsync(RandomAccessFile file) async {
  final length = await file.length();
  await file.setPosition(0);
  final buffer = Uint8List(length);
  await file.readInto(buffer);
  final contentText = utf8.decode(buffer);
  return json.decode(contentText) as Map<String, dynamic>;
}
