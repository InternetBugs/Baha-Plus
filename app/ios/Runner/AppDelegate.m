#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
@import AVFoundation;

static NSDictionary *BahaDiagnosticError(NSError *error, NSUInteger depth) {
  if (!error || depth > 4) return @{};
  NSMutableDictionary *result = [@{
    @"domain": error.domain,
    @"code": @(error.code),
    @"description": error.localizedDescription ?: @""
  } mutableCopy];
  NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
  if ([underlying isKindOfClass:[NSError class]]) {
    result[@"underlying"] = BahaDiagnosticError(underlying, depth + 1);
  }
  return result;
}

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

- (void)didInitializeImplicitFlutterEngine:(NSObject<FlutterImplicitEngineBridge> *)engineBridge {
  [GeneratedPluginRegistrant registerWithRegistry:engineBridge.pluginRegistry];
  NSObject<FlutterPluginRegistrar> *registrar =
      [engineBridge.pluginRegistry registrarForPlugin:@"BahaDiagnostics"];
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"baha.diagnostics"
                                 binaryMessenger:[registrar messenger]];
  [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if (![call.method isEqualToString:@"inspectHls"]) {
      result(FlutterMethodNotImplemented);
      return;
    }
    id arguments = call.arguments;
    NSString *raw = [arguments isKindOfClass:[NSDictionary class]] ? arguments[@"url"] : nil;
    NSURL *url = [raw isKindOfClass:[NSString class]] ? [NSURL URLWithString:raw] : nil;
    if (!url || ![url.scheme isEqualToString:@"https"] ||
        ![url.host isEqualToString:@"bahamut.akamaized.net"] ||
        url.user != nil || (url.port != nil && url.port.intValue != 443)) {
      result([FlutterError errorWithCode:@"invalid_source" message:@"Invalid diagnostic source" details:nil]);
      return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
      NSError *error = nil;
      AVKeyValueStatus status = [asset statusOfValueForKey:@"playable" error:&error];
      NSDictionary *value = @{
        @"status": @(status),
        @"playable": @(status == AVKeyValueStatusLoaded && asset.playable),
        @"error": BahaDiagnosticError(error, 0)
      };
      dispatch_async(dispatch_get_main_queue(), ^{ result(value); });
    }];
  }];
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
