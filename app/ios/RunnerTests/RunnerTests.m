#import <XCTest/XCTest.h>
#import <Flutter/Flutter.h>
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import "../Runner/AppDelegate.h"

@interface AppDelegate (BahaPlaybackEnvironmentTesting)
@property(nonatomic, strong) FlutterMethodChannel *playbackEnvironmentChannel;
@property(nonatomic, copy) NSString *playbackDocument;
@property(nonatomic, assign) BOOL nativePlayback;
@property(nonatomic, assign) BOOL playbackDiagnosticsEnabled;
@property(nonatomic, assign) NSUInteger playbackControlGeneration;
@property(nonatomic, strong) id remotePlayTarget;
- (void)installPlaybackControls;
- (void)clearPlaybackControls;
- (MPRemoteCommandHandlerStatus)forwardPlaybackCommand:(NSString *)action;
- (void)recordPlaybackAudioEvent:(NSString *)stage fields:(NSDictionary *)fields;
- (void)audioSessionInterrupted:(NSNotification *)notification;
- (void)audioRouteChanged:(NSNotification *)notification;
@end

// A channel double never opens a Flutter engine, network connection or player.
@interface BahaPlaybackEnvironmentChannel : NSObject
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *requests;
@property(nonatomic, copy) void (^handler)(NSDictionary *, FlutterResult);
@end

@implementation BahaPlaybackEnvironmentChannel
- (instancetype)init {
  if ((self = [super init])) _requests = [NSMutableArray array];
  return self;
}

- (void)invokeMethod:(NSString *)method arguments:(id)arguments result:(FlutterResult)result {
  NSAssert([method isEqualToString:@"remoteCommand"], @"Unexpected channel method");
  [self.requests addObject:arguments];
  if (self.handler) {
    self.handler(arguments, result);
  } else {
    result(@{
      @"requestId": arguments[@"requestId"], @"accepted": @YES,
      @"reason": @"dispatched", @"stateMatches": @YES, @"paused": @YES
    });
  }
}
@end

@interface BahaPlaybackDelegate : AppDelegate
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *audioEvents;
@property(nonatomic, copy) void (^onAudioEvent)(NSDictionary *);
@end

@implementation BahaPlaybackDelegate
- (instancetype)init {
  if ((self = [super init])) _audioEvents = [NSMutableArray array];
  return self;
}

- (void)recordPlaybackAudioEvent:(NSString *)stage fields:(NSDictionary *)fields {
  NSMutableDictionary *event = [fields mutableCopy];
  event[@"stage"] = stage;
  [self.audioEvents addObject:[event copy]];
  if (self.onAudioEvent) self.onAudioEvent(event);
}
@end

@protocol BahaPlaybackCacheTesting <NSObject>
+ (instancetype)shared;
- (void)prepare:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion;
- (void)stop:(NSString *)document;
- (void)setApplicationActive:(BOOL)active;
- (void)reconnect:(void (^)(void))completion;
@end

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests
- (void)testFlutterEngineAvailable {
  XCTAssertNotNil(NSClassFromString(@"FlutterEngine"));
}

- (BahaPlaybackDelegate *)playbackDelegate:(BahaPlaybackEnvironmentChannel *)channel {
  BahaPlaybackDelegate *delegate = [BahaPlaybackDelegate new];
  delegate.playbackEnvironmentChannel = (FlutterMethodChannel *)channel;
  delegate.playbackDocument = @"private-document-token";
  delegate.nativePlayback = YES;
  delegate.playbackDiagnosticsEnabled = YES;
  return delegate;
}

- (void)testRemotePauseWaitsForFlutterReceiptAndReportsObservedState {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  XCTestExpectation *finished = [self expectationWithDescription:@"Flutter pause acknowledged"];
  delegate.onAudioEvent = ^(NSDictionary *event) {
    if (![event[@"stage"] isEqual:@"command-acknowledged"]) return;
    XCTAssertEqualObjects(event[@"source"], @"remote-command");
    XCTAssertEqualObjects(event[@"action"], @"pause");
    XCTAssertEqualObjects(event[@"requestId"], channel.requests.firstObject[@"requestId"]);
    XCTAssertEqualObjects(event[@"accepted"], @YES);
    XCTAssertEqualObjects(event[@"stateMatches"], @YES);
    XCTAssertEqualObjects(event[@"paused"], @YES);
    XCTAssertEqualObjects(event[@"documentCurrent"], @YES);
    XCTAssertFalse([event.description containsString:@"private-document-token"]);
    [finished fulfill];
  };
  XCTAssertEqual([delegate forwardPlaybackCommand:@"pause"], MPRemoteCommandHandlerStatusSuccess);
  XCTAssertEqual(channel.requests.count, 0);
  XCTAssertEqualObjects(delegate.audioEvents.lastObject[@"stage"], @"command-queued");
  [self waitForExpectations:@[finished] timeout:2];
  XCTAssertEqual(channel.requests.count, 1);
  XCTAssertEqualObjects(channel.requests.firstObject[@"document"], delegate.playbackDocument);
}

