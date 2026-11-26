//
//  VibeEQGraphicView.m
//  vibe-libs
//
//  Ten sliders drawn in one view, so the face is one layer and one pass.
//  Each is a VoiceOver slider of its own.
//

#import "VibeEQEditorParts.h"

#import "NSView+DarkMode.h"
#import "VibeEQEditorFormat.h"
#import "VibeEQEditorMath.h"

enum { kSliderCount = 10 };
static const CGFloat kKnobWidth = 26;
static const CGFloat kKnobHeight = 12;
static const CGFloat kTrackWidth = 4;
static const NSEdgeInsets kPlotInsets = {24, 38, 22, 10};  // top, left, bottom, right

@implementation VibeEQGraphicView {
    double _gains[kSliderCount];
    NSArray<VibeEQAccessibilitySlider *> *_elements;
    CGFloat _grabOffset;
    BOOL _changedInGesture;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bands = @[];
        _enabled = YES;
        _locale = NSLocale.currentLocale;
        _strings = [[VibeEQEditorStrings alloc] init];
        _draggedSlider = NSNotFound;
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityGroupRole];
    }
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (BOOL)isOpaque {
    return NO;
}

#pragma mark - Values

- (void)setBands:(NSArray<VibeEQBand *> *)bands {
    _bands = [bands copy];
    BOOL graphic = bands.count == kSliderCount;
    for (NSUInteger i = 0; i < kSliderCount; i++) {
        _gains[i] = graphic ? bands[i].gainDB : 0;
    }
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) {
        _draggedSlider = NSNotFound;
    }
    self.needsDisplay = YES;
}

- (void)setFocusedSlider:(NSUInteger)focusedSlider {
    _focusedSlider = MIN(focusedSlider, kSliderCount - 1);
    self.needsDisplay = YES;
    [self noteFocusRingMaskChanged];
}

- (double)gainAtSlider:(NSUInteger)index {
    return index < kSliderCount ? _gains[index] : 0;
}

// Sets one gain and tells the owner, when it moved.
- (void)setGain:(double)gain atSlider:(NSUInteger)index {
    double snapped = VibeEQSnapGain(gain, kVibeEQGraphicStepDB, kVibeEQNarrowRangeDB);
    if (index >= kSliderCount || snapped == _gains[index]) {
        return;
    }
    _gains[index] = snapped;
    _changedInGesture = YES;
    NSMutableArray<NSNumber *> *gains = [NSMutableArray arrayWithCapacity:kSliderCount];
    for (NSUInteger i = 0; i < kSliderCount; i++) {
        [gains addObject:@(_gains[i])];
    }
    _bands = [VibeListeningSettings graphicBandsWithGains:gains];
    self.needsDisplay = YES;
    [self noteFocusRingMaskChanged];
    [self.owner face:self didChangeBands:_bands];
}

- (void)endEdit {
    if (_changedInGesture) {
        _changedInGesture = NO;
        [self.owner faceDidEndEditing:self];
    }
}

#pragma mark - Geometry

- (NSRect)plotRect {
    return VibeEQPlotRect(self.bounds, kPlotInsets);
}

- (NSPoint)knobCenterForSlider:(NSUInteger)index {
    NSRect plot = self.plotRect;
    return NSMakePoint(VibeEQColumnCenterX(index, NSMinX(plot), NSWidth(plot), kSliderCount),
                       VibeEQYForGain(_gains[MIN(index, kSliderCount - 1)], NSMinY(plot), NSHeight(plot),
                                      kVibeEQNarrowRangeDB));
}

- (NSRect)knobRectForSlider:(NSUInteger)index {
    NSPoint center = [self knobCenterForSlider:index];
    return NSMakeRect(center.x - kKnobWidth / 2, center.y - kKnobHeight / 2, kKnobWidth, kKnobHeight);
}

// The slider's whole column, the VoiceOver frame.
- (NSRect)columnRectForSlider:(NSUInteger)index {
    NSRect plot = self.plotRect;
    CGFloat width = NSWidth(plot) / kSliderCount;
    return NSMakeRect(NSMinX(plot) + width * (CGFloat)index, NSMinY(plot) - kKnobHeight / 2, width,
                      NSHeight(plot) + kKnobHeight);
}

