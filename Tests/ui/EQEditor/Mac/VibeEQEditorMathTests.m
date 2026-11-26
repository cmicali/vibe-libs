//
//  VibeEQEditorMathTests.m
//  EQEditorTests
//
//  The editor's axes both ways, its steps and rounding, the node hit test,
//  the graphic columns, and how it writes and reads numbers.
//

#import <XCTest/XCTest.h>

#import "VibeEQEditorFormat.h"
#import "VibeEQEditorMath.h"

@interface VibeEQEditorMathTests : XCTestCase
@end

@implementation VibeEQEditorMathTests

- (void)testFrequencyAxisIsLogFromTwentyHertzToTwentyKilohertz {
    XCTAssertEqualWithAccuracy(VibeEQXForFrequency(20, 10, 300), 10, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQXForFrequency(20000, 10, 300), 310, 1e-9);
    // Three decades, so each takes a third.
    XCTAssertEqualWithAccuracy(VibeEQXForFrequency(200, 10, 300), 110, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQXForFrequency(2000, 10, 300), 210, 1e-9);
    // Outside the axis, held to its ends.
    XCTAssertEqualWithAccuracy(VibeEQXForFrequency(5, 10, 300), 10, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQXForFrequency(96000, 10, 300), 310, 1e-9);
}

- (void)testFrequencyAxisRoundTrips {
    for (double f = 20; f <= 20000; f *= 1.37) {
        CGFloat x = VibeEQXForFrequency(f, 38, 512);
        XCTAssertEqualWithAccuracy(VibeEQFrequencyForX(x, 38, 512), f, f * 1e-9);
    }
    XCTAssertEqualWithAccuracy(VibeEQFrequencyForX(-100, 38, 512), 20, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQFrequencyForX(9999, 38, 512), 20000, 1e-6);
    XCTAssertEqualWithAccuracy(VibeEQFrequencyForX(50, 38, 0), 20, 1e-9);
}

- (void)testGainAxisRoundTripsAtBothRanges {
    for (double range = 12; range <= 24; range += 12) {
        XCTAssertEqualWithAccuracy(VibeEQYForGain(-range, 20, 200, range), 20, 1e-9);
        XCTAssertEqualWithAccuracy(VibeEQYForGain(0, 20, 200, range), 120, 1e-9);
        XCTAssertEqualWithAccuracy(VibeEQYForGain(range, 20, 200, range), 220, 1e-9);
        for (double db = -range; db <= range; db += 0.5) {
            CGFloat y = VibeEQYForGain(db, 20, 200, range);
            XCTAssertEqualWithAccuracy(VibeEQGainForY(y, 20, 200, range), db, 1e-9);
        }
    }
}

- (void)testGainPastTheAxisGoesOnToTwentyFour {
    // Ten points over the top of a ±12 axis 200 high is 1.2 dB past +12.
    XCTAssertEqualWithAccuracy(VibeEQGainForY(230, 20, 200, 12), 13.2, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQGainForY(10000, 20, 200, 12), 24, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQGainForY(-10000, 20, 200, 12), -24, 1e-9);
    // Drawn, a gain past the axis sits on its edge.
    XCTAssertEqualWithAccuracy(VibeEQYForGain(18, 20, 200, 12), 220, 1e-9);
}

- (void)testRangeWidensOnlyPastTwelve {
    XCTAssertEqual(VibeEQRangeForPeak(0), 12);
    XCTAssertEqual(VibeEQRangeForPeak(12), 12);
    XCTAssertEqual(VibeEQRangeForPeak(-12), 12);
    XCTAssertEqual(VibeEQRangeForPeak(12.1), 24);
    XCTAssertEqual(VibeEQRangeForPeak(-18), 24);
}

- (void)testGainSnapsToItsStepAndLimit {
    XCTAssertEqual(VibeEQSnapGain(3.26, 0.5, 12), 3.5);
    XCTAssertEqual(VibeEQSnapGain(3.24, 0.5, 12), 3);
    XCTAssertEqual(VibeEQSnapGain(-0.2, 0.5, 12), 0);
    XCTAssertFalse(signbit(VibeEQSnapGain(-0.2, 0.5, 12)));
    XCTAssertEqual(VibeEQSnapGain(15, 0.5, 12), 12);
    XCTAssertEqual(VibeEQSnapGain(-30, 0.1, 24), -24);
    XCTAssertEqualWithAccuracy(VibeEQSnapGain(1.234, 0.1, 24), 1.2, 1e-12);
}