- (void)testHandoffReenablesExistingNativeControlsWithoutAddingTargets {
  MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
  BOOL playEnabled = commands.playCommand.enabled;
  BOOL pauseEnabled = commands.pauseCommand.enabled;
  BOOL toggleEnabled = commands.togglePlayPauseCommand.enabled;
  BOOL seekEnabled = commands.changePlaybackPositionCommand.enabled;
  BahaPlaybackDelegate *delegate = [self playbackDelegate:[BahaPlaybackEnvironmentChannel new]];
  [delegate installPlaybackControls];
  id target = delegate.remotePlayTarget;
  XCTAssertNotNil(target);
  commands.playCommand.enabled = NO;
  commands.pauseCommand.enabled = NO;
  commands.togglePlayPauseCommand.enabled = NO;
  [delegate installPlaybackControls];
  XCTAssertTrue(commands.playCommand.enabled);
  XCTAssertTrue(commands.pauseCommand.enabled);
  XCTAssertTrue(commands.togglePlayPauseCommand.enabled);
  XCTAssertEqualObjects(delegate.remotePlayTarget, target);
  [delegate clearPlaybackControls];
  commands.playCommand.enabled = playEnabled;
  commands.pauseCommand.enabled = pauseEnabled;
  commands.togglePlayPauseCommand.enabled = toggleEnabled;
  commands.changePlaybackPositionCommand.enabled = seekEnabled;
}

- (void)testMissingContentOrChannelCannotReportSuccessfulDispatch {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  delegate.playbackDocument = nil;
  XCTAssertEqual([delegate forwardPlaybackCommand:@"pause"], MPRemoteCommandHandlerStatusNoSuchContent);
  XCTAssertEqualObjects(delegate.audioEvents.lastObject[@"reason"], @"no-content");
  delegate.playbackDocument = @"current";
  delegate.playbackEnvironmentChannel = nil;
  XCTAssertEqual([delegate forwardPlaybackCommand:@"pause"], MPRemoteCommandHandlerStatusCommandFailed);
  XCTAssertEqualObjects(delegate.audioEvents.lastObject[@"reason"], @"no-channel");
  XCTAssertEqual(channel.requests.count, 0);
}

- (void)testQueuedCommandCannotReachRecreatedControlsForTheSameDocument {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  XCTestExpectation *finished = [self expectationWithDescription:@"Discard stale queued command"];
  delegate.onAudioEvent = ^(NSDictionary *event) {
    if (![event[@"stage"] isEqual:@"command-discarded"]) return;
    XCTAssertEqualObjects(event[@"reason"], @"session-changed");
    [finished fulfill];
  };
  [delegate forwardPlaybackCommand:@"pause"];
  delegate.playbackControlGeneration++;
  [self waitForExpectations:@[finished] timeout:2];
  XCTAssertEqual(channel.requests.count, 0);
}

- (void)testFlutterRejectionAndMalformedRepliesRemainDistinct {
  for (NSNumber *malformed in @[@NO, @YES]) {
    BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
    BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
    XCTestExpectation *finished = [self expectationWithDescription:@"Record Flutter reply"];
    channel.handler = ^(NSDictionary *arguments, FlutterResult result) {
      if (malformed.boolValue) {
        result([FlutterError errorWithCode:@"failure"
            message:@"https://signed.invalid/media?token=secret" details:nil]);
      } else {
        result(@{
          @"requestId": arguments[@"requestId"], @"accepted": @NO,
          @"reason": @"not-foreground"
        });
      }
    };
    delegate.onAudioEvent = ^(NSDictionary *event) {
      if (![event[@"stage"] isEqual:@"command-acknowledged"]) return;
      XCTAssertEqualObjects(event[@"accepted"], @NO);
      XCTAssertEqualObjects(event[@"reason"], malformed.boolValue ? @"flutter-error" : @"not-foreground");
      XCTAssertNil(event[@"stateMatches"]);
      XCTAssertFalse([event.description containsString:@"secret"]);
      [finished fulfill];
    };
    [delegate forwardPlaybackCommand:@"pause"];
    [self waitForExpectations:@[finished] timeout:2];
  }
}

