#import "FileDownloaderPlugin.h"
#if __has_include(<file_downloader/file_downloader-Swift.h>)
#import <file_downloader/file_downloader-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "file_downloader-Swift.h"
#endif

@implementation FileDownloaderPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [Downloader registerWithRegistrar:registrar];
}
@end
