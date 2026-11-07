#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import "Runner-Swift.h"

@interface AppDelegate ()
@property(nonatomic, strong) FlutterMethodChannel *mediaSessionChannel;
@property(nonatomic, strong) FlutterMethodChannel *playbackCacheChannel;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

- (void)didInitializeImplicitFlutterEngine:(NSObject<FlutterImplicitEngineBridge> *)engineBridge {
  [GeneratedPluginRegistrant registerWithRegistry:engineBridge.pluginRegistry];
  NSObject<FlutterPluginRegistrar> *registrar =
      [engineBridge.pluginRegistry registrarForPlugin:@"BahaMediaSession"];
  self.playbackCacheChannel =
      [FlutterMethodChannel methodChannelWithName:@"app.bahaplus.mobile/hls_cache"
                                 binaryMessenger:registrar.messenger];
  [self.playbackCacheChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
    if ([call.method isEqualToString:@"prepare"]) {
      [[PlaybackCache shared] prepare:arguments completion:^(NSDictionary *value) { result(value); }];
    } else if ([call.method isEqualToString:@"update"]) {
      [[PlaybackCache shared] update:arguments];
      result(nil);
    } else if ([call.method isEqualToString:@"stop"]) {
      NSString *document = [arguments[@"document"] isKindOfClass:[NSString class]] ? arguments[@"document"] : @"";
      [[PlaybackCache shared] stop:document];
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }];
  self.mediaSessionChannel =
      [FlutterMethodChannel methodChannelWithName:@"app.bahaplus.mobile/media_session"
                                 binaryMessenger:registrar.messenger];
  [self.mediaSessionChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if (![call.method isEqualToString:@"releasePlayback"]) {
      result(FlutterMethodNotImplemented);
      return;
    }
    // Dart unloads the web media first so WebKit cannot immediately publish
    // the old session again. Deactivate only on exit, never on a normal pause.
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    NSError *error = nil;
    BOOL released = [[AVAudioSession sharedInstance]
        setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
        error:&error];
    if (!released) {
      result([FlutterError errorWithCode:@"audio_session_release_failed"
                                message:error.localizedDescription
                                details:nil]);
      return;
    }
    result(nil);
  }];
}

- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
    completionHandler:(void (^)(void))completionHandler {
  if ([identifier isEqualToString:PlaybackCache.identifier]) {
    [[PlaybackCache shared] reconnect:completionHandler];
  } else {
    [super application:application handleEventsForBackgroundURLSession:identifier
        completionHandler:completionHandler];
  }
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
