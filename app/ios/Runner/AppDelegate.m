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

@interface BahaMediaProbe : NSObject
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerItem *item;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) FlutterResult callback;
@property(nonatomic) BOOL observing;
@property(nonatomic) BOOL prerollStarted;
@property(nonatomic) BOOL finished;
- (void)beginWithURL:(NSURL *)url callback:(FlutterResult)callback;
- (void)finish:(NSString *)reason;
@end

@implementation BahaMediaProbe
- (void)beginWithURL:(NSURL *)url callback:(FlutterResult)callback {
  self.callback = callback;
  self.item = [AVPlayerItem playerItemWithURL:url];
  [self.item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
  self.observing = YES;
  self.player = [AVPlayer playerWithPlayerItem:self.item];
  self.player.muted = YES;
  self.timer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:NO block:^(NSTimer *timer) {
    [self finish:@"timeout"];
  }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.finished) return;
    if (self.item.status == AVPlayerItemStatusFailed) {
      [self finish:@"failed"];
    } else if (self.item.status == AVPlayerItemStatusReadyToPlay && !self.prerollStarted) {
      self.prerollStarted = YES;
      // Buffer/decode without starting audible or visible playback.
      [self.player prerollAtRate:1 completionHandler:^(BOOL ready) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self finish:ready ? @"ready" : @"preroll_failed"];
        });
      }];
    }
  });
}

- (void)finish:(NSString *)reason {
  if (self.finished) return;
  self.finished = YES;
  NSMutableArray *events = [NSMutableArray array];
  for (AVPlayerItemErrorLogEvent *event in self.item.errorLog.events) {
    [events addObject:@{@"domain": event.errorDomain ?: @"",
                        @"code": @(event.errorStatusCode)}];
    if (events.count >= 5) break;
  }
  NSDictionary *value = @{
    @"reason": reason,
    @"itemStatus": @(self.item.status),
    @"playerStatus": @(self.player.status),
    @"error": BahaDiagnosticError(self.item.error ?: self.player.error, 0),
    @"events": events
  };
  if (self.observing) {
    [self.item removeObserver:self forKeyPath:@"status"];
    self.observing = NO;
  }
  [self.timer invalidate];
  self.timer = nil;
  [self.player cancelPendingPrerolls];
  [self.player pause];
  self.callback(value);
  self.callback = nil;
  self.player = nil;
  self.item = nil;
}
@end

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
    BahaMediaProbe *probe = [[BahaMediaProbe alloc] init];
    [probe beginWithURL:url callback:result];
  }];
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
