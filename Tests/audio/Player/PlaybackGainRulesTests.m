//
//  PlaybackGainRulesTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "PlaybackGainRules.h"

@interface PlaybackGainRulesTests : XCTestCase
@end

@implementation PlaybackGainRulesTests

- (void)testDecibelsConvertAsTwentyTimesTheLog {
    XCTAssertEqual(VibeFileGainFromDecibels(0), 1.0f);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(-6.0206), 0.5f, 1e-5);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(6.0206), 2.0f, 1e-5);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(-20), 0.1f, 1e-7);
    XCTAssertEqualWithAccuracy(VibeFileGainFromDecibels(-7.5), 0.421697f, 1e-6);
}

- (void)testTheInverseReadsBackTheDecibels {
    for (NSNumber *decibels in @[@-23.5, @-7.5, @-0.25, @0, @3.1, @12]) {
        XCTAssertEqualWithAccuracy(VibeFileGainInDecibels(VibeFileGainFromDecibels(decibels.doubleValue)),
                                   decibels.doubleValue, 1e-5, @"%@ dB", decibels);
    }
    XCTAssertEqual(VibeFileGainInDecibels(0), -INFINITY);
}

- (void)testAGainInRangeIsAppliedAsGiven {
    for (NSNumber *gain in @[@0, @0.25, @0.5, @1, @2, @15.8]) {
        XCTAssertEqual(VibeFileGainApplied(gain.floatValue), gain.floatValue);
    }
}

- (void)testAGainPastTwentyFourDecibelsIsHeldThere {
    XCTAssertEqual(VibeFileGainApplied(100), kVibeFileGainMaximum);
    XCTAssertEqual(VibeFileGainApplied(INFINITY), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainFromDecibels(40), kVibeFileGainMaximum);
    XCTAssertEqual(VibeFileGainFromDecibels(INFINITY), kVibeFileGainMaximum);
    XCTAssertEqualWithAccuracy(VibeFileGainInDecibels(kVibeFileGainMaximum), 24, 1e-5);
}

- (void)testANegativeOrUndefinedGainIsUnity {
    XCTAssertEqual(VibeFileGainApplied(-0.5f), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainApplied(NAN), kVibeFileGainUnity);
    XCTAssertEqual(VibeFileGainFromDecibels(NAN), kVibeFileGainUnity);
}

- (void)testMinusInfinityDecibelsIsSilence {
    XCTAssertEqual(VibeFileGainFromDecibels(-INFINITY), 0.0f);
}

@end
