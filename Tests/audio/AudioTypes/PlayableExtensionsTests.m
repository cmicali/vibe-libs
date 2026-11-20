//
// The playable extensions: one lowercase list, its set, and TagLib's share.
//

#import <XCTest/XCTest.h>

#import "PlayableExtensions.h"

@interface PlayableExtensionsTests : XCTestCase
@end

@implementation PlayableExtensionsTests

- (void)testTheListIsLowercaseAndEachSpellingOnce {
    NSArray<NSString *> *ordered = PlayableExtensions.ordered;
    for (NSString *extension in ordered) {
        XCTAssertEqualObjects(extension, extension.lowercaseString);
    }
    XCTAssertEqual(PlayableExtensions.lookup.count, ordered.count);
    XCTAssertEqualObjects(PlayableExtensions.lookup, [NSSet setWithArray:ordered]);
}

- (void)testLosslessComesBeforeLossy {
    NSArray<NSString *> *ordered = PlayableExtensions.ordered;
    XCTAssertLessThan([ordered indexOfObject:@"flac"], [ordered indexOfObject:@"m4a"]);
    XCTAssertLessThan([ordered indexOfObject:@"wav"], [ordered indexOfObject:@"mp3"]);
    XCTAssertLessThan([ordered indexOfObject:@"wv"], [ordered indexOfObject:@"m4a"]);
    XCTAssertLessThan([ordered indexOfObject:@"aifc"], [ordered indexOfObject:@"m4a"]);
}

- (void)testTagLibParsesAllButW64AndCaf {
    NSMutableSet<NSString *> *expected = [PlayableExtensions.lookup mutableCopy];
    [expected removeObject:@"w64"];
    [expected removeObject:@"caf"];
    XCTAssertEqualObjects(PlayableExtensions.tagParsed, expected);
}

@end