- (void)testReplyAfterNavigationIsMarkedAsBelongingToTheOldDocument {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  XCTestExpectation *forwarded = [self expectationWithDescription:@"Forward command"];
  __block FlutterResult pendingReply;
  __block NSNumber *requestId;
  channel.handler = ^(NSDictionary *arguments, FlutterResult result) {
    pendingReply = [result copy];
    requestId = arguments[@"requestId"];
    [forwarded fulfill];
  };
  [delegate forwardPlaybackCommand:@"pause"];
  [self waitForExpectations:@[forwarded] timeout:2];
  delegate.playbackDocument = @"next-document";
  XCTestExpectation *finished = [self expectationWithDescription:@"Record stale receipt"];
  delegate.onAudioEvent = ^(NSDictionary *event) {
    if (![event[@"stage"] isEqual:@"command-acknowledged"]) return;
    XCTAssertEqualObjects(event[@"documentCurrent"], @NO);
    [finished fulfill];
  };
  pendingReply(@{@"requestId": requestId, @"accepted": @YES, @"reason": @"dispatched"});
  pendingReply = nil;
  [self waitForExpectations:@[finished] timeout:2];
}

- (void)testAudioNotificationsPauseOnlyForInterruptionStartAndLostRoute {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  XCTestExpectation *finished = [self expectationWithDescription:@"Two safety pauses"];
  finished.expectedFulfillmentCount = 2;
  delegate.onAudioEvent = ^(NSDictionary *event) {
    if ([event[@"stage"] isEqual:@"command-acknowledged"]) [finished fulfill];
  };
  [delegate audioSessionInterrupted:[NSNotification notificationWithName:AVAudioSessionInterruptionNotification
      object:nil userInfo:@{
        AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeEnded),
        AVAudioSessionInterruptionOptionKey: @(AVAudioSessionInterruptionOptionShouldResume)
      }]];
  [delegate audioRouteChanged:[NSNotification notificationWithName:AVAudioSessionRouteChangeNotification
      object:nil userInfo:@{AVAudioSessionRouteChangeReasonKey: @(AVAudioSessionRouteChangeReasonNewDeviceAvailable)}]];
  [delegate audioRouteChanged:[NSNotification notificationWithName:AVAudioSessionRouteChangeNotification
      object:nil userInfo:@{AVAudioSessionRouteChangeReasonKey: @(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)}]];
  [delegate audioSessionInterrupted:[NSNotification notificationWithName:AVAudioSessionInterruptionNotification
      object:nil userInfo:@{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}]];
  [self waitForExpectations:@[finished] timeout:2];
  XCTAssertEqual(channel.requests.count, 2);
  XCTAssertEqualObjects(channel.requests[0][@"action"], @"pause");
  XCTAssertEqualObjects(channel.requests[0][@"source"], @"audio-route");
  XCTAssertEqualObjects(channel.requests[1][@"action"], @"pause");
  XCTAssertEqualObjects(channel.requests[1][@"source"], @"audio-interruption");
  XCTAssertNotEqualObjects(channel.requests[0][@"requestId"], channel.requests[1][@"requestId"]);
}

- (void)testNativeAudioNotificationsDoNotControlTheWebBackend {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  delegate.nativePlayback = NO;
  [delegate audioRouteChanged:[NSNotification notificationWithName:AVAudioSessionRouteChangeNotification
      object:nil userInfo:@{AVAudioSessionRouteChangeReasonKey: @(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)}]];
  [delegate audioSessionInterrupted:[NSNotification notificationWithName:AVAudioSessionInterruptionNotification
      object:nil userInfo:@{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}]];
  XCTAssertEqual(channel.requests.count, 0);
  for (NSDictionary *event in delegate.audioEvents) {
    XCTAssertFalse([event[@"stage"] isEqual:@"command-queued"]);
  }
}

- (void)testMissingFlutterReceiptTimesOutAndALateReplyIsIdentified {
  BahaPlaybackEnvironmentChannel *channel = [BahaPlaybackEnvironmentChannel new];
  BahaPlaybackDelegate *delegate = [self playbackDelegate:channel];
  __block FlutterResult pendingReply;
  __block NSNumber *requestId;
  channel.handler = ^(NSDictionary *arguments, FlutterResult result) {
    pendingReply = [result copy];
    requestId = arguments[@"requestId"];
  };
  XCTestExpectation *timedOut = [self expectationWithDescription:@"Missing Flutter receipt"];
  delegate.onAudioEvent = ^(NSDictionary *event) {
    if (![event[@"stage"] isEqual:@"command-timeout"]) return;
    XCTAssertEqualObjects(event[@"reason"], @"no-flutter-reply");
    [timedOut fulfill];
  };
  [delegate forwardPlaybackCommand:@"pause"];
  [self waitForExpectations:@[timedOut] timeout:8];
  XCTestExpectation *finished = [self expectationWithDescription:@"Late receipt"];
  delegate.onAudioEvent = ^(NSDictionary *event) {
    if (![event[@"stage"] isEqual:@"command-acknowledged"]) return;
    XCTAssertEqualObjects(event[@"late"], @YES);
    [finished fulfill];
  };
  pendingReply(@{@"requestId": requestId, @"accepted": @YES, @"reason": @"dispatched"});
  pendingReply = nil;
  [self waitForExpectations:@[finished] timeout:2];
}

