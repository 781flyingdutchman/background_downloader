// ignore_for_file: avoid_print, empty_catches

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// MUST START WITH AN UNINSTALLED APPLICATION

void main() {
  testWidgets('permission status', (widgetTester) async {
    for (var permissionType in PermissionType.values) {
      final status = await FileDownloader().permissions.status(permissionType);
      print('Permission $permissionType was $status');
      switch (permissionType) {
        case PermissionType.notifications:
          if (Platform.isIOS) {
            expect(status, equals(PermissionStatus.undetermined));
          } else if (Platform.isAndroid) {
            final androidVersion = await getAndroidVersion();
            expect(
                status,
                equals(androidVersion < 33
                    ? PermissionStatus.granted
                    : PermissionStatus.denied));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.androidSharedStorage:
          if (Platform.isAndroid) {
            final androidVersion = await getAndroidVersion();
            expect(
                status,
                equals(androidVersion < 29
                    ? PermissionStatus.denied
                    : PermissionStatus.granted));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.iosAddToPhotoLibrary:
          if (Platform.isIOS) {
            expect(status, equals(PermissionStatus.undetermined));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.iosChangePhotoLibrary:
          if (Platform.isIOS) {
            expect(status, equals(PermissionStatus.undetermined));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
      }
    }
  });

  testWidgets('request permission', (widgetTester) async {
    // Requires manual approval of permission request, therefore
    // are are expected to be granted.
    // Make test fail by denying certain permissions
    for (var permissionType in PermissionType.values) {
      final status = await FileDownloader().permissions.request(permissionType);
      print('Permission $permissionType was $status');
      switch (permissionType) {
        case PermissionType.notifications:
          if (Platform.isAndroid) {
            final androidVersion = await getAndroidVersion();
            expect(
                status,
                equals(androidVersion < 33
                    ? PermissionStatus.requestError
                    : PermissionStatus.granted));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.androidSharedStorage:
          if (Platform.isAndroid) {
            final androidVersion = await getAndroidVersion();
            expect(
                status,
                equals(androidVersion > 29
                    ? PermissionStatus.requestError
                    : PermissionStatus.granted));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.iosAddToPhotoLibrary:
          expect(status, equals(PermissionStatus.granted));
        case PermissionType.iosChangePhotoLibrary:
          expect(status, equals(PermissionStatus.granted));
      }
    }
  });
}

Future<int> getAndroidVersion() async =>
    int.parse(await FileDownloader().platformVersion());
