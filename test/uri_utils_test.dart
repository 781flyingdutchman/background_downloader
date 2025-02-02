import 'package:background_downloader/src/uri/uri_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

final testUrl = 'https://google.com';
final testUriWithFileScheme = Uri.parse('file:///test_file.txt');

void main() {
  group('pack and unpack', () {
    test('pack should pack filename and uri into a single string', () {
      const filename = 'myFile.txt';
      final uri = Uri.parse('content://com.example.app/document/123');

      final packedString = pack(filename, uri);

      expect(packedString, ':::$filename::::::${uri.toString()}:::');
    });

    test('unpack should unpack a valid packed string into filename and uri',
        () {
      const filename = 'myFile.txt';
      final uri = Uri.parse('content://com.example.app/document/123');
      final packedString = ':::$filename::::::${uri.toString()}:::';

      final (filename: unpackedFilename, uri: unpackedUri) =
          unpack(packedString);

      expect(unpackedFilename, filename);
      expect(unpackedUri, uri);
    });

    test(
        'unpack should return original string and null uri for simple filename string',
        () {
      const invalidPackedString = 'This is not a packed string';

      final (:filename, :uri) = unpack(invalidPackedString);

      expect(filename, invalidPackedString);
      expect(uri, isNull);
    });

    test('unpack should return null and a uri for simple uri string', () {
      const uriString = 'https://www.example.com/path/to/resource';

      final (:filename, :uri) = unpack(uriString);

      expect(filename, isNull);
      expect(uri.toString(), equals(uriString));
    });

    test('uriFromStringValue should return Uri for a valid Uri string', () {
      const uriString = 'https://www.example.com/path/to/resource';
      final expectedUri = Uri.parse(uriString);

      final resultUri = uriFromStringValue(uriString);

      expect(resultUri, expectedUri);
    });

    test('uriFromStringValue should return Uri from a valid packed string', () {
      const filename = 'myFile.txt';
      final uri = Uri.parse('content://com.example.app/document/123');
      final packedString = pack(filename, uri);

      final resultUri = uriFromStringValue(packedString);

      expect(resultUri, uri);
    });

    test('uriFromStringValue should return null for an invalid string', () {
      const invalidString = 'This is not a Uri or packed string';

      final resultUri = uriFromStringValue(invalidString);

      expect(resultUri, isNull);
    });

    test(
        'uriFromStringValue should return null for a packed string with invalid Uri',
        () {
      const filename = 'myFile.txt';
      const invalidUri = 'invalid';
      const packedString = ':::$filename::::::$invalidUri:::';

      final resultUri = uriFromStringValue(packedString);

      expect(resultUri, isNull);
    });
  });
}
