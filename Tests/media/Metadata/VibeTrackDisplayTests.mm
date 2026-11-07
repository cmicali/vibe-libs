//
//  VibeTrackDisplayTests.mm
//  The metadata tests
//
//  What a row shows of a whole file and of a CUE window, over the real parse
//  of a tagged and an untagged FLAC.
//

#import <XCTest/XCTest.h>

#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "VibeTrackDisplay.h"

@interface VibeTrackDisplayTests : XCTestCase
@end

@implementation VibeTrackDisplayTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = VibeTagFixtureDirectory();
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// A FLAC with these tags, or none, parsed.
- (AudioTrackMetadata *)parse:(NSString *)name tags:(NSDictionary<NSString *, NSString *> *)tags url:(NSURL **)url {
    NSURL *file = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue(VibeWriteTagFixtureAudio(file, VibeTagFixtureFLAC));
    TagLib::PropertyMap properties;
    for (NSString *key in tags) {
        properties[VibeTagString(key)] = TagLib::StringList(VibeTagString(tags[key]));
    }
    XCTAssertTrue(VibeSaveTagFixtureTags(file, VibeTagFixtureFLAC, properties, nil, NO));
    *url = file;
    return [AudioTrackMetadata metadataWithURL:file displayArtData:NULL];
}

- (void)testATaggedFileShowsItsTags {
    NSURL *url = nil;
    AudioTrackMetadata *metadata = [self parse:@"Song.flac" tags:@{@"TITLE": @"Blue", @"ARTIST": @"Kind"} url:&url];
    XCTAssertEqualObjects(VibeTrackTitle(metadata, url, nil), @"Blue");
    XCTAssertEqualObjects(VibeTrackArtist(metadata, nil), @"Kind");
    XCTAssertEqualWithAccuracy(VibeTrackDuration(metadata, 0, 0), metadata.duration, 0.0001);
    XCTAssertGreaterThan(metadata.duration, 0);
}

// A tagless file's parse keeps its name as its title, which is no title.
- (void)testATaglessFileHasNoTitleOrArtist {
    NSURL *url = nil;
    AudioTrackMetadata *metadata = [self parse:@"Untitled Take.flac" tags:@{} url:&url];
    XCTAssertEqualObjects(metadata.title, @"Untitled Take");
    XCTAssertNil(VibeTrackTitle(metadata, url, nil));
    XCTAssertNil(VibeTrackArtist(metadata, nil));
    XCTAssertNil(VibeTrackTitle(nil, url, nil), @"none while it loads");
    XCTAssertEqual(VibeTrackDuration(nil, 0, 0), 0);
}

// The sheet's names win over the image's tags, and a window is its own
// length, before its tags load too.
- (void)testAWindowShowsItsSheetsNamesAndLength {
    NSURL *url = nil;
    AudioTrackMetadata *metadata = [self parse:@"Image.flac" tags:@{@"TITLE": @"Whole", @"ARTIST": @"Band"} url:&url];
    XCTAssertEqualObjects(VibeTrackTitle(metadata, url, @"Track Two"), @"Track Two");
    XCTAssertEqualObjects(VibeTrackArtist(metadata, @"Guest"), @"Guest");
    XCTAssertEqualObjects(VibeTrackTitle(metadata, url, @""), @"Whole", @"an empty name is none");
    XCTAssertEqualObjects(VibeTrackArtist(metadata, nil), @"Band");
    XCTAssertEqualWithAccuracy(VibeTrackDuration(nil, 75, 225), 2, 0.0001);
    // The last window runs to the file's end.
    NSTimeInterval file = metadata.duration;
    XCTAssertEqualWithAccuracy(VibeTrackDuration(metadata, 15, 0), file - 0.2, 0.0001);
    XCTAssertEqual(VibeTrackDuration(nil, 15, 0), 0, @"unknown until the file's length is");
}

@end
