#import "BackgroundDownloaderPlugin.h"
#if __has_include(<background_downloader/background_downloader-Swift.h>)
#import <background_downloader/background_downloader-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "background_downloader-Swift.h"
#endif

@implementation BackgroundDownloaderPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [Downloader registerWithRegistrar:registrar];
}
@end
