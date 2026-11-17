//
//  MusicalKeyColor.m
//  vibe-libs
//

#import "MusicalKeyColor.h"
#import <math.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
typedef NSColor KeyColor;
#else
#import <UIKit/UIKit.h>
typedef UIColor KeyColor;
#endif

static const double kCamelotHueOfNumberOne = 1.0 / 3.0;

double VibeCamelotHue(NSInteger number) {
    return fmod(kCamelotHueOfNumberOne + (double)(number - 1) / 12.0, 1.0);
}

static KeyColor *CamelotColor(CGFloat hue, BOOL dark) {
    return [KeyColor colorWithHue:hue saturation:dark ? 0.62 : 0.90 brightness:dark ? 0.82 : 0.60 alpha:1.0];
}

KeyColor *_Nullable VibeMusicalKeyCamelotColor(VibeMusicalKey key) {
    NSInteger number = VibeMusicalKeyCamelotNumber(key);
    if (number < 1 || number > 12) {
        return nil;
    }
    static KeyColor *palette[13];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSInteger i = 1; i <= 12; i++) {
            CGFloat hue = (CGFloat)VibeCamelotHue(i);
#if TARGET_OS_OSX
            palette[i] = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
                NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:
                        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
                return CamelotColor(hue, [match isEqualToString:NSAppearanceNameDarkAqua]);
            }];
#else
            palette[i] = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return CamelotColor(hue, traits.userInterfaceStyle == UIUserInterfaceStyleDark);
            }];
#endif
        }
    });
    return palette[number];
}
