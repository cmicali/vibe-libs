// When the app publishes a new snapshot, and the key that names a track's
// files (VibeWidgetPublishRules.h).

#import <XCTest/XCTest.h>

#import "NSURL+Hash.h"
#import "VibeWidgetPublishRules.h"

// Only what the key reads.
@interface WidgetKeyItem : NSObject <VibePlayableItem>
@property (copy) NSURL *url;
@property NSUInteger cueStart;
@property NSUInteger cueEnd;
@end

@implementation WidgetKeyItem
- (NSString *)sourceKey { return self.url.path; }
- (NSString *)cacheKey { return nil; }
@end

@interface VibeWidgetPublishRulesTests : XCTestCase
@end

@implementation VibeWidgetPublishRulesTests

- (VibeWidgetState *)published {
    VibeWidgetState *state = [[VibeWidgetState alloc] init];
    state.hasTrack = YES;
    state.playing = YES;
    state.title = @"Song";
    state.duration = 180;
    state.position = 10;
    state.positionDate = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
    return state;
}

- (void)testNothingPublishedOrANewTrackPublishes {
    XCTAssertTrue(VibeWidgetNeedsPublish(nil, NO, YES, @"Song", nil, YES, 180, 10, NO, 1000));
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 10, NO, 1000));
}

- (void)testSteadyPlaybackPublishesNothing {
    XCTAssertFalse(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180, 40, NO, 1030),
                   @"the widget extrapolates the playhead");
    XCTAssertFalse(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180.4, 11.9, NO, 1000),
                   @"within the tolerances");
}

- (void)testAPlayPauseADurationTitleOrArtistChangePublishes {
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, NO, 180, 10, NO, 1000));
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 181, 10, NO, 1000));
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Tagged", nil, YES, 180, 10, NO, 1000));
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", @"Artist", YES, 180, 10, NO, 1000),
                  @"an artist landing");
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, NO, @"Song", nil, YES, 180, 10, NO, 1000));
}

- (void)testANilArtistEqualsANilArtist {
    XCTAssertFalse(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180, 10, NO, 1000),
                   @"an artistless track would republish every tick");
}

- (void)testASeekPastTheToleranceRepublishesUnlessTheOpenRuns {
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180, 90, NO, 1000));
    XCTAssertFalse(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180, 0, YES, 1000),
                   @"pinned at 0 while the open runs");
}

- (void)testAPausedSnapshotIsNotExtrapolated {
    VibeWidgetState *paused = self.published;
    paused.playing = NO;
    XCTAssertFalse(VibeWidgetNeedsPublish(paused, NO, YES, @"Song", nil, NO, 180, 10, NO, 1060));
    XCTAssertTrue(VibeWidgetNeedsPublish(paused, NO, YES, @"Song", nil, NO, 180, 15, NO, 1060));
}

- (void)testStartPendingHidesOnlyThePosition {
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, NO, 180, 0, YES, 1000),
                  @"a pause");
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Tagged", nil, YES, 180, 0, YES, 1000),
                  @"a title");
    XCTAssertTrue(VibeWidgetNeedsPublish(self.published, NO, YES, @"Song", nil, YES, 200, 0, YES, 1000),
                  @"a duration");
    VibeWidgetState *paused = self.published;
    paused.playing = NO;
    XCTAssertTrue(VibeWidgetNeedsPublish(paused, NO, YES, @"Song", nil, YES, 180, 0, YES, 1000), @"a play");
}

#pragma mark - The track key

- (void)testATrackKeyIsItsFilesPathKeyAndACueRowAddsItsWindow {
    WidgetKeyItem *item = [WidgetKeyItem new];
    item.url = [NSURL fileURLWithPath:@"/Music/mix.flac"];
    NSString *pathKey = item.url.pathKey;
    XCTAssertNotNil(pathKey);
    XCTAssertEqualObjects(VibeWidgetTrackKey(item), pathKey);

    item.cueStart = 4500;
    item.cueEnd = 9000;
    XCTAssertEqualObjects(VibeWidgetTrackKey(item), [pathKey stringByAppendingString:@"#4500-9000"]);
    XCTAssertNil(VibeWidgetTrackKey(nil));
}

@end
