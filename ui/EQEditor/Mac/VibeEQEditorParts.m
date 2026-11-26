//
//  VibeEQEditorParts.m
//  vibe-libs
//

#import "VibeEQEditorParts.h"

#import "VibeEQEditorFormat.h"

@implementation VibeEQAccessibilitySlider

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilitySliderRole;
}

- (id)accessibilityValue {
    return self.valueBlock ? self.valueBlock() : nil;
}

- (NSRect)accessibilityFrame {
    NSView *parent = self.accessibilityParent;
    if (![parent isKindOfClass:NSView.class] || !self.frameBlock) {
        return NSZeroRect;
    }
    return NSAccessibilityFrameInView(parent, self.frameBlock());
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (BOOL)isAccessibilityEnabled {
    NSView *parent = self.accessibilityParent;
    return ![parent respondsToSelector:@selector(isEnabled)] || [(id)parent isEnabled];
}

- (BOOL)accessibilityPerformIncrement {
    if (!self.stepBlock || !self.isAccessibilityEnabled) {
        return NO;
    }
    self.stepBlock(YES);
    return YES;
}

- (BOOL)accessibilityPerformDecrement {
    if (!self.stepBlock || !self.isAccessibilityEnabled) {
        return NO;
    }
    self.stepBlock(NO);
    return YES;
}

- (void)setAccessibilityFocused:(BOOL)focused {
    [super setAccessibilityFocused:focused];
    if (focused && self.focusBlock) {
        self.focusBlock();
    }
}

@end

BOOL VibeEQBandHasGain(VibeEQBandType type) {
    return type == VibeEQBandTypePeak || type == VibeEQBandTypeLowShelf || type == VibeEQBandTypeHighShelf;
}

NSString *VibeEQNodeAccessibilityValue(VibeEQBand *band, NSLocale *locale) {
    NSString *frequency = VibeEQFormatFrequency(band.frequency, locale);
    NSString *q = [@"Q " stringByAppendingString:VibeEQFormatQ(band.q, locale)];
    if (!VibeEQBandHasGain(band.type)) {
        return [NSString stringWithFormat:@"%@, %@", frequency, q];
    }
    return [NSString stringWithFormat:@"%@, %@, %@", frequency, VibeEQFormatGain(band.gainDB, locale), q];
}

NSFont *VibeEQLabelFont(void) {
    return [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
}

NSColor *VibeEQGridColor(CGFloat alpha) {
    return [NSColor.labelColor colorWithAlphaComponent:alpha];
}