- (double)gainForY:(CGFloat)y {
    NSRect plot = self.plotRect;
    return VibeEQGainForY(y, NSMinY(plot), NSHeight(plot), kVibeEQNarrowRangeDB);
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSRect plot = self.plotRect;
    if (NSIsEmptyRect(plot)) {
        return;
    }
    NSDictionary *labelAttributes = @{
        NSFontAttributeName: VibeEQLabelFont(),
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
    };
    VibeEQDrawGainGrid(plot, kVibeEQNarrowRangeDB, 6);

    NSColor *accent = NSColor.controlAccentColor;
    CGFloat zeroY = VibeEQYForGain(0, NSMinY(plot), NSHeight(plot), kVibeEQNarrowRangeDB);
    NSArray<NSNumber *> *frequencies = [VibeListeningSettings graphicFrequencies];
    BOOL focused = self.window.firstResponder == self && self.window.isKeyWindow;
    for (NSUInteger i = 0; i < kSliderCount; i++) {
        NSPoint knob = [self knobCenterForSlider:i];
        NSRect track = NSMakeRect(round(knob.x - kTrackWidth / 2), NSMinY(plot), kTrackWidth, NSHeight(plot));
        [NSColor.quaternaryLabelColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:kTrackWidth / 2 yRadius:kTrackWidth / 2] fill];

        if (_gains[i] != 0) {
            NSRect fill = NSMakeRect(NSMinX(track), MIN(zeroY, knob.y), kTrackWidth, fabs(knob.y - zeroY));
            [accent setFill];
            [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:kTrackWidth / 2 yRadius:kTrackWidth / 2] fill];
        }

        [self drawKnobInRect:[self knobRectForSlider:i]];

        NSString *label = VibeEQFormatShortFrequency(frequencies[i].doubleValue, self.locale);
        NSSize size = [label sizeWithAttributes:labelAttributes];
        [label drawAtPoint:NSMakePoint(round(knob.x - size.width / 2), NSMinY(plot) - kKnobHeight / 2 - 4 - size.height)
            withAttributes:labelAttributes];

        if (i == _draggedSlider || (focused && i == _focusedSlider)) {
            NSDictionary *valueAttributes = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: NSColor.labelColor,
            };
            NSString *value = VibeEQFormatGain(_gains[i], self.locale);
            NSSize valueSize = [value sizeWithAttributes:valueAttributes];
            CGFloat x = VibeEQClamp(round(knob.x - valueSize.width / 2), 0, NSWidth(self.bounds) - valueSize.width);
            [value drawAtPoint:NSMakePoint(x, knob.y + kKnobHeight / 2 + 2) withAttributes:valueAttributes];
        }
    }
}

- (void)drawKnobInRect:(NSRect)rect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:3 yRadius:3];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
    shadow.shadowOffset = NSMakeSize(0, -0.5);
    shadow.shadowBlurRadius = 1.5;
    [shadow set];
    [[NSColor colorWithWhite:self.isDark ? 0.8 : 1 alpha:1] setFill];
    [path fill];
    [NSGraphicsContext restoreGraphicsState];
    [NSColor.separatorColor setStroke];
    path.lineWidth = 0.5;
    [path stroke];
    // A grip line across the knob's middle.
    [[NSColor colorWithWhite:0.5 alpha:0.6] setFill];
    NSRectFill(NSMakeRect(NSMinX(rect) + 6, round(NSMidY(rect)) - 0.5, NSWidth(rect) - 12, 1));
}

- (NSRect)focusRingMaskBounds {
    return NSInsetRect([self knobRectForSlider:_focusedSlider], -1, -1);
}

- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:[self knobRectForSlider:_focusedSlider] xRadius:3 yRadius:3] fill];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

#pragma mark - Mouse

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) {
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect plot = self.plotRect;
    NSUInteger column = VibeEQColumnAtX(point.x, NSMinX(plot), NSWidth(plot), kSliderCount);
    if (column == NSNotFound) {
        return;
    }
    if (self.acceptsFirstResponder) {
        [self.window makeFirstResponder:self];
    }
    self.focusedSlider = column;
    if (event.clickCount == 2) {
        [self setGain:0 atSlider:column];
        [self endEdit];
        return;
    }
    NSRect knob = NSInsetRect([self knobRectForSlider:column], 0, -4);
    _grabOffset = NSPointInRect(point, knob) ? [self knobCenterForSlider:column].y - point.y : 0;
    _draggedSlider = column;
    [self setGain:[self gainForY:point.y + _grabOffset] atSlider:column];
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_draggedSlider == NSNotFound) {
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self setGain:[self gainForY:point.y + _grabOffset] atSlider:_draggedSlider];
}

