# Permissions

User permissions may be needed to display notifications, to move files to shared storage (on Android) and to add images or video to the iOS Photo Library. These permissions should be checked and if needed requested before executing those operations.

You can use a package like [permission_handler](https://pub.dev/packages/permission_handler), or use the `FileDownloader().permissions` object, which has three methods:
* `status`: returns a `PermissionsStatus`. On Android this is either `granted` or `denied`. If you have not asked for permission yet, then Android returns `denied` and iOS returns `.undetermined`. iOS can also return `.partial`
* `request`: to request the actual permission. Only do this if you have confirmed that the permission is not already `granted`
* `shouldShowRationale`: for Android only, if `true` you should show a UI element (e.g. a dialog) to explain to the user why this permission is necessary

All three methods take one `PermissionType` parameter:
* `notifications`, to display notifications
* `androidSharedStorage`, to move files to external storage on Android, before API 29
* `iosAddToPhotoLibrary`, to move files to `SharedStorage.images` or `SharedStorage.video` on iOS, as this adds those files to the Photo Library
* `iosChangePhotoLibrary`, to access the path to files moved to the Photos Library

For example, to request permissions for notifications:
```dart
final permissionType = PermissionType.notifications;
var status = await FileDownloader().permissions.status(permissionType);
if (status != PermissionStatus.granted) {
  if (await FileDownloader().permissions.shouldShowRationale(permissionType)) {
    await showRationaleDialog(permissionType); // Show a dialog with rationale
  }
  status = await FileDownloader().permissions.request(permissionType);
  debugPrint('Permission for $permissionType was $status');
}
```

The downloader will check permission status before each action, e.g. will not show notifications unless permissions for notifications have been granted.

Note that permissions are very platform and version dependent, e.g. notification permissions on Android are only required as of API 33, and iOS 14 introduced new Photo Library permissions. If you want to get into details, you can determine the platform version you're running by calling `await FileDownloader().platformVersion()`.

## Bypassing permissions on iOS

By default, the downloader allows any of the permissions to be requested, but that also means that Apple requires you to add things like Photo Library Usage Description to your Info.plist, even if you never move files to the Photo Library.

On iOS, to bypass the permission code altogether at compile time (and therefore remove the need to provide the Info.plist entry) modify your app's Podfile as follows:
```agsl
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    
    # The following loop has been added to bypass compilation of specific
    # permissions.
    # If you want to bypass one or more permissions (so that you don't
    # have to include things like a Photo Library Usage Description
    # if you don't add files to the Photo Library) then add this loop
    # and uncomment the permissions you want to bypass.
    # If you bypass (by including the line below) then the
    # check will not happen, and the permission is aways denied. If you
    # bypass you do not need to include the associated entry in your
    # Info.plist file
    target.build_configurations.each do |config|
      config.build_settings['OTHER_SWIFT_FLAGS'] ||= ['$(inherited)']
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_NOTIFICATIONS'
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY'
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY'
      end
  end
end
```
and uncomment the line items that you want to bypass by deleting the `#` mark at the start of the line.
