import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Documents directory path containing regex metacharacters
const basePath = '/tmp/user (1)+x';

/// Temporary directory path that is a prefix of a sibling directory
const tempPath = '/tmp/docs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => basePath,
            'getTemporaryDirectory' => tempPath,
            _ => '/other/${call.method}',
          },
        );
  });

  test('split matches a base directory containing regex metacharacters',
      () async {
    final (baseDirectory, directory, filename) = await Task.split(
      filePath: '$basePath/sub/dir/file.txt',
    );
    expect(baseDirectory, equals(BaseDirectory.applicationDocuments));
    expect(directory, equals('sub/dir'));
    expect(filename, equals('file.txt'));
    final (baseDirectory2, directory2, _) = await Task.split(
      filePath: '$basePath/file.txt',
    );
    expect(baseDirectory2, equals(baseDirectory));
    expect(directory2, equals(''));
  });

  test('split does not match a sibling directory sharing a prefix', () async {
    final (baseDirectory, directory, filename) = await Task.split(
      filePath: '${tempPath}2/sub/file.txt',
    );
    expect(baseDirectory, equals(BaseDirectory.root));
    expect(directory, equals('tmp/docs2/sub'));
    expect(filename, equals('file.txt'));
  });
}
