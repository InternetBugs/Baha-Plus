#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import "Runner-Swift.h"

@interface AppDelegate ()
@property(nonatomic, strong) FlutterMethodChannel *mediaSessionChannel;
@property(nonatomic, strong) FlutterMethodChannel *playbackCacheChannel;
@property(nonatomic, strong) FlutterMethodChannel *playbackEnvironmentChannel;
@property(nonatomic, strong) id remotePlayTarget;
@property(nonatomic, strong) id remotePauseTarget;
@property(nonatomic, strong) id remoteToggleTarget;
@property(nonatomic, copy) NSString *playbackDocument;
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
  self.playbackEnvironmentChannel =
      [FlutterMethodChannel methodChannelWithName:@"app.bahaplus.mobile/playback_environment"
                                 binaryMessenger:registrar.messenger];
  __weak AppDelegate *weakSelf = self;
  [self.playbackEnvironmentChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    AppDelegate *owner = weakSelf;
    if (![call.method isEqualToString:@"update"]) {
      result(FlutterMethodNotImplemented);
      return;
    }
    NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
    BOOL active = [arguments[@"active"] boolValue];
    UIApplication.sharedApplication.idleTimerDisabled = active && [arguments[@"keepAwake"] boolValue];
    if (!active) {
      [owner clearPlaybackControls];
      result(nil);
      return;
    }
    owner.playbackDocument = arguments[@"document"];
    [owner installPlaybackControls];
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = @{
      MPMediaItemPropertyTitle: arguments[@"title"] ?: @"Baha Plus",
      MPMediaItemPropertyAlbumTitle: arguments[@"episode"] ?: @"",
      MPMediaItemPropertyPlaybackDuration: arguments[@"duration"] ?: @0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: arguments[@"position"] ?: @0,
      MPNowPlayingInfoPropertyPlaybackRate: [arguments[@"playing"] boolValue] ? arguments[@"rate"] ?: @1 : @0
    };
    result(nil);
  }];
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

- (void)installPlaybackControls {
  if (self.remotePlayTarget) return;
  __weak AppDelegate *weakSelf = self;
  MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
  commands.playCommand.enabled = YES;
  commands.pauseCommand.enabled = YES;
  commands.togglePlayPauseCommand.enabled = YES;
  self.remotePlayTarget = [commands.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    return [weakSelf forwardPlaybackCommand:@"play"];
  }];
  self.remotePauseTarget = [commands.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    return [weakSelf forwardPlaybackCommand:@"pause"];
  }];
  self.remoteToggleTarget = [commands.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    return [weakSelf forwardPlaybackCommand:@"toggle"];
  }];
}

- (MPRemoteCommandHandlerStatus)forwardPlaybackCommand:(NSString *)action {
  NSString *document = self.playbackDocument;
  if (!document.length) return MPRemoteCommandHandlerStatusNoSuchContent;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self.playbackDocument isEqualToString:document]) return;
    [self.playbackEnvironmentChannel invokeMethod:@"remoteCommand"
        arguments:@{@"document": document, @"action": action}];
  });
  return MPRemoteCommandHandlerStatusSuccess;
}

- (void)clearPlaybackControls {
  MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
  if (self.remotePlayTarget) [commands.playCommand removeTarget:self.remotePlayTarget];
  if (self.remotePauseTarget) [commands.pauseCommand removeTarget:self.remotePauseTarget];
  if (self.remoteToggleTarget) [commands.togglePlayPauseCommand removeTarget:self.remoteToggleTarget];
  self.remotePlayTarget = nil;
  self.remotePauseTarget = nil;
  self.remoteToggleTarget = nil;
  if (self.playbackDocument) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
  self.playbackDocument = nil;
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
