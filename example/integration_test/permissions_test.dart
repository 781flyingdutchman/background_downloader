import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// MUST START WITH AN UNINSTALLED APPLICATION

void main() {
  testWidgets('permission status', (widgetTester) async {
    for (var type in PermissionType.values) {
      final status = await FileDownloader().permissions.status(type);
      switch (type) {
        case PermissionType.notifications:
          if (Platform.isIOS || Platform.isAndroid) {
            expect(status, equals(PermissionStatus.undetermined));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.androidExternalStorage:
          expect(true, isTrue); //TODO
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
    for (var permissionType in PermissionType.values) {
      final status = await FileDownloader().permissions.request(permissionType);
      switch (permissionType) {
        case PermissionType.notifications:
          if (Platform.isIOS || Platform.isAndroid) {
            expect(status, equals(PermissionStatus.granted));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.androidExternalStorage:
          expect(true, isTrue); //TODO
        case PermissionType.iosAddToPhotoLibrary:
          if (Platform.isIOS) {
            expect(status, equals(PermissionStatus.granted));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
        case PermissionType.iosChangePhotoLibrary:
          if (Platform.isIOS) {
            expect(status, equals(PermissionStatus.granted));
          } else {
            expect(status, equals(PermissionStatus.granted));
          }
      }
    }
  });
}
