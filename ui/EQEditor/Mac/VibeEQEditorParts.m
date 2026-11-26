//
//  VibeEQEditorParts.m
//  vibe-libs
//

#import "VibeEQEditorParts.h"

#import "VibeEQEditorMath.h"

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

VibeEQBand *VibeEQBandChanged(VibeEQBand *band, VibeEQBandType type, double frequency, double gainDB, double q) {
    return [[VibeEQBand alloc] initWithType:type frequency:frequency gainDB:gainDB q:q enabled:band.enabled];
}

NSString *VibeEQBandName(VibeEQEditorStrings *strings, NSUInteger index) {
    return [NSString stringWithFormat:strings.bandFormat, (long)index + 1];
}

NSRect VibeEQPlotRect(NSRect bounds, NSEdgeInsets insets) {
    return NSMakeRect(insets.left, insets.bottom, MAX(0, NSWidth(bounds) - insets.left - insets.right),
                      MAX(0, NSHeight(bounds) - insets.top - insets.bottom));
}

NSFont *VibeEQLabelFont(void) {
    return [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
}

NSColor *VibeEQGridColor(CGFloat alpha) {
    return [NSColor.labelColor colorWithAlphaComponent:alpha];
}

void VibeEQDrawGainGrid(NSRect plot, double rangeDB, int labelStep) {
    NSDictionary *attributes = @{
        NSFontAttributeName: VibeEQLabelFont(),
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
    };
    for (int db = -(int)rangeDB; db <= (int)rangeDB; db += 6) {
        CGFloat y = round(VibeEQYForGain(db, NSMinY(plot), NSHeight(plot), rangeDB)) + 0.5;
        [VibeEQGridColor(db == 0 ? 0.3 : kVibeEQMajorGridAlpha) setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(plot), y - 0.5, NSWidth(plot), 1), NSCompositingOperationSourceOver);
        if (db % labelStep == 0) {
            NSString *label = db > 0 ? [NSString stringWithFormat:@"+%d", db] : [NSString stringWithFormat:@"%d", db];
            NSSize size = [label sizeWithAttributes:attributes];
            [label drawAtPoint:NSMakePoint(NSMinX(plot) - 8 - size.width, y - size.height / 2) withAttributes:attributes];
        }
    }
}
