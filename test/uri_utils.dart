import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pack and unpack', () {
    test('pack should pack filename and uri into a single string', () {
      const filename = 'myFile.txt';
      final uri = Uri.parse('content://com.example.app/document/123');

      final packedString = UriUtils.pack(filename, uri);

      expect(packedString, ':::$filename::::::${uri.toString()}:::');
    });

    test(
        'unpack should unpack a valid packed string into filename and uri', () {
      const filename = 'myFile.txt';
      final uri = Uri.parse('content://com.example.app/document/123');
      final packedString = ':::$filename::::::${uri.toString()}:::';

      final (filename: unpackedFilename, uri: unpackedUri) = UriUtils.unpack(
          packedString);

      expect(unpackedFilename, filename);
      expect(unpackedUri, uri);
    });

    test(
        'unpack should return original string and null uri for invalid packed string', () {
      const invalidPackedString = 'This is not a packed string';

      final (:filename, :uri) = UriUtils.unpack(invalidPackedString);

      expect(filename, invalidPackedString);
      expect(uri, isNull);
    });

    test('uriFromStringValue should return Uri for a valid Uri string', () {
      const uriString = 'https://www.example.com/path/to/resource';
      final expectedUri = Uri.parse(uriString);

      final resultUri = UriUtils.uriFromStringValue(uriString);

      expect(resultUri, expectedUri);
    });

    test('uriFromStringValue should return Uri from a valid packed string', () {
      const filename = 'myFile.txt';
      final uri = Uri.parse('content://com.example.app/document/123');
      final packedString = UriUtils.pack(filename, uri);

      final resultUri = UriUtils.uriFromStringValue(packedString);

      expect(resultUri, uri);
    });

    test('uriFromStringValue should return null for an invalid string', () {
      const invalidString = 'This is not a Uri or packed string';

      final resultUri = UriUtils.uriFromStringValue(invalidString);

      expect(resultUri, isNull);
    });

    test(
        'uriFromStringValue should return null for a packed string with invalid Uri', () {
      const filename = 'myFile.txt';
      const invalidUri = 'invalid';
      const packedString = ':::$filename::::::$invalidUri:::';

      final resultUri = UriUtils.uriFromStringValue(packedString);

      expect(resultUri, isNull);
    });
  });
}