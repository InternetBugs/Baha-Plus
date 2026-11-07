#import <XCTest/XCTest.h>
#import <Flutter/Flutter.h>

@protocol BahaPlaybackCacheTesting <NSObject>
+ (instancetype)shared;
- (void)prepare:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion;
- (void)stop:(NSString *)document;
@end

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests
- (void)testFlutterEngineAvailable {
  XCTAssertNotNil(NSClassFromString(@"FlutterEngine"));
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
@end
