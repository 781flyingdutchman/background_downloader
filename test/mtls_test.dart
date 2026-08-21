import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    DesktopDownloader.resetMtlsConfig();
  });

  tearDown(() {
    DesktopDownloader.resetMtlsConfig();
  });

  group('MTLSConfig initialization and assertions', () {
    test('Valid path-based config', () {
      const config = MTLSConfig(
        host: 'api.example.com',
        certificatePath: '/path/to/cert.pem',
        privateKeyPath: '/path/to/key.pem',
        password: 'secretpassword',
      );

      expect(config.host, equals('api.example.com'));
      expect(config.certificatePath, equals('/path/to/cert.pem'));
      expect(config.privateKeyPath, equals('/path/to/key.pem'));
      expect(config.password, equals('secretpassword'));
      expect(config.hasCredentials, isTrue);
      expect(config.isReset, isFalse);
    });

    test('Valid byte-based config', () {
      const certBytes = [1, 2, 3, 4];
      const keyBytes = [5, 6, 7, 8];
      const config = MTLSConfig(
        certificateBytes: certBytes,
        privateKeyBytes: keyBytes,
      );

      expect(config.certificateBytes, equals(certBytes));
      expect(config.privateKeyBytes, equals(keyBytes));
      expect(config.hasCredentials, isTrue);
      expect(config.isReset, isFalse);
    });

    test('Valid reset config', () {
      const config = MTLSConfig(host: 'api.example.com');

      expect(config.host, equals('api.example.com'));
      expect(config.hasCredentials, isFalse);
      expect(config.isReset, isTrue);
    });

    test('Throws assertion error if both cert path and bytes are provided', () {
      expect(
        () => MTLSConfig(
          certificatePath: '/path/cert.pem',
          certificateBytes: const [1, 2, 3],
          privateKeyPath: '/path/key.pem',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('Throws assertion error if both key path and bytes are provided', () {
      expect(
        () => MTLSConfig(
          certificatePath: '/path/cert.pem',
          privateKeyPath: '/path/key.pem',
          privateKeyBytes: const [1, 2, 3],
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('Throws assertion error if certificate provided without key', () {
      expect(
        () => MTLSConfig(certificatePath: '/path/cert.pem'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('Throws assertion error if key provided without certificate', () {
      expect(
        () => MTLSConfig(privateKeyPath: '/path/key.pem'),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('MTLSConfig equality', () {
    test('equality and hashCode', () {
      const config1 = MTLSConfig(
        host: 'api.example.com',
        certificatePath: '/path/to/cert.pem',
        privateKeyPath: '/path/to/key.pem',
        password: 'password123',
        serverCertificateBytes: [10, 20, 30],
      );
      const config2 = MTLSConfig(
        host: 'api.example.com',
        certificatePath: '/path/to/cert.pem',
        privateKeyPath: '/path/to/key.pem',
        password: 'password123',
        serverCertificateBytes: [10, 20, 30],
      );

      expect(config1, equals(config2));
      expect(config1.hashCode, equals(config2.hashCode));
    });
  });

  group('DesktopDownloader mTLS configuration', () {
    test('Configuring global mTLS updates active mtlsConfigs', () async {
      const config = MTLSConfig(
        certificatePath: '/path/cert.pem',
        privateKeyPath: '/path/key.pem',
      );

      final result = await FileDownloader().configure(
        desktopConfig: (Config.mTLS, config),
      );

      expect(result.first, equals((Config.mTLS, '')));
      expect(DesktopDownloader.mtlsConfigs.length, equals(1));
      expect(DesktopDownloader.mtlsConfigs.first, equals(config));
    });

    test('Configuring multiple host-specific mTLS entries', () async {
      const configA = MTLSConfig(
        host: 'hostA.com',
        certificatePath: '/path/certA.pem',
        privateKeyPath: '/path/keyA.pem',
      );
      const configB = MTLSConfig(
        host: 'hostB.com',
        certificatePath: '/path/certB.pem',
        privateKeyPath: '/path/keyB.pem',
      );

      await FileDownloader().configure(
        desktopConfig: [(Config.mTLS, configA), (Config.mTLS, configB)],
      );

      expect(DesktopDownloader.mtlsConfigs.length, equals(2));
      expect(
        DesktopDownloader.mtlsConfigs.map((c) => c.host),
        containsAll(['hostA.com', 'hostB.com']),
      );
    });

    test('Resetting mTLS for a specific host', () async {
      const configA = MTLSConfig(
        host: 'hostA.com',
        certificatePath: '/path/certA.pem',
        privateKeyPath: '/path/keyA.pem',
      );
      const configB = MTLSConfig(
        host: 'hostB.com',
        certificatePath: '/path/certB.pem',
        privateKeyPath: '/path/keyB.pem',
      );

      await FileDownloader().configure(
        desktopConfig: [(Config.mTLS, configA), (Config.mTLS, configB)],
      );

      // Reset hostA
      await FileDownloader().configure(
        desktopConfig: (Config.mTLS, const MTLSConfig(host: 'hostA.com')),
      );

      expect(DesktopDownloader.mtlsConfigs.length, equals(1));
      expect(DesktopDownloader.mtlsConfigs.first.host, equals('hostB.com'));
    });

    test('Resetting all mTLS configs with false or null', () async {
      const config = MTLSConfig(
        certificatePath: '/path/cert.pem',
        privateKeyPath: '/path/key.pem',
      );

      await FileDownloader().configure(desktopConfig: (Config.mTLS, config));
      expect(DesktopDownloader.mtlsConfigs.length, equals(1));

      await FileDownloader().configure(desktopConfig: (Config.mTLS, false));
      expect(DesktopDownloader.mtlsConfigs, isEmpty);
    });
  });

  group('SecurityContext application and httpClient selection', () {
    test(
      'applyToSecurityContext executes without throwing invalid methods',
      () {
        final context = SecurityContext(withTrustedRoots: true);
        const config = MTLSConfig(
          certificateBytes: [1, 2, 3],
          privateKeyBytes: [4, 5, 6],
        );

        expect(() => config.applyToSecurityContext(context), returnsNormally);
      },
    );

    test('httpClientForUrl returns cached or dedicated client per host', () {
      const configHostA = MTLSConfig(
        host: 'hostA.com',
        certificateBytes: [1, 2, 3],
        privateKeyBytes: [4, 5, 6],
      );
      const configHostB = MTLSConfig(
        host: 'hostB.com',
        certificateBytes: [7, 8, 9],
        privateKeyBytes: [10, 11, 12],
      );

      DesktopDownloader.mtlsConfig = configHostA;
      DesktopDownloader.mtlsConfig = configHostB;

      final clientA1 = DesktopDownloader.httpClientForUrl(
        'https://hostA.com/file',
      );
      final clientA2 = DesktopDownloader.httpClientForUrl(
        'https://hostA.com/other',
      );
      final clientB = DesktopDownloader.httpClientForUrl(
        'https://hostB.com/file',
      );
      final clientDefault = DesktopDownloader.httpClientForUrl(
        'https://unmatched.com/file',
      );

      expect(identical(clientA1, clientA2), isTrue);
      expect(identical(clientA1, clientB), isFalse);
      expect(identical(clientA1, clientDefault), isFalse);
    });
  });
}
