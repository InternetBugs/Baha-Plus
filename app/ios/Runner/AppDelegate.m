#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>

@interface AppDelegate ()
@property(nonatomic, strong) FlutterMethodChannel *mediaSessionChannel;
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
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
