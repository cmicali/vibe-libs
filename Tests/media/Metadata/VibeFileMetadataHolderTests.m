//
//  VibeFileMetadataHolderTests.m
//
//  The default holder's key and its install rule. The loader tests run the
//  real loader over it as VibeLoaderTestTrack.
//

#import <XCTest/XCTest.h>

#import "MetadataLoaderTestFakes.h"
#import "VibeFileMetadataHolder.h"

@interface VibeFileMetadataHolderTests : XCTestCase
@end

@implementation VibeFileMetadataHolderTests

static AudioTrackMetadata *Result(BOOL parsedOK, NSString *marker, NSString *cacheKey) {
    AudioTrackMetadata *metadata = VibeLoaderTestMetadataResult(parsedOK, marker);
    ((VibeLoaderTestMetadata *)metadata).cacheKey = cacheKey;
    return metadata;
}

- (void)testAWholeFileIsKeyedByItsPathAndAWindowByItsFrames {
    NSURL *url = [NSURL fileURLWithPath:@"/Music/Album.flac"];
    VibeFileMetadataHolder *whole = [[VibeFileMetadataHolder alloc] initWithURL:url];
    VibeFileMetadataHolder *window = [[VibeFileMetadataHolder alloc] initWithURL:url cueStart:750 cueEnd:1500];

    XCTAssertEqualObjects(whole.sourceKey, @"/Music/Album.flac");
    XCTAssertEqual(whole.cueStart, 0u);
    XCTAssertEqual(whole.cueEnd, 0u);
    XCTAssertEqualObjects(window.sourceKey, @"/Music/Album.flac#750-1500");
    XCTAssertEqual(window.cueStart, 750u);
    XCTAssertEqual(window.cueEnd, 1500u);
}

- (void)testOnlyANewVersionReplacesASuccessfulAnswer {
    VibeFileMetadataHolder *holder =
            [[VibeFileMetadataHolder alloc] initWithURL:[NSURL fileURLWithPath:@"/Music/Song.mp3"]];
    AudioTrackMetadata *failed = Result(NO, @"failed", @"v1");
    AudioTrackMetadata *parsed = Result(YES, @"parsed", @"v1");
    AudioTrackMetadata *again = Result(YES, @"again", @"v1");
    AudioTrackMetadata *newer = Result(YES, @"newer", @"v2");

    XCTAssertTrue([holder installMetadataIfUnresolved:failed]);
    XCTAssertTrue([holder installMetadataIfUnresolved:parsed]);
    XCTAssertFalse([holder installMetadataIfUnresolved:again]);
    XCTAssertEqual(holder.metadata, parsed);
    XCTAssertTrue([holder installMetadataIfUnresolved:newer]);
    XCTAssertEqual(holder.metadata, newer);
}

- (void)testADeliveryRunsOnlyWhileItsAnswerIsInstalled {
    VibeFileMetadataHolder *holder =
            [[VibeFileMetadataHolder alloc] initWithURL:[NSURL fileURLWithPath:@"/Music/Song.mp3"]];
    AudioTrackMetadata *first = Result(YES, @"first", @"v1");
    AudioTrackMetadata *second = Result(YES, @"second", @"v2");
    [holder installMetadataIfUnresolved:first];
    [holder installMetadataIfUnresolved:second];

    __block NSUInteger deliveries = 0;
    XCTAssertFalse([holder deliverIfMetadataStillInstalled:first usingBlock:^{
        deliveries++;
    }]);
    XCTAssertTrue([holder deliverIfMetadataStillInstalled:second usingBlock:^{
        deliveries++;
    }]);
    XCTAssertEqual(deliveries, 1u);
}

@end
