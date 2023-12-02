import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'native_downloader.dart';

enum PermissionType {
  notifications,
  androidExternalStorage,
  iosAddToPhotoLibrary,
  iosChangePhotoLibrary
}

enum PermissionStatus { undetermined, denied, granted, partial, requestError }

/// Developer visible interface to the PermissionService
abstract interface class Permissions {
  /// Request a permission; returns the [PermissionStatus]
  ///
  /// Ensure that only one request is being handled at the same time,
  /// i.e. wait for the result before requesting another permission
  Future<PermissionStatus> request(PermissionType permissionType);

  /// Get the auth status of a permission; returns the [PermissionStatus]
  Future<PermissionStatus> status(PermissionType permissionType);

  /// Returns true if the developer should show a rationale for
  /// requesting this permission
  Future<bool> shouldShowRationale(PermissionType permissionType);
}

/// Basic implementation of the Permission
base class PermissionsService implements Permissions {
  final log = Logger("PermissionService");

  PermissionsService();

  /// Creates a [PermissionsService] appropriate for this platform
  factory PermissionsService.instance() {
    return Platform.isAndroid
        ? AndroidPermissionsService()
        : Platform.isIOS
            ? IOSPermissionsService()
            : Platform.isLinux || Platform.isMacOS || Platform.isWindows
                ? PermissionsService()
                : throw ArgumentError(
                    '${Platform.operatingSystem} is not a supported platform');
  }

  @override
  Future<PermissionStatus> request(PermissionType permissionType) =>
      Future.value(PermissionStatus.granted);

  @override
  Future<bool> shouldShowRationale(PermissionType permissionType) =>
      Future.value(false);

  @override
  Future<PermissionStatus> status(PermissionType permissionType) =>
      Future.value(PermissionStatus.granted);

  /// Process the response to a request
  ///
  /// Responses are sent to the downloader, and from there are sent here for processing
  void processResponse(int response) {}
}

final class IOSPermissionsService extends PermissionsService {

  IOSPermissionsService();

  @override
  Future<PermissionStatus> request(PermissionType permissionType) async {
    final result = await NativeDownloader.methodChannel
        .invokeMethod<int>('requestPermission', permissionType.index);
    return result != null
        ? PermissionStatus.values[result]
        : PermissionStatus.requestError;
  }

  @override
  Future<PermissionStatus> status(PermissionType permissionType) async {
    final result = await NativeDownloader.methodChannel
        .invokeMethod<int>('permissionStatus', permissionType.index);
    return result != null
        ? PermissionStatus.values[result]
        : PermissionStatus.requestError;
  }

}

final class AndroidPermissionsService extends IOSPermissionsService {
  var permissionStatusCompleter = Completer<PermissionStatus>();

  @override
  Future<PermissionStatus> request(PermissionType permissionType) async {
    permissionStatusCompleter = Completer();
    final callResult = await NativeDownloader.methodChannel
        .invokeMethod<bool>('requestPermission', permissionType.index);
    if (callResult == null || callResult == false) {
      return PermissionStatus.requestError;
    }
    return permissionStatusCompleter
        .future; // to be completed via [processResponse]
  }

  @override
  Future<bool> shouldShowRationale(PermissionType permissionType) async {
    final result = await NativeDownloader.methodChannel
        .invokeMethod<bool>('shouldShowPermissionRationale', permissionType.index);
    return result ?? false;
  }

  @override
  void processResponse(int response) {
    if (!permissionStatusCompleter.isCompleted) {
      permissionStatusCompleter.complete(PermissionStatus.values[response]);
    }
    log.severe('Simultaneous permissions requests will lead to errors');
  }

}
