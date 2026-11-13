#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

@interface AppDelegate () <NSURLSessionDelegate>
@property(nonatomic, strong) FlutterMethodChannel *mediaSessionChannel;
@property(nonatomic, strong) NSURLSession *retiredPlaybackDownloads;
@property(nonatomic, copy) void (^retiredPlaybackCompletion)(void);
@property(nonatomic, strong) FlutterMethodChannel *playbackEnvironmentChannel;
@property(nonatomic, strong) FlutterMethodChannel *playbackDownloadChannel;
@property(nonatomic, copy) NSString *downloadDocument;
@property(nonatomic, copy) NSSet<NSString *> *downloadSources;
@property(nonatomic, weak) AVPlayerItem *downloadItem;
@property(nonatomic, assign) NSUInteger downloadSourceGeneration;
@property(nonatomic, strong) id remotePlayTarget;
@property(nonatomic, strong) id remotePauseTarget;
@property(nonatomic, strong) id remoteToggleTarget;
@property(nonatomic, strong) id remoteSeekTarget;
@property(nonatomic, copy) NSString *playbackDocument;
@property(nonatomic, assign) BOOL nativePlayback;
@property(nonatomic, assign) BOOL playbackDiagnosticsEnabled;
@property(nonatomic, assign) NSUInteger playbackCommandSequence;
@property(nonatomic, assign) NSUInteger playbackControlGeneration;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [self retirePlaybackDownloads];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(audioSessionInterrupted:)
      name:AVAudioSessionInterruptionNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(audioRouteChanged:)
      name:AVAudioSessionRouteChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(playbackAccessLogChanged:)
      name:AVPlayerItemNewAccessLogEntryNotification object:nil];
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
  self.playbackDownloadChannel =
      [FlutterMethodChannel methodChannelWithName:@"app.bahaplus.mobile/playback_download"
                                 binaryMessenger:registrar.messenger];
  [self.playbackDownloadChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    [weakSelf handlePlaybackDownloadCall:call result:result];
  }];
  [self.playbackEnvironmentChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    AppDelegate *owner = weakSelf;
    if (![call.method isEqualToString:@"update"]) {
      result(FlutterMethodNotImplemented);
      return;
    }
    NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
    if ([arguments[@"diagnostics"] isKindOfClass:NSNumber.class]) {
      owner.playbackDiagnosticsEnabled = [arguments[@"diagnostics"] boolValue];
    }
    BOOL active = [arguments[@"active"] boolValue];
    UIApplication.sharedApplication.idleTimerDisabled = active && [arguments[@"keepAwake"] boolValue];
    if (!active) {
      [owner clearPlaybackControls];
      result(nil);
      return;
    }
    NSString *document = [arguments[@"document"] isKindOfClass:NSString.class] ? arguments[@"document"] : nil;
    if (![owner.playbackDocument isEqualToString:document]) owner.playbackControlGeneration++;
    owner.playbackDocument = document;
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
  self.mediaSessionChannel =
      [FlutterMethodChannel methodChannelWithName:@"app.bahaplus.mobile/media_session"
                                 binaryMessenger:registrar.messenger];
  [self.mediaSessionChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if (![call.method isEqualToString:@"releasePlayback"]) {
      result(FlutterMethodNotImplemented);
      return;
    }
    // Dart releases the native player before exit.
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

- (void)playbackAccessLogChanged:(NSNotification *)notification {
  AVPlayerItem *item = [notification.object isKindOfClass:AVPlayerItem.class] ? notification.object : nil;
  if (!item || ![item.asset isKindOfClass:AVURLAsset.class]) return;
  // AVPlayer may deliver this notification from a media thread. Keep all
  // counter state on the platform channel's main queue.
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *source = ((AVURLAsset *)item.asset).URL.absoluteString;
    if (!self.downloadDocument.length || ![self.downloadSources containsObject:source]) return;
    if (self.downloadItem != item) {
      self.downloadItem = item;
      self.downloadSourceGeneration++;
    }
  });
}

