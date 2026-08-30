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

By default, the downloader allows any of the permissions to be requested, but that also means that Apple requires you to add things like Photo Library Usage Description to your `Info.plist`, even if you never move files to the Photo Library.

On iOS, you can bypass the permission code altogether at compile time (and therefore remove the need to provide the `Info.plist` entry) using Swift Package Manager (default) or CocoaPods (legacy).

### Using Swift Package Manager (SPM) — Default

Starting with Flutter 3.44+, Swift Package Manager is the default dependency manager for iOS. Because Swift packages are built in isolated target modules, they do not inherit compiler flags (`OTHER_SWIFT_FLAGS`) from the consuming app's Xcode target.

Instead, `background_downloader`'s `Package.swift` reads build-time environment variables during package manifest resolution:

* `BYPASS_PERMISSION_NOTIFICATIONS=1`
* `BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY=1`
* `BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY=1`

Depending on your build environment, configure these variables as follows:

#### 1. Flutter CLI / Terminal Builds
Set the environment variables in your shell before invoking `flutter`:

```bash
# Bypass Photo Library permissions
export BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY=1
export BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY=1

# Run or build the app
flutter run
# or
flutter build ios
```

#### 2. Building from Xcode IDE
If you build or archive directly from Xcode:
1. In Xcode, open your workspace (`Runner.xcworkspace`).
2. Go to **Product > Scheme > Edit Scheme...** (or press `Cmd + <`).
3. Select **Run** (for debugging) or **Archive** (for release distribution) in the left sidebar.
4. Under the **Arguments** tab, find **Environment Variables**.
5. Click **+** and add the desired variable name(s) (e.g. `BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY`) with value `1`.

> **Note on Package Resolution Caching**: Xcode and SwiftPM cache package manifest evaluations. If you add, change, or remove any `BYPASS_PERMISSION_*` environment variables, force a clean evaluation by running `flutter clean` in the terminal or selecting **File > Packages > Reset Package Caches** in Xcode.

#### 3. CI/CD Pipelines (GitHub Actions, Bitrise, Xcode Cloud, Fastlane)
Define the environment variables in your workflow configuration. For example, in GitHub Actions:

```yaml
- name: Build iOS App
  env:
    BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY: 1
    BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY: 1
  run: flutter build ios --release --no-codesign
```

---

### Using CocoaPods (Legacy)

For projects that have not yet migrated to Swift Package Manager and still use CocoaPods, you can bypass the permission code by modifying your app's `ios/Podfile`:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    
    # The following loop bypasses compilation of specific permissions.
    # Uncomment the permissions you want to bypass.
    # When bypassed, the check is omitted and permission is always denied,
    # removing the need to include the associated Info.plist entry.
    target.build_configurations.each do |config|
      config.build_settings['OTHER_SWIFT_FLAGS'] ||= ['$(inherited)']
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_NOTIFICATIONS'
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY'
      #config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY'
    end
  end
end
```

Uncomment the relevant line(s) by removing the leading `#`.