- (id<BahaPlaybackCacheTesting>)cache {
  Class<BahaPlaybackCacheTesting> type =
      (Class<BahaPlaybackCacheTesting>)(NSClassFromString(@"Runner.PlaybackCache") ?:
                                      NSClassFromString(@"PlaybackCache"));
  XCTAssertNotNil(type);
  return [type shared];
}

- (void)testBackgroundCacheRejectsForeignSourceWithoutOpeningTransport {
  XCTestExpectation *finished = [self expectationWithDescription:@"Reject untrusted source"];
  [[self cache] prepare:@{
    @"source": @"https://attacker.invalid/master.m3u8",
    @"document": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"videoId": @"20"
  } completion:^(NSDictionary *result) {
    XCTAssertNil(result);
    [finished fulfill];
  }];
  [self waitForExpectations:@[finished] timeout:5];
}

- (void)testLoopbackGatewayRejectsUnknownResourcesAndOldSessionStop {
  id<BahaPlaybackCacheTesting> cache = [self cache];
  NSString *old = @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  NSString *current = @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  // Preparing a source does not fetch it. This test sends only a loopback
  // request for an unregistered resource, so no real CDN request is made.
  NSString *source = @"https://bahamut.akamaized.net/offline-test/master.m3u8";
  XCTestExpectation *finished = [self expectationWithDescription:@"Loopback isolation"];
  [cache prepare:@{@"source": source, @"document": old, @"videoId": @"20"}
      completion:^(NSDictionary *first) {
    XCTAssertNotNil(first);
    [cache prepare:@{@"source": source, @"document": current, @"videoId": @"21"}
        completion:^(NSDictionary *second) {
      XCTAssertNotNil(second);
      [cache stop:old];
      NSString *base = second[@"base"];
      NSURL *baseURL = [NSURL URLWithString:base];
      XCTAssertEqualObjects(baseURL.host, @"localhost");
      XCTAssertEqualObjects(baseURL.scheme, @"http");
      NSURL *requestURL = [NSURL URLWithString:
          [base stringByAppendingString:@"media.ts?u=https%3A%2F%2Fattacker.invalid%2Fa.ts"]];
      [[[NSURLSession sharedSession] dataTaskWithURL:requestURL
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(((NSHTTPURLResponse *)response).statusCode, 404);
        [cache stop:current];
        [finished fulfill];
      }] resume];
    }];
  }];
  [self waitForExpectations:@[finished] timeout:10];
}

- (void)testForegroundCacheSuspendsWithoutReplacingItsGateway {
  id<BahaPlaybackCacheTesting> cache = [self cache];
  NSString *document = @"cccccccccccccccccccccccccccccccccccccccccccccccc";
  NSDictionary *arguments = @{
    @"source": @"https://bahamut.akamaized.net/offline-test/master.m3u8",
    @"document": document, @"videoId": @"20"
  };
  XCTestExpectation *finished = [self expectationWithDescription:@"Foreground cache lifecycle"];
  [cache setApplicationActive:YES];
  [cache prepare:arguments completion:^(NSDictionary *first) {
    XCTAssertNotNil(first);
    NSString *base = first[@"base"];
    NSURL *unknown = [NSURL URLWithString:[base stringByAppendingString:
        @"media.ts?u=https%3A%2F%2Fattacker.invalid%2Fa.ts"]];
    [cache setApplicationActive:NO];
    [cache prepare:arguments completion:^(NSDictionary *suspended) {
      XCTAssertEqualObjects(suspended[@"base"], base);
      // Unknown resources never access the CDN. All requests are rejected
      // while backgrounded, even though the gateway and its session survive.
      [[[NSURLSession sharedSession] dataTaskWithURL:unknown
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(((NSHTTPURLResponse *)response).statusCode, 503);
        [cache setApplicationActive:YES];
        [cache prepare:arguments completion:^(NSDictionary *resumed) {
          XCTAssertEqualObjects(resumed[@"base"], base);
          [[[NSURLSession sharedSession] dataTaskWithURL:unknown
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqual(((NSHTTPURLResponse *)response).statusCode, 404);
            [cache stop:document];
            [finished fulfill];
          }] resume];
        }];
      }] resume];
    }];
  }];
  [self waitForExpectations:@[finished] timeout:10];
}

- (void)testRetiredBackgroundSessionCompletesWhenNoTransfersRemain {
  XCTestExpectation *finished = [self expectationWithDescription:@"Drain retired session"];
  [[self cache] reconnect:^{ [finished fulfill]; }];
  [self waitForExpectations:@[finished] timeout:5];
}
@end