- (void)handlePlaybackDownloadCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *arguments = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSString *document = [arguments[@"document"] isKindOfClass:NSString.class] ? arguments[@"document"] : nil;
  if ([call.method isEqualToString:@"start"]) {
    NSArray *sources = [arguments[@"sources"] isKindOfClass:NSArray.class] ? arguments[@"sources"] : nil;
    if (!document.length || !sources.count || sources.count > 21) {
      result(@NO);
      return;
    }
    for (id source in sources) {
      if (![source isKindOfClass:NSString.class]) {
        result(@NO);
        return;
      }
      NSURL *url = [NSURL URLWithString:source];
      if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:@"bahamut.akamaized.net"]) {
        result(@NO);
        return;
      }
    }
    self.downloadDocument = document;
    self.downloadSources = [NSSet setWithArray:sources];
    self.downloadItem = nil;
    self.downloadSourceGeneration = 0;
    result(@YES);
  } else if ([call.method isEqualToString:@"sample"]) {
    if (![self.downloadDocument isEqualToString:document]) {
      result(nil);
      return;
    }
    long long bytes = 0;
    for (AVPlayerItemAccessLogEvent *event in self.downloadItem.accessLog.events) {
      bytes += MAX(0LL, event.numberOfBytesTransferred);
    }
    result(@{@"bytes": @(bytes), @"source": @(self.downloadSourceGeneration)});
  } else if ([call.method isEqualToString:@"stop"]) {
    if ([self.downloadDocument isEqualToString:document]) {
      self.downloadDocument = nil;
      self.downloadSources = nil;
      self.downloadItem = nil;
    }
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)installPlaybackControls {
  if (self.remotePlayTarget && !self.nativePlayback) return;
  MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
  // Reassert controls when taking ownership from the web Media Session, even
  // when native targets were installed before handoff. Do not duplicate them.
  commands.playCommand.enabled = YES;
  commands.pauseCommand.enabled = YES;
  commands.togglePlayPauseCommand.enabled = YES;
  if (self.remotePlayTarget) return;
  __weak AppDelegate *weakSelf = self;
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
  return [self forwardPlaybackCommand:action value:nil source:@"remote-command"];
}

- (MPRemoteCommandHandlerStatus)forwardPlaybackCommand:(NSString *)action value:(NSNumber *)value {
  return [self forwardPlaybackCommand:action value:value source:@"remote-command"];
}

- (void)recordPlaybackAudioEvent:(NSString *)stage fields:(NSDictionary *)fields {
  if (!self.playbackDiagnosticsEnabled) return;
  NSMutableDictionary *event = [fields mutableCopy];
  event[@"stage"] = stage;
  NSData *data = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:nil];
  if (data) {
    NSLog(@"[BAHA_AUDIO] %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
  }
}

- (MPRemoteCommandHandlerStatus)forwardPlaybackCommand:(NSString *)action
    value:(NSNumber *)value source:(NSString *)source {
  NSString *document = self.playbackDocument;
  NSUInteger generation = self.playbackControlGeneration;
  NSNumber *requestId;
  @synchronized (self) {
    requestId = @(++self.playbackCommandSequence);
  }
  NSDictionary *context = @{
    @"requestId": requestId, @"action": action, @"source": source,
    @"native": @(self.nativePlayback)
  };
  if (!document.length || !self.playbackEnvironmentChannel) {
    NSMutableDictionary *event = [context mutableCopy];
    event[@"reason"] = !document.length ? @"no-content" : @"no-channel";
    [self recordPlaybackAudioEvent:@"command-rejected" fields:event];
    return !document.length ? MPRemoteCommandHandlerStatusNoSuchContent : MPRemoteCommandHandlerStatusCommandFailed;
  }
  [self recordPlaybackAudioEvent:@"command-queued" fields:context];
  __weak AppDelegate *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    AppDelegate *owner = weakSelf;
    if (!owner) return;
    if (![owner.playbackDocument isEqualToString:document] ||
        owner.playbackControlGeneration != generation ||
        !owner.playbackEnvironmentChannel) {
      NSMutableDictionary *event = [context mutableCopy];
      event[@"reason"] = @"session-changed";
      [owner recordPlaybackAudioEvent:@"command-discarded" fields:event];
      return;
    }
    NSMutableDictionary *arguments =
        [@{@"document": document, @"action": action, @"requestId": requestId, @"source": source} mutableCopy];
    if (value) arguments[@"value"] = value;
    __block BOOL replied = NO;
    __block BOOL timedOut = NO;
    [owner recordPlaybackAudioEvent:@"command-forwarded" fields:context];
    [owner.playbackEnvironmentChannel invokeMethod:@"remoteCommand"
        arguments:arguments result:^(id result) {
      dispatch_async(dispatch_get_main_queue(), ^{
        replied = YES;
        AppDelegate *current = weakSelf;
        if (!current) return;
        NSMutableDictionary *event = [context mutableCopy];
        event[@"late"] = @(timedOut);
        event[@"documentCurrent"] = @(
            [current.playbackDocument isEqualToString:document] &&
            current.playbackControlGeneration == generation);
        if ([result isKindOfClass:NSDictionary.class] &&
            [result[@"requestId"] isEqual:requestId] &&
            [result[@"accepted"] isKindOfClass:NSNumber.class]) {
          event[@"accepted"] = @([result[@"accepted"] boolValue]);
          // Only copy known, bounded diagnostics. Never log a document token,
          // an arbitrary Flutter error message, or platform-channel payload.
          NSArray *reasons = @[
            @"disposed", @"unsupported-method", @"invalid-request-id",
            @"stale-document", @"not-foreground", @"unsupported-action",
            @"no-visible-player", @"not-operable", @"invalid-seek",
            @"command-error", @"session-changed", @"session-inactive",
            @"dispatched"
          ];
          event[@"reason"] = [reasons containsObject:result[@"reason"]] ? result[@"reason"] : @"unknown";
          for (NSString *key in @[@"stateMatches", @"paused"]) {
            if ([result[key] isKindOfClass:NSNumber.class]) event[key] = @([result[key] boolValue]);
          }
        } else if ([result isKindOfClass:NSNumber.class]) {
          event[@"accepted"] = @([result boolValue]);
          event[@"reason"] = @"legacy-reply";
        } else {
          event[@"accepted"] = @NO;
          event[@"reason"] = [result isKindOfClass:FlutterError.class] ? @"flutter-error" : @"invalid-reply";
        }
        [current recordPlaybackAudioEvent:@"command-acknowledged" fields:event];
      });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
      if (replied) return;
      timedOut = YES;
      NSMutableDictionary *event = [context mutableCopy];
      event[@"reason"] = @"no-flutter-reply";
      [weakSelf recordPlaybackAudioEvent:@"command-timeout" fields:event];
    });
  });
  // MPRemoteCommand's handler is synchronous. Success here means delivery was
  // queued; Flutter's result above reports acceptance and observed state.
  // Blocking this thread for that result could deadlock Flutter's UI thread.
  return MPRemoteCommandHandlerStatusSuccess;
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
  NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
  NSNumber *options = notification.userInfo[AVAudioSessionInterruptionOptionKey];
  [self recordPlaybackAudioEvent:@"audio-interruption" fields:@{
    @"type": type ?: NSNull.null,
    @"shouldResume": @((options.unsignedIntegerValue & AVAudioSessionInterruptionOptionShouldResume) != 0),
    @"native": @(self.nativePlayback)
  }];
  if (type && type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
    [self pauseNativePlaybackFromSource:@"audio-interruption"];
  }
}

