//
// The Camelot key colors: one hue per wheel number, 1 green, resolved per
// appearance.
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>

#import "MusicalKeyColor.h"

@interface MusicalKeyColorTests : XCTestCase
@end

@implementation MusicalKeyColorTests

- (NSColor *)color:(NSColor *)color in:(NSAppearanceName)name {
    __block NSColor *resolved = nil;
    [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
        resolved = [color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    }];
    return resolved;
}

- (void)testAKeyThatIsNotValidHasNoColor {
    XCTAssertNil(VibeMusicalKeyCamelotColor(VibeMusicalKeyNone));
    XCTAssertNil(VibeMusicalKeyCamelotColor(24));
    XCTAssertNil(VibeMusicalKeyCamelotColor(-7));
}

- (void)testEveryKeyHasAColor {
    for (VibeMusicalKey key = 0; key < 24; key++) {
        XCTAssertNotNil(VibeMusicalKeyCamelotColor(key), @"key %ld", (long)key);
    }
}

// 1 is green, and each number is a twelfth of the hue circle on. Around the
// wheel from 1B, each key a fifth up is the next number.
- (void)testNumberOneIsGreenAndTheHuesStepByATwelfth {
    CGFloat previous = 0;
    for (NSInteger number = 1; number <= 12; number++) {
        VibeMusicalKey key = VibeMusicalKeyMake((11 + 7 * (number - 1)) % 12, NO);
        XCTAssertEqual(VibeMusicalKeyCamelotNumber(key), number);
        NSColor *color = [self color:VibeMusicalKeyCamelotColor(key) in:NSAppearanceNameAqua];
        if (number == 1) {
            XCTAssertEqualWithAccuracy(color.hueComponent, 1.0 / 3.0, 0.01);
            XCTAssertGreaterThan(color.greenComponent, color.redComponent);
            XCTAssertGreaterThan(color.greenComponent, color.blueComponent);
        } else {
            XCTAssertEqualWithAccuracy(fmod(color.hueComponent - previous + 1.0, 1.0), 1.0 / 12.0, 0.01,
                                       @"number %ld", (long)number);
        }
        previous = color.hueComponent;
    }
}

// A relative major and minor share a wheel number, and so a color.
- (void)testARelativeMajorAndMinorShareAColor {
    for (NSInteger pitchClass = 0; pitchClass < 12; pitchClass++) {
        VibeMusicalKey major = VibeMusicalKeyMake(pitchClass, NO);
        VibeMusicalKey minor = VibeMusicalKeyMake((pitchClass + 9) % 12, YES);
        XCTAssertEqual(VibeMusicalKeyCamelotNumber(major), VibeMusicalKeyCamelotNumber(minor));
        XCTAssertEqual(VibeMusicalKeyCamelotColor(major), VibeMusicalKeyCamelotColor(minor));
    }
}

- (void)testEachWheelNumberHasItsOwnHue {
    NSMutableSet<NSNumber *> *hues = [NSMutableSet set];
    for (VibeMusicalKey key = 0; key < 12; key++) {
        NSColor *color = [self color:VibeMusicalKeyCamelotColor(key) in:NSAppearanceNameAqua];
        [hues addObject:@(lround(color.hueComponent * 360))];
    }
    XCTAssertEqual(hues.count, 12u);
}

// Less saturated on dark chrome, darker on light, and never full brightness.
- (void)testTheColorFollowsTheAppearance {
    for (VibeMusicalKey key = 0; key < 24; key++) {
        NSColor *color = VibeMusicalKeyCamelotColor(key);
        NSColor *light = [self color:color in:NSAppearanceNameAqua];
        NSColor *dark = [self color:color in:NSAppearanceNameDarkAqua];
        XCTAssertEqualWithAccuracy(light.saturationComponent, 0.90, 0.01);
        XCTAssertEqualWithAccuracy(light.brightnessComponent, 0.60, 0.01);
        XCTAssertEqualWithAccuracy(dark.saturationComponent, 0.62, 0.01);
        XCTAssertEqualWithAccuracy(dark.brightnessComponent, 0.82, 0.01);
        XCTAssertEqualWithAccuracy(light.hueComponent, dark.hueComponent, 0.01);
    }
}

@end
