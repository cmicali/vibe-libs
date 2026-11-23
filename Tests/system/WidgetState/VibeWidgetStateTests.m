// The snapshot's own arithmetic: the playhead the widget derives from it.
// VibeWidgetPublishRulesTests covers when the app publishes a new one.
// Nothing here reaches the app group container, which on the mac is a real
// directory under ~/Library.

#import <XCTest/XCTest.h>

#import "VibeWidgetState.h"

// The read's parse, past the container, which the tests never reach.
@interface VibeWidgetState (Testing)
+ (nullable VibeWidgetState *)stateFromPlist:(nullable id)plist;
@end

@interface VibeWidgetStateTests : XCTestCase
@end

@implementation VibeWidgetStateTests

- (VibeWidgetState *)stateAt:(NSTimeInterval)position playing:(BOOL)playing {
    VibeWidgetState *state = [[VibeWidgetState alloc] init];
    state.hasTrack = YES;
    state.playing = playing;
    state.duration = 100;
    state.position = position;
    state.positionDate = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
    return state;
}

- (NSDate *)at:(NSTimeInterval)seconds {
    return [NSDate dateWithTimeIntervalSinceReferenceDate:seconds];
}

- (void)testPlayingAdvancesFromThePublishedInstant {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    XCTAssertEqual([state positionAtDate:[self at:1015]], 25);
    XCTAssertEqual([state progressAtDate:[self at:1015]], 0.25);
}

- (void)testPausedHoldsItsPosition {
    XCTAssertEqual([[self stateAt:10 playing:NO] positionAtDate:[self at:1500]], 10);
}

- (void)testThePlayheadIsClampedToTheTrack {
    VibeWidgetState *state = [self stateAt:90 playing:YES];
    XCTAssertEqual([state positionAtDate:[self at:1500]], 100, @"never past the end");
    XCTAssertEqual([state progressAtDate:[self at:1500]], 1);
    XCTAssertEqual([state positionAtDate:[self at:900]], 90, @"a date before the publish adds nothing");
    XCTAssertEqual([[self stateAt:-5 playing:NO] positionAtDate:[self at:1000]], 0);
}

- (void)testNoDurationHasNoProgressAndNoUpperClamp {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    state.duration = 0;
    XCTAssertEqual([state progressAtDate:[self at:1100]], 0);
    XCTAssertEqual([state positionAtDate:[self at:1100]], 110);
}

- (void)testAPlayingSnapshotWithNoDateDoesNotAdvance {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    state.positionDate = nil;
    XCTAssertEqual([state positionAtDate:[self at:1100]], 10);
}

- (void)testASnapshotWithNoTrackKeyNamesNoImages {
    VibeWidgetState *state = [self stateAt:0 playing:NO];
    XCTAssertNil(state.artworkURL);
    XCTAssertNil(state.waveformPlayedURL);
    XCTAssertNil(state.waveformUnplayedURL);
}

#pragma mark - Copying and reading

- (void)testACopyCarriesEveryFieldAndIsItsOwnObject {
    VibeWidgetState *state = [self stateAt:10 playing:YES];
    state.title = @"Song";
    state.artist = @"Artist";
    state.trackKey = @"key";
    state.playheadLine = YES;
    VibeWidgetState *copy = [state copy];
    XCTAssertNotEqual(copy, state);
    XCTAssertEqualObjects(copy.title, @"Song");
    XCTAssertEqualObjects(copy.artist, @"Artist");
    XCTAssertEqualObjects(copy.trackKey, @"key");
    XCTAssertTrue(copy.hasTrack);
    XCTAssertTrue(copy.playing);
    XCTAssertEqual(copy.duration, 100);
    XCTAssertEqual(copy.position, 10);
    XCTAssertEqualObjects(copy.positionDate, state.positionDate);
    XCTAssertTrue(copy.playheadLine);

    copy.playheadLine = NO;
    XCTAssertTrue(state.playheadLine, @"a change to the copy leaves the original");
}

- (NSMutableDictionary *)plist {
    return [@{@"version": @3, @"title": @"Song", @"trackKey": @"key", @"hasTrack": @YES, @"playing": @YES,
              @"duration": @100, @"position": @10, @"positionDate": [self at:1000], @"playheadLine": @NO}
            mutableCopy];
}

- (void)testAWellFormedPlistReads {
    VibeWidgetState *state = [VibeWidgetState stateFromPlist:self.plist];
    XCTAssertEqualObjects(state.title, @"Song");
    XCTAssertNil(state.artist);
    XCTAssertEqual([state positionAtDate:[self at:1015]], 25);
}

- (void)testAFieldOfTheWrongClassReadsAsNoState {
    for (NSString *key in @[@"title", @"artist", @"trackKey", @"playing", @"duration", @"positionDate"]) {
        NSMutableDictionary *plist = self.plist;
        plist[key] = [key isEqualToString:@"positionDate"] || [key isEqualToString:@"duration"]
                ? @"wrong" : (id)@[];
        XCTAssertNil([VibeWidgetState stateFromPlist:plist], @"%@", key);
    }
    XCTAssertNil([VibeWidgetState stateFromPlist:@[]]);
    NSMutableDictionary *old = self.plist;
    old[@"version"] = @2;
    XCTAssertNil([VibeWidgetState stateFromPlist:old], @"an unknown version");
}

@end