- (NSArray<NSString *> *)audioPortTypes:(AVAudioSessionRouteDescription *)route {
  NSMutableArray<NSString *> *types = [NSMutableArray array];
  for (AVAudioSessionPortDescription *port in route.outputs) {
    if (port.portType) [types addObject:port.portType];
  }
  return types;
}

- (void)audioRouteChanged:(NSNotification *)notification {
  NSNumber *reason = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
  if (self.playbackDiagnosticsEnabled) {
    AVAudioSessionRouteDescription *previous =
        notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
    [self recordPlaybackAudioEvent:@"audio-route" fields:@{
      @"reason": reason ?: NSNull.null, @"native": @(self.nativePlayback),
      @"previousOutputs": [self audioPortTypes:previous],
      @"currentOutputs": [self audioPortTypes:AVAudioSession.sharedInstance.currentRoute]
    }];
  }
  if (reason && reason.unsignedIntegerValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
    [self pauseNativePlaybackFromSource:@"audio-route"];
  }
}

- (void)pauseNativePlaybackFromSource:(NSString *)source {
  // Calls, Siri and disconnected headphones latch pause through the same
  // document-scoped control path. Interruption end never resumes playback.
  // A route notification does not prove that an AirPod was removed.
  if (self.nativePlayback) {
    [self forwardPlaybackCommand:@"pause" value:nil source:source];
  }
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
  self.playbackControlGeneration++;
  self.playbackDocument = nil;
  self.nativePlayback = NO;
}

// Cancel downloads left by releases that used the retired WebView cache.
- (void)retirePlaybackDownloads {
  if (self.retiredPlaybackDownloads) return;
  NSURLSessionConfiguration *configuration =
      [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:
          @"app.bahaplus.mobile.hls-cache"];
  configuration.sessionSendsLaunchEvents = NO;
  self.retiredPlaybackDownloads =
      [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
  [self.retiredPlaybackDownloads invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (session != self.retiredPlaybackDownloads) return;
    self.retiredPlaybackDownloads = nil;
    void (^completion)(void) = self.retiredPlaybackCompletion;
    self.retiredPlaybackCompletion = nil;
    if (completion) completion();
  });
}

- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
    completionHandler:(void (^)(void))completionHandler {
  if ([identifier isEqualToString:@"app.bahaplus.mobile.hls-cache"]) {
    self.retiredPlaybackCompletion = completionHandler;
    [self retirePlaybackDownloads];
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