- (void)testFrequencyAndQRoundToFewFigures {
    XCTAssertEqual(VibeEQRoundFrequency(1234.5), 1230);
    XCTAssertEqualWithAccuracy(VibeEQRoundFrequency(98.76), 98.8, 1e-9);
    XCTAssertEqual(VibeEQRoundFrequency(19999), 20000);
    XCTAssertEqual(VibeEQRoundFrequency(3), 20);
    XCTAssertEqualWithAccuracy(VibeEQRoundQ(1.414), 1.4, 1e-12);
    XCTAssertEqualWithAccuracy(VibeEQRoundQ(0.7071), 0.71, 1e-12);
    XCTAssertEqual(VibeEQRoundQ(25), 10);
    XCTAssertEqualWithAccuracy(VibeEQRoundQ(0.01), 0.1, 1e-12);
}

- (void)testQGesturesDoubleAndHalveWithinTheirRange {
    XCTAssertEqualWithAccuracy(VibeEQQForVerticalDrag(1, 60), 2, 1e-12);
    XCTAssertEqualWithAccuracy(VibeEQQForVerticalDrag(1, -60), 0.5, 1e-12);
    XCTAssertEqualWithAccuracy(VibeEQQForVerticalDrag(8, 600), 10, 1e-12);
    XCTAssertEqualWithAccuracy(VibeEQQForScroll(1, 40), 2, 1e-12);
    XCTAssertEqualWithAccuracy(VibeEQQForScroll(0.2, -400), 0.1, 1e-12);
    XCTAssertEqualWithAccuracy(VibeEQFrequencyByOctaves(1000, 1), 2000, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQFrequencyByOctaves(15000, 1), 20000, 1e-9);
}

- (void)testNodeHitTestFindsTheNearestWithinTheRadius {
    CGPoint nodes[] = {{100, 100}, {110, 100}, {300, 50}};
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(101, 101), 12), 0u);
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(108, 100), 12), 1u);
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(305, 58), 12), 2u);
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(200, 200), 12), (NSUInteger)NSNotFound);
    // Exactly between two, the later one wins, since it is drawn on top.
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(105, 100), 12), 1u);
    // On the radius counts; past it doesn't.
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(312, 50), 12), 2u);
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 3, CGPointMake(312.5, 50), 12), (NSUInteger)NSNotFound);
    XCTAssertEqual(VibeEQNodeIndexAtPoint(nodes, 0, CGPointMake(100, 100), 12), (NSUInteger)NSNotFound);
}

- (void)testGraphicColumnsSplitTheWidthEvenly {
    XCTAssertEqual(VibeEQColumnAtX(10, 10, 500, 10), 0u);
    XCTAssertEqual(VibeEQColumnAtX(59.9, 10, 500, 10), 0u);
    XCTAssertEqual(VibeEQColumnAtX(60, 10, 500, 10), 1u);
    XCTAssertEqual(VibeEQColumnAtX(509.9, 10, 500, 10), 9u);
    XCTAssertEqual(VibeEQColumnAtX(510, 10, 500, 10), (NSUInteger)NSNotFound);
    XCTAssertEqual(VibeEQColumnAtX(9, 10, 500, 10), (NSUInteger)NSNotFound);
    XCTAssertEqualWithAccuracy(VibeEQColumnCenterX(0, 10, 500, 10), 35, 1e-9);
    XCTAssertEqualWithAccuracy(VibeEQColumnCenterX(9, 10, 500, 10), 485, 1e-9);
    for (NSUInteger i = 0; i < 10; i++) {
        XCTAssertEqual(VibeEQColumnAtX(VibeEQColumnCenterX(i, 10, 500, 10), 10, 500, 10), i);
    }
}

- (void)testANewBandGoesInTheWidestGap {
    XCTAssertEqual(VibeEQFrequencyForNewBand(NULL, 0), 1000);
    double one[] = {1000};
    // 20 to 1000 is wider than 1000 to 20000 on the log axis.
    XCTAssertEqualWithAccuracy(VibeEQFrequencyForNewBand(one, 1), sqrt(20 * 1000), 1e-9);
    double three[] = {8000, 30, 1000};
    XCTAssertEqualWithAccuracy(VibeEQFrequencyForNewBand(three, 3), sqrt(30 * 1000), 1e-9);
    double edge[] = {20000, 20};
    XCTAssertEqualWithAccuracy(VibeEQFrequencyForNewBand(edge, 2), sqrt(20 * 20000), 1e-9);
}

