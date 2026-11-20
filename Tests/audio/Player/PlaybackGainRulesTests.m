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

// The DSD gain applies to a DSD file whose item plays at unity, through the
// guard. A leveled item keeps its gain, and a PCM file never takes it.
- (void)testTheDSDGainAppliesOnlyToAnUnleveledDSDFile {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/a.dsf"];
    VibeTestTrack *plain = [VibeTestTrack withURL:url];
    XCTAssertEqual(VibeFileGainOfItemInFile(plain, YES, 2), 2.0f);
    XCTAssertEqual(VibeFileGainOfItemInFile(nil, YES, 2), 2.0f);
    XCTAssertEqual(VibeFileGainOfItemInFile(plain, NO, 2), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItemInFile([VibeTestTrack withURL:url fileGain:0.5f], YES, 2), 0.5f);
    XCTAssertEqual(VibeFileGainOfItemInFile([VibeTestTrack withURL:url fileGain:NAN], YES, 2), 2.0f,
                   @"NaN is unity, so the DSD gain applies");
    XCTAssertEqual(VibeFileGainOfItemInFile(plain, YES, NAN), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainOfItemInFile(plain, YES, 1000), kVibeFileGainMaximum);
}

@end
