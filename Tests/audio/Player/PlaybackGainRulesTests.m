//
//  PlaybackGainRulesTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "PlaybackGainRules.h"
#import "VibeTestTrack.h"

@interface PlaybackGainRulesTests : XCTestCase
@end

@implementation PlaybackGainRulesTests

- (void)testDecibelsConvertAsTenToTheTwentieth {
    XCTAssertEqual(VibeFileGainFromDecibels(0), 1.0f);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(-6.0206f), 0.5f, 1e-5);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(6.0206f), 2.0f, 1e-5);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(-20), 0.1f, 1e-7);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(-7.5f), 0.421697f, 1e-6);
    XCTAssertEqual(VibeFileGainFromDecibels(-INFINITY), 0.0f);
}

- (void)testAGainInRangeIsAppliedAsGiven {
    for (NSNumber *gain in @[@0, @0.25, @0.5, @1, @2, @15.8, @100]) {
        XCTAssertEqual(VibeFileGainApplied(gain.floatValue), gain.floatValue);
    }
}

- (void)testTheGuardHoldsEveryOtherValue {
    XCTAssertEqual(VibeFileGainApplied(NAN), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainApplied(-0.5f), 0.0f);
    XCTAssertEqual(VibeFileGainApplied(-INFINITY), 0.0f);
    XCTAssertEqual(VibeFileGainApplied(1000), kVibeFileGainMaximum);
    XCTAssertEqual(VibeFileGainApplied(INFINITY), kVibeFileGainMaximum);
}

// An item with no fileGain plays at unity, and one with a gain at it, guarded.
- (void)testAnItemsGainIsReadThroughTheGuard {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/a.wav"];
    XCTAssertEqual(VibeFileGainOfItem(nil), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItem((id<VibePlayableItem>)[NSObject new]), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItem([VibeTestTrack withURL:url]), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItem([VibeTestTrack withURL:url fileGain:0.25f]), 0.25f);
    XCTAssertEqual(VibeFileGainOfItem([VibeTestTrack withURL:url fileGain:NAN]), kVibeFileGainUnity);
}

// A DSD file plays at the item's dsdFileGain, through the guard, and any
// other file at its fileGain. An item without a DSD gain plays a DSD file at
// its fileGain.
- (void)testADSDFilePlaysAtTheItemsDSDGain {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/a.dsf"];
    VibeTestTrack *track = [VibeTestTrack withURL:url fileGain:0.5f dsdFileGain:2];
    XCTAssertEqual(VibeFileGainOfItemInFile(track, YES), 2.0f);
    XCTAssertEqual(VibeFileGainOfItemInFile(track, NO), 0.5f);
    XCTAssertEqual(VibeFileGainOfItemInFile([VibeTestTrack withURL:url fileGain:0.5f], YES), 0.5f,
                   @"no DSD gain: its fileGain");
    XCTAssertEqual(VibeFileGainOfItemInFile(nil, YES), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItemInFile([VibeTestTrack withURL:url fileGain:1 dsdFileGain:NAN], YES),
                   kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItemInFile([VibeTestTrack withURL:url fileGain:1 dsdFileGain:1000], YES),
                   kVibeFileGainMaximum);
}

@end
