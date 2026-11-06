#import <XCTest/XCTest.h>
#import <Flutter/Flutter.h>

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests
- (void)testFlutterEngineAvailable {
  XCTAssertNotNil(NSClassFromString(@"FlutterEngine"));
}
@end
