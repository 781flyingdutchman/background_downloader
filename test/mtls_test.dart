import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _testCertPem = '''-----BEGIN CERTIFICATE-----
MIIC/zCCAeegAwIBAgIUDIdgj9t+yWcM0e7PNwvQgNH2ZlUwDQYJKoZIhvcNAQEL
BQAwDzENMAsGA1UEAwwEdGVzdDAeFw0yNjA4MzAxMjU1NTBaFw0yNzA4MzAxMjU1
NTBaMA8xDTALBgNVBAMMBHRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
AoIBAQC0vxJQCL6EIg2doEk8d37KnWBKiA6mPYulfgYlrinZ06rMywrED0vCBUYA
PGFkFS57/2YUX+KKXu02iQ8mslSkqIBH6eN0Mh3sFpLxxIf85tUbtD2lx6jUepi8
VF+6ScXntRry62TURtaoBHAFMFqQ4m41fjLHyy2/Tp/D5uM1ayd4lriyYacrsVMP
d2oErYhyQTSLZn3gYYM6+QKOwTqVeeFcxuuj9x1NBMwpsVrrBGtNCosaA+W/RMgU
HYXh2ryIddORzSwa46DBL8YIK7pP9Q+1YXYi0f5Hllu7m2THPgTnHWKLGvncKWc/
nzjhssWFRw4hc/9Rgd9BhPu8dqPVAgMBAAGjUzBRMB0GA1UdDgQWBBT4LZDJGIHX
cYxczolDjxlOmSt4pzAfBgNVHSMEGDAWgBT4LZDJGIHXcYxczolDjxlOmSt4pzAP
BgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCdjmpBmwh+hVnm61aG
8ssTiCuhBu8cDlOjSftP7X4zLGWdTYQIOW1sWof1tLR398nKq9KGVGiI6maF2JwH
N+hKB7SpOtZ5Jexc4e1BW8ShBnltrJi0tiPcY8WyTqodUulKZQd/pYiaxRPZmRoO
qMxG1OXU93GFWAnqrfJj5iq1wURYikhj4bAeIkWaaENedAp8UO2H18ZxhZsLAfbi
ADLNjWd9Ug9ohP1DBWtljwwiNkhMnqjVtT6OGeacWMGgAa9evGHFei2pppyg9Wdj
SFJA0W9rymfQCTZmKf4nnRios4BdsCFOrYZ3bjOHkVhrRNuTh56ATQ35zyFTslcj
7xB5
-----END CERTIFICATE-----''';

const _testKeyPem = '''-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC0vxJQCL6EIg2d
oEk8d37KnWBKiA6mPYulfgYlrinZ06rMywrED0vCBUYAPGFkFS57/2YUX+KKXu02
iQ8mslSkqIBH6eN0Mh3sFpLxxIf85tUbtD2lx6jUepi8VF+6ScXntRry62TURtao
BHAFMFqQ4m41fjLHyy2/Tp/D5uM1ayd4lriyYacrsVMPd2oErYhyQTSLZn3gYYM6
+QKOwTqVeeFcxuuj9x1NBMwpsVrrBGtNCosaA+W/RMgUHYXh2ryIddORzSwa46DB
L8YIK7pP9Q+1YXYi0f5Hllu7m2THPgTnHWKLGvncKWc/nzjhssWFRw4hc/9Rgd9B
hPu8dqPVAgMBAAECggEAAqY8KhXljORN5EnQ7i1OwUDBvMsdulNoanqahn4xRVoL
UfN7yBsw/0dtTbSNV1D3Zvq/h29O5mGY24IfiZlF9sn4RWaGGOqk+BQ5ZNtVBIvx
tDzyH/ke/j8mrQOsIDCiur9RveiZuS9AGvnu+D4mAxv8cl0jDzWSdnX8LTSo+Od4
GjuBXc/H/4aj3Masg6nJ2btCOtyb4v5GMrxvWQpwZaKj32z5YAvkqevIBD+MkB8g
kEk78JrCibVq7+CICMsFvS0Wb1sLiDO+oCGiwjQANdZT3a5r6YNWjhAcZqmAUGA3
1ZPZmBvlfjt5lE68yJaOn6AXEY+mIdVne13zJKyNcQKBgQD2wv6NeiaYFHkjonjt
W+Jgwnv2vFARoURpe/kvVEYvTr8zro7/k4363+ihIKmPkGShRxmhtvHnPOgbxv5g
3DWaSH/9bMNSsb1GqcvcsgLL2c0B1AzXkRT/wr23HsHazstLU2xI8+EbtgLARzrG
cQpELlDYjADeY10tyb5VWWk4UQKBgQC7g2ANzjPL+363tBUqyL8mw6VZ5kSq1Dw7
oX44sIzGQj9slJQAN8ejw1qpRg4acNJTejRmLN5P0icTzTDZxvohyxRhAG2/KoFq
lIpFu/4EpKAj+xyFiVwBMs4aSzI/Z8QqDCrPLhsKj1haIT/m1l327WPXnPqZgKYd
smIO/quWRQKBgQCEHEuKVR56h2N/x4l0kp/1a8pQg+teNPfafawgQb89rqxBMDCQ
9l+qM9xo/4KoQQcPLXC0mqySP5KI5JXmJ59vFWeot2UvTcdnIJrrckZ6+wV9+BhU
BPG4KHvHoWjqC5LdpjEwMZmQa3a3mKsH+Rck/6L6/KGuboZBcGQ9b5wcsQKBgBO1
MxtAWOFPhXn5S2A7yRth5LcWJJFvzQTXbFS4+ZK8072twABl3G2x0o2H92OACBsN
9QPoI1VwWPsTzdaVuyRiG7o2OVKmPQPeqMm7gG8sfkhJ1C2Uyj62AENzM8zGMy/Y
J4eu6NirSDXw2K6CSU3ylVPMA+quQsdMQFIjIhWhAoGBANibgeVJbHIb5PwmmMwo
z+xkH36AiAAS3Qj5TKObilZOGKwEfhw6cjsFb6KxpBgRnpuiOIhcWrA7EoujXCXF
KCeC3RR1ms0Bfv/syzn0GYlTGEl0pAqOi475IR4rS8DG04O0iE2EoJDqz0Mf+lFS
JQTddI2ttdBhoL2YER5dVS66
-----END PRIVATE KEY-----''';

final _testCertBytes = utf8.encode(_testCertPem);
final _testKeyBytes = utf8.encode(_testKeyPem);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    DesktopDownloader.resetMtlsConfig();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
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
        final config = MTLSConfig(
          certificateBytes: _testCertBytes,
          privateKeyBytes: _testKeyBytes,
        );

        expect(() => config.applyToSecurityContext(context), returnsNormally);
      },
    );

    test('httpClientForUrl returns cached or dedicated client per host', () {
      final configHostA = MTLSConfig(
        host: 'hostA.com',
        certificateBytes: _testCertBytes,
        privateKeyBytes: _testKeyBytes,
      );
      final configHostB = MTLSConfig(
        host: 'hostB.com',
        certificateBytes: _testCertBytes,
        privateKeyBytes: _testKeyBytes,
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