- (void)testTheSelectionAfterARemoval {
    XCTAssertEqual(VibeEQSelectionAfterRemoving(1, 3), 1u);
    XCTAssertEqual(VibeEQSelectionAfterRemoving(3, 3), 2u);
    XCTAssertEqual(VibeEQSelectionAfterRemoving(0, 0), (NSUInteger)NSNotFound);
}

- (void)testNumbersReadInTheLocalesDigits {
    NSLocale *english = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSLocale *german = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
    XCTAssertEqualObjects(VibeEQFormatFrequency(1000, english), @"1,000 Hz");
    XCTAssertEqualObjects(VibeEQFormatFrequency(1000, german), @"1.000 Hz");
    XCTAssertEqualObjects(VibeEQFormatFrequency(31.4, english), @"31 Hz");
    XCTAssertEqualObjects(VibeEQFormatShortFrequency(31, english), @"31");
    XCTAssertEqualObjects(VibeEQFormatShortFrequency(1000, english), @"1k");
    XCTAssertEqualObjects(VibeEQFormatShortFrequency(2500, english), @"2.5k");
    XCTAssertEqualObjects(VibeEQFormatShortFrequency(2500, german), @"2,5k");
    XCTAssertEqualObjects(VibeEQFormatShortFrequency(16000, english), @"16k");
    XCTAssertEqualObjects(VibeEQFormatGain(3, english), @"+3.0 dB");
    XCTAssertEqualObjects(VibeEQFormatGain(-4.5, german), @"-4,5 dB");
    XCTAssertEqualObjects(VibeEQFormatGain(-0.01, english), @"0.0 dB");
    XCTAssertEqualObjects(VibeEQFormatQ(1.414, english), @"1.4");
    XCTAssertEqualObjects(VibeEQFormatQ(0.7071, english), @"0.71");
    XCTAssertEqualObjects(VibeEQFormatQ(10, english), @"10");
    XCTAssertEqualObjects(VibeEQFormatQ(1, english), @"1.0");
    XCTAssertEqualObjects(VibeEQFormatFieldNumber(1000, 0, 0, english), @"1000");
    XCTAssertEqualObjects(VibeEQFormatFieldNumber(-3, 1, 1, english), @"-3.0");
    XCTAssertEqualObjects(VibeEQFormatFieldNumber(-0.04, 1, 1, english), @"0.0");
    XCTAssertEqualObjects(VibeEQFormatFieldNumber(0.707, 0, 2, german), @"0,71");
}

- (void)testTypedNumbersParse {
    NSLocale *english = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSLocale *german = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
    double value = 0;
    XCTAssertTrue(VibeEQParseNumber(@"1000", english, &value));
    XCTAssertEqual(value, 1000);
    XCTAssertTrue(VibeEQParseNumber(@" 1,000 Hz", english, &value));
    XCTAssertEqual(value, 1000);
    XCTAssertTrue(VibeEQParseNumber(@"2.5k", english, &value));
    XCTAssertEqual(value, 2500);
    XCTAssertTrue(VibeEQParseNumber(@"2,5 kHz", german, &value));
    XCTAssertEqual(value, 2500);
    XCTAssertTrue(VibeEQParseNumber(@"-3.5 dB", english, &value));
    XCTAssertEqual(value, -3.5);
    XCTAssertTrue(VibeEQParseNumber(@"−4,5", german, &value));
    XCTAssertEqual(value, -4.5);
    XCTAssertTrue(VibeEQParseNumber(@"+6", english, &value));
    XCTAssertEqual(value, 6);
    XCTAssertTrue(VibeEQParseNumber(@".7", english, &value));
    XCTAssertEqualWithAccuracy(value, 0.7, 1e-12);
    XCTAssertFalse(VibeEQParseNumber(@"", english, &value));
    XCTAssertFalse(VibeEQParseNumber(@"loud", english, &value));
    XCTAssertFalse(VibeEQParseNumber(@"-", english, &value));
}

@end
