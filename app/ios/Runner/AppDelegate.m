#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>
#import "Runner-Swift.h"

@interface AppDelegate ()
@property(nonatomic, strong) FlutterMethodChannel *mediaSessionChannel;
@property(nonatomic, strong) FlutterMethodChannel *playbackCacheChannel;
@property(nonatomic, strong) FlutterMethodChannel *playbackEnvironmentChannel;
@property(nonatomic, strong) id remotePlayTarget;
@property(nonatomic, strong) id remotePauseTarget;
@property(nonatomic, strong) id remoteToggleTarget;
@property(nonatomic, strong) id remoteSeekTarget;
@property(nonatomic, copy) NSString *playbackDocument;
@property(nonatomic, assign) BOOL nativePlayback;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(audioSessionInterrupted:)
      name:AVAudioSessionInterruptionNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(audioRouteChanged:)
      name:AVAudioSessionRouteChangeNotification object:nil];
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
    owner.nativePlayback = [arguments[@"native"] boolValue];
    [owner installPlaybackControls];
    MPRemoteCommandCenter.sharedCommandCenter.changePlaybackPositionCommand.enabled =
        owner.nativePlayback && [arguments[@"duration"] doubleValue] > 0;
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
    // Dart releases the native player and unloads web media before exit.
    // Deactivate only on exit, never on a normal pause or quality change.
    [weakSelf clearPlaybackControls];
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
  self.remoteSeekTarget = [commands.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    if (!weakSelf.nativePlayback ||
        ![event isKindOfClass:MPChangePlaybackPositionCommandEvent.class]) {
      return MPRemoteCommandHandlerStatusCommandFailed;
    }
    double position = ((MPChangePlaybackPositionCommandEvent *)event).positionTime;
    if (!isfinite(position) || position < 0) return MPRemoteCommandHandlerStatusCommandFailed;
    return [weakSelf forwardPlaybackCommand:@"seek" value:@(position)];
  }];
}

- (MPRemoteCommandHandlerStatus)forwardPlaybackCommand:(NSString *)action {
  return [self forwardPlaybackCommand:action value:nil];
}

- (MPRemoteCommandHandlerStatus)forwardPlaybackCommand:(NSString *)action value:(NSNumber *)value {
  NSString *document = self.playbackDocument;
  if (!document.length) return MPRemoteCommandHandlerStatusNoSuchContent;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self.playbackDocument isEqualToString:document]) return;
    NSMutableDictionary *arguments =
        [@{@"document": document, @"action": action} mutableCopy];
    if (value) arguments[@"value"] = value;
    [self.playbackEnvironmentChannel invokeMethod:@"remoteCommand"
        arguments:arguments];
  });
  return MPRemoteCommandHandlerStatusSuccess;
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
  if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] ==
      AVAudioSessionInterruptionTypeBegan) {
    [self pauseNativePlayback];
  }
}

- (void)audioRouteChanged:(NSNotification *)notification {
  if ([notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] ==
      AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
    [self pauseNativePlayback];
  }
}

- (void)pauseNativePlayback {
  // Calls, Siri and disconnected headphones latch pause through the same
  // document-scoped control path. Interruption end never resumes playback.
  if (self.nativePlayback) [self forwardPlaybackCommand:@"pause"];
}

- (void)clearPlaybackControls {
  MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
  if (self.remotePlayTarget) [commands.playCommand removeTarget:self.remotePlayTarget];
  if (self.remotePauseTarget) [commands.pauseCommand removeTarget:self.remotePauseTarget];
  if (self.remoteToggleTarget) [commands.togglePlayPauseCommand removeTarget:self.remoteToggleTarget];
  if (self.remoteSeekTarget) [commands.changePlaybackPositionCommand removeTarget:self.remoteSeekTarget];
  self.remotePlayTarget = nil;
  self.remotePauseTarget = nil;
  self.remoteToggleTarget = nil;
  self.remoteSeekTarget = nil;
  commands.changePlaybackPositionCommand.enabled = NO;
  if (self.playbackDocument) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
  self.playbackDocument = nil;
  self.nativePlayback = NO;
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