- (void)mouseUp:(NSEvent *)event {
    if (_draggedSlider == NSNotFound) {
        return;
    }
    _draggedSlider = NSNotFound;
    self.needsDisplay = YES;
    [self endEdit];
}

#pragma mark - Keys

- (BOOL)acceptsFirstResponder {
    return self.enabled;
}

- (BOOL)becomeFirstResponder {
    self.needsDisplay = YES;
    return YES;
}

- (BOOL)resignFirstResponder {
    self.needsDisplay = YES;
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (!self.enabled) {
        return;
    }
    if ([event.charactersIgnoringModifiers isEqualToString:@"0"]) {
        [self setGain:0 atSlider:_focusedSlider];
        [self endEdit];
        return;
    }
    [self interpretKeyEvents:@[event]];
}

- (void)stepFocusedBy:(double)db {
    [self setGain:_gains[_focusedSlider] + db atSlider:_focusedSlider];
    [self endEdit];
}

- (void)moveUp:(id)sender {
    [self stepFocusedBy:kVibeEQGraphicStepDB];
}

- (void)moveDown:(id)sender {
    [self stepFocusedBy:-kVibeEQGraphicStepDB];
}

- (void)pageUp:(id)sender {
    [self stepFocusedBy:3];
}

- (void)pageDown:(id)sender {
    [self stepFocusedBy:-3];
}

- (void)scrollPageUp:(id)sender {
    [self pageUp:sender];
}

- (void)scrollPageDown:(id)sender {
    [self pageDown:sender];
}

- (void)moveLeft:(id)sender {
    if (_focusedSlider > 0) {
        self.focusedSlider = _focusedSlider - 1;
    }
}

- (void)moveRight:(id)sender {
    if (_focusedSlider + 1 < kSliderCount) {
        self.focusedSlider = _focusedSlider + 1;
    }
}

- (void)insertTab:(id)sender {
    [self.window selectNextKeyView:self];
}

- (void)insertBacktab:(id)sender {
    [self.window selectPreviousKeyView:self];
}

- (void)insertText:(id)string {
    NSBeep();
}

#pragma mark - Accessibility

- (NSArray<VibeEQAccessibilitySlider *> *)sliderElements {
    if (!_elements) {
        NSMutableArray<VibeEQAccessibilitySlider *> *elements = [NSMutableArray array];
        NSArray<NSNumber *> *frequencies = [VibeListeningSettings graphicFrequencies];
        __weak typeof(self) weakSelf = self;
        for (NSUInteger i = 0; i < kSliderCount; i++) {
            VibeEQAccessibilitySlider *element = [[VibeEQAccessibilitySlider alloc] init];
            element.accessibilityParent = self;
            double frequency = frequencies[i].doubleValue;
            element.valueBlock = ^NSString * {
                typeof(self) view = weakSelf;
                return view ? VibeEQFormatGain([view gainAtSlider:i], view.locale) : @"";
            };
            element.frameBlock = ^NSRect {
                return [weakSelf columnRectForSlider:i];
            };
            element.stepBlock = ^(BOOL up) {
                typeof(self) view = weakSelf;
                view.focusedSlider = i;
                [view stepFocusedBy:up ? kVibeEQGraphicStepDB : -kVibeEQGraphicStepDB];
            };
            element.focusBlock = ^{
                weakSelf.focusedSlider = i;
            };
            element.accessibilityLabel = VibeEQFormatFrequency(frequency, self.locale);
            [elements addObject:element];
        }
        _elements = elements;
    }
    return _elements;
}

- (void)setLocale:(NSLocale *)locale {
    _locale = [locale copy];
    _elements = nil;
    self.needsDisplay = YES;
}

- (void)setStrings:(VibeEQEditorStrings *)strings {
    _strings = [strings copy];
    self.accessibilityLabel = strings.slidersAccessibilityLabel;
}

- (NSArray *)accessibilityChildren {
    return self.sliderElements;
}

- (BOOL)isAccessibilityEnabled {
    return self.enabled;
}

@end
