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
    // caf can hold either, so an app may take everything before it as lossless.
    XCTAssertLessThan([ordered indexOfObject:@"dsf"], [ordered indexOfObject:@"caf"]);
}

- (void)testTagLibParsesAllButW64AndCaf {
    NSMutableSet<NSString *> *expected = [PlayableExtensions.lookup mutableCopy];
    [expected removeObject:@"w64"];
    [expected removeObject:@"caf"];
    XCTAssertEqualObjects(PlayableExtensions.tagParsed, expected);
}

// A .wvc is looked for in the .wv's case first, then in lowercase and in
// uppercase, and a file with no extension looks for .wvc. The other way, a
// .wvc names its .wv the same three ways, and anything else names none.
- (void)testAWavPackCorrectionFileIsSpelledBothWays {
    NSArray<NSString *> *(^names)(NSString *) = ^NSArray<NSString *> *(NSString *path) {
        return [[PlayableExtensions wavPackCorrectionSpellingsOf:[NSURL fileURLWithPath:path]] valueForKey:@"lastPathComponent"];
    };
    XCTAssertEqualObjects(names(@"/a/song.wv"), (@[@"song.wvc", @"song.WVC"]));
    XCTAssertEqualObjects(names(@"/a/SONG.WV"), (@[@"SONG.WVC", @"SONG.wvc"]));
    XCTAssertEqualObjects(names(@"/a/song.Wv"), (@[@"song.Wvc", @"song.wvc", @"song.WVC"]));
    XCTAssertEqualObjects(names(@"/a/song"), (@[@"song.wvc", @"song.WVC"]));
    XCTAssertEqualObjects([PlayableExtensions wavPackPathsOfCorrectionPath:@"a/song.wvc"], (@[@"a/song.wv", @"a/song.WV"]));
    XCTAssertEqualObjects([PlayableExtensions wavPackPathsOfCorrectionPath:@"a/LOUD.WVC"], (@[@"a/LOUD.WV", @"a/LOUD.wv"]));
    XCTAssertEqualObjects([PlayableExtensions wavPackPathsOfCorrectionPath:@"a/song.wv"], @[]);
    XCTAssertEqualObjects([PlayableExtensions wavPackPathsOfCorrectionPath:@"a/song"], @[]);
}

@end
