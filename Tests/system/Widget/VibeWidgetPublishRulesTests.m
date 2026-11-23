// When the app publishes a new snapshot (VibeWidgetPublishRules.h).

#import <XCTest/XCTest.h>

#import "VibeWidgetPublishRules.h"

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

// The publisher's own call, asked whether the track is the published one.
static BOOL NeedsPublish(VibeWidgetState *_Nullable last, BOOL sameTrack, BOOL hasTrack, NSString *title,
                         NSString *_Nullable artist, BOOL playing, NSTimeInterval duration,
                         NSTimeInterval position, BOOL startPending, CFAbsoluteTime now) {
    return VibeWidgetNeedsPublish(last, !sameTrack, hasTrack, title, artist, playing, duration, position,
                                  startPending, now);
}

- (void)testNothingPublishedOrANewTrackPublishes {
    XCTAssertTrue(NeedsPublish(nil, YES, YES, @"Song", nil, YES, 180, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, NO, YES, @"Song", nil, YES, 180, 10, NO, 1000));
}

- (void)testSteadyPlaybackPublishesNothing {
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 40, NO, 1030),
                   @"the widget extrapolates the playhead");
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180.4, 11.9, NO, 1000),
                   @"within the tolerances");
}

- (void)testAPlayPauseALineOrADurationChangePublishes {
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", nil, NO, 180, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 181, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Tagged", nil, YES, 180, 10, NO, 1000));
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", @"Artist", YES, 180, 10, NO, 1000),
                  @"an artist landing");
    XCTAssertTrue(NeedsPublish(self.published, YES, NO, @"Song", nil, YES, 180, 10, NO, 1000));
}

- (void)testANilArtistEqualsANilArtist {
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 10, NO, 1000),
                   @"an artistless track would republish every tick");
}

- (void)testASeekPastTheToleranceRepublishesUnlessTheOpenRuns {
    XCTAssertTrue(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 90, NO, 1000));
    XCTAssertFalse(NeedsPublish(self.published, YES, YES, @"Song", nil, YES, 180, 0, YES, 1000),
                   @"pinned at 0 while the open runs");
}

- (void)testAPausedSnapshotIsNotExtrapolated {
    VibeWidgetState *paused = self.published;
    paused.playing = NO;
    XCTAssertFalse(NeedsPublish(paused, YES, YES, @"Song", nil, NO, 180, 10, NO, 1060));
    XCTAssertTrue(NeedsPublish(paused, YES, YES, @"Song", nil, NO, 180, 15, NO, 1060));
}

@end
