//
//  VibeEQCurveView.m
//  vibe-libs
//
//  The parametric graph. The curve is sampled only when it draws, so a view
//  that isn't shown computes nothing.
//

#import "VibeEQEditorParts.h"

#import "VibeEQEditorFormat.h"
#import "VibeEQEditorMath.h"

static const NSEdgeInsets kPlotInsets = {10, 38, 20, 12};  // top, left, bottom, right
static const CGFloat kNodeRadius = 8;
static const CGFloat kHitRadius = 12;

typedef NS_ENUM(NSInteger, VibeEQDragMode) {
    VibeEQDragModeNone,
    VibeEQDragModeMove,
    VibeEQDragModeQ,
};

@implementation VibeEQCurveView {
    // The curve, in dB, one per sample, and the range it needs. Empty until
    // asked for.
    NSMutableData *_samples;
    double _neededRange;
    BOOL _curveValid;
    // A drag holds the axis, so the node stays under the pointer. It only
    // widens.
    double _heldRange;
    VibeEQDragMode _dragMode;
    NSPoint _dragAnchor;
    VibeEQBand *_dragAnchorBand;
    NSPoint _grabOffset;
    BOOL _changedInGesture;
    NSArray<VibeEQAccessibilitySlider *> *_elements;
    NSBezierPath *_selectedPath;
    double _selectedPathRange;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bands = @[];
        _selectedIndex = NSNotFound;
        _enabled = YES;
        _locale = NSLocale.currentLocale;
        _strings = [[VibeEQEditorStrings alloc] init];
        _samples = [NSMutableData data];
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityGroupRole];
    }
    return self;
}

- (BOOL)isOpaque {
    return NO;
}

#pragma mark - Values

- (void)setBands:(NSArray<VibeEQBand *> *)bands {
    NSUInteger oldCount = _bands.count;
    _bands = [bands copy];
    if (_selectedIndex != NSNotFound && _selectedIndex >= _bands.count) {
        _selectedIndex = NSNotFound;
    }
    if (_bands.count != oldCount) {
        _elements = nil;
        NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
    }
    [self invalidateCurve];
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    _selectedIndex = selectedIndex < _bands.count ? selectedIndex : NSNotFound;
    _selectedPath = nil;
    self.needsDisplay = YES;
    [self noteFocusRingMaskChanged];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) {
        _dragMode = VibeEQDragModeNone;
    }
    self.needsDisplay = YES;
}

- (void)setLocale:(NSLocale *)locale {
    _locale = [locale copy];
    self.needsDisplay = YES;
}

- (void)setStrings:(VibeEQEditorStrings *)strings {
    _strings = [strings copy];
    self.accessibilityLabel = strings.curveAccessibilityLabel;
    _elements = nil;
}

- (void)invalidateCurve {
    _curveValid = NO;
    _selectedPath = nil;
    self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self invalidateCurve];
}

// Replaces one band and tells the owner, when it changed.
- (void)replaceBandAtIndex:(NSUInteger)index with:(VibeEQBand *)band {
    if (index >= _bands.count || [band isEqual:_bands[index]]) {
        return;
    }
    NSMutableArray<VibeEQBand *> *bands = [_bands mutableCopy];
    bands[index] = band;
    _bands = bands;
    _changedInGesture = YES;
    [self invalidateCurve];
    [self noteFocusRingMaskChanged];
    [self.owner face:self didChangeBands:_bands];
}

- (void)endEdit {
    if (_changedInGesture) {
        _changedInGesture = NO;
        [self.owner faceDidEndEditing:self];
    }
}

- (void)selectBand:(NSUInteger)index {
    if (index == _selectedIndex) {
        return;
    }
    self.selectedIndex = index;
    [self.owner face:self didSelectBandAtIndex:_selectedIndex];
}

static VibeEQBand *VibeEQBandMoved(VibeEQBand *band, double frequency, double gainDB, double q) {
    return VibeEQBandChanged(band, band.type, frequency, gainDB, q);
}

// "1,000 Hz, +3.0 dB, Q 1.4". A pass filter has no gain: "30 Hz, Q 0.71".
static NSString *VibeEQNodeAccessibilityValue(VibeEQBand *band, NSLocale *locale) {
    NSString *frequency = VibeEQFormatFrequency(band.frequency, locale);
    NSString *q = [@"Q " stringByAppendingString:VibeEQFormatQ(band.q, locale)];
    if (!VibeEQBandHasGain(band.type)) {
        return [NSString stringWithFormat:@"%@, %@", frequency, q];
    }
    return [NSString stringWithFormat:@"%@, %@, %@", frequency, VibeEQFormatGain(band.gainDB, locale), q];
}

#pragma mark - Geometry

- (NSRect)plotRect {
    return VibeEQPlotRect(self.bounds, kPlotInsets);
}

// Samples the curve, once for each change, and finds the range it needs.
- (void)ensureCurve {
    if (_curveValid) {
        return;
    }
    _curveValid = YES;
    NSRect plot = self.plotRect;
    // A sample for each point across.
    NSUInteger count = NSWidth(plot) > 0 ? (NSUInteger)ceil(NSWidth(plot)) + 1 : 0;
    _samples.length = count * sizeof(double);
    double *samples = _samples.mutableBytes;
    double largest = 0;
    BOOL any = NO;
    for (VibeEQBand *band in _bands) {
        any = any || band.enabled;
        if (band.enabled && VibeEQBandHasGain(band.type)) {
            largest = MAX(largest, fabs(band.gainDB));
        }
    }
    for (NSUInteger i = 0; i < count; i++) {
        double frequency = VibeEQFrequencyForX(NSMinX(plot) + MIN((CGFloat)i, NSWidth(plot)), NSMinX(plot),
                                               NSWidth(plot));
        samples[i] = any ? VibeListeningResponseDB(_bands, frequency, kVibeEQCurveSampleRate) : 0;
        if (isfinite(samples[i])) {
            largest = MAX(largest, fabs(samples[i]));
        }
    }
    _neededRange = VibeEQRangeForPeak(largest);
}

- (double)rangeDB {
    [self ensureCurve];
    return _dragMode != VibeEQDragModeNone ? MAX(_heldRange, _neededRange) : _neededRange;
}

- (NSPoint)nodeCenterForBandAtIndex:(NSUInteger)index {
    if (index >= _bands.count) {
        return NSZeroPoint;
    }
    VibeEQBand *band = _bands[index];
    NSRect plot = self.plotRect;
    double gain = VibeEQBandHasGain(band.type) ? band.gainDB : 0;
    return NSMakePoint(VibeEQXForFrequency(band.frequency, NSMinX(plot), NSWidth(plot)),
                       VibeEQYForGain(gain, NSMinY(plot), NSHeight(plot), self.rangeDB));
}

- (NSUInteger)nodeIndexAtPoint:(NSPoint)point {
    NSUInteger count = MIN(_bands.count, kVibeListeningMaxBands);
    CGPoint nodes[kVibeListeningMaxBands];
    for (NSUInteger i = 0; i < count; i++) {
        nodes[i] = [self nodeCenterForBandAtIndex:i];
    }
    // The selected node is drawn on top, so it wins a tie.
    NSUInteger index = VibeEQNodeIndexAtPoint(nodes, count, point, kHitRadius);
    if (_selectedIndex != NSNotFound && index != NSNotFound && index != _selectedIndex) {
        CGFloat dx = nodes[_selectedIndex].x - point.x, dy = nodes[_selectedIndex].y - point.y;
        CGFloat ix = nodes[index].x - point.x, iy = nodes[index].y - point.y;
        if (dx * dx + dy * dy <= ix * ix + iy * iy) {
            return _selectedIndex;
        }
    }
    return index;
}

- (NSRect)nodeRectForBandAtIndex:(NSUInteger)index {
    NSPoint center = [self nodeCenterForBandAtIndex:index];
    return NSMakeRect(center.x - kNodeRadius, center.y - kNodeRadius, kNodeRadius * 2, kNodeRadius * 2);
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSRect plot = self.plotRect;
    if (NSIsEmptyRect(plot)) {
        return;
    }
    double range = self.rangeDB;
    NSDictionary *labelAttributes = @{
        NSFontAttributeName: VibeEQLabelFont(),
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
    };

    [[NSColor.labelColor colorWithAlphaComponent:0.04] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:plot xRadius:4 yRadius:4] fill];

    // The frequency grid: a line at each 1 to 9 of a decade, labeled at 2, 5,
    // and 10.
    for (double decade = 10; decade <= 10000; decade *= 10) {
        for (int step = 1; step <= 10; step++) {
            double frequency = decade * step;
            if (frequency < kVibeEQMinFrequency || frequency > kVibeEQMaxFrequency || (step == 10 && decade < 10000)) {
                continue;
            }
            CGFloat x = round(VibeEQXForFrequency(frequency, NSMinX(plot), NSWidth(plot))) + 0.5;
            BOOL labeled = step == 1 || step == 2 || step == 5 || step == 10;
            [VibeEQGridColor(labeled ? kVibeEQMajorGridAlpha : kVibeEQMinorGridAlpha) setFill];
            NSRectFillUsingOperation(NSMakeRect(x - 0.5, NSMinY(plot), 1, NSHeight(plot)),
                                     NSCompositingOperationSourceOver);
            if (labeled) {
                NSString *label = VibeEQFormatShortFrequency(frequency, self.locale);
                NSSize size = [label sizeWithAttributes:labelAttributes];
                CGFloat lx = VibeEQClamp(x - size.width / 2, NSMinX(plot), NSMaxX(plot) - size.width);
                [label drawAtPoint:NSMakePoint(lx, NSMinY(plot) - 4 - size.height) withAttributes:labelAttributes];
            }
        }
    }

    VibeEQDrawGainGrid(plot, range, range > kVibeEQNarrowRangeDB ? 12 : 6);

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(plot);
    NSColor *accent = NSColor.controlAccentColor;

    // The selected band alone, faintly, so its share of the curve shows. Kept
    // until the bands, the selection, or the axis change.
    if (_selectedIndex != NSNotFound && _bands[_selectedIndex].enabled) {
        if (!_selectedPath || _selectedPathRange != range) {
            _selectedPath = [self curvePathForBand:_bands[_selectedIndex] range:range];
            _selectedPathRange = range;
        }
        NSBezierPath *own = _selectedPath;
        [[accent colorWithAlphaComponent:0.5] setStroke];
        own.lineWidth = 1;
        CGFloat dash[] = {3, 3};
        [own setLineDash:dash count:2 phase:0];
        [own stroke];
    }

    NSBezierPath *curve = [self curvePathFromSamples:range];
    CGFloat zeroY = VibeEQYForGain(0, NSMinY(plot), NSHeight(plot), range);
    NSBezierPath *fill = [curve copy];
    [fill lineToPoint:NSMakePoint(NSMaxX(plot), zeroY)];
    [fill lineToPoint:NSMakePoint(NSMinX(plot), zeroY)];
    [fill closePath];
    [[accent colorWithAlphaComponent:0.15] setFill];
    [fill fill];
    [accent setStroke];
    curve.lineWidth = 2;
    curve.lineJoinStyle = NSLineJoinStyleRound;
    [curve stroke];
    [NSGraphicsContext restoreGraphicsState];

    for (NSUInteger i = 0; i < _bands.count; i++) {
        if (i != _selectedIndex) {
            [self drawNodeAtIndex:i accent:accent];
        }
    }
    if (_selectedIndex != NSNotFound) {
        [self drawNodeAtIndex:_selectedIndex accent:accent];
    }
}

- (NSBezierPath *)curvePathFromSamples:(double)range {
    NSRect plot = self.plotRect;
    const double *samples = _samples.bytes;
    NSUInteger count = _samples.length / sizeof(double);
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (NSUInteger i = 0; i < count; i++) {
        double db = isfinite(samples[i]) ? samples[i] : -range * 2;
        NSPoint point = NSMakePoint(NSMinX(plot) + MIN((CGFloat)i, NSWidth(plot)),
                                    NSMinY(plot) + NSHeight(plot) * (CGFloat)((db + range) / (2 * range)));
        i == 0 ? [path moveToPoint:point] : [path lineToPoint:point];
    }
    return path;
}

// One band's own curve, sampled every other point: drawn only while selected.
- (NSBezierPath *)curvePathForBand:(VibeEQBand *)band range:(double)range {
    NSArray<VibeEQBand *> *bands = @[band];
    NSRect plot = self.plotRect;
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (CGFloat x = NSMinX(plot);; x += 2) {
        CGFloat clamped = MIN(x, NSMaxX(plot));
        double db = VibeListeningResponseDB(bands, VibeEQFrequencyForX(clamped, NSMinX(plot), NSWidth(plot)),
                                            kVibeEQCurveSampleRate);
        if (!isfinite(db)) {
            db = -range * 2;
        }
        NSPoint point = NSMakePoint(clamped, NSMinY(plot) + NSHeight(plot) * (CGFloat)((db + range) / (2 * range)));
        x == NSMinX(plot) ? [path moveToPoint:point] : [path lineToPoint:point];
        if (clamped >= NSMaxX(plot)) {
            break;
        }
    }
    return path;
}

- (void)drawNodeAtIndex:(NSUInteger)index accent:(NSColor *)accent {
    VibeEQBand *band = _bands[index];
    NSRect rect = [self nodeRectForBandAtIndex:index];
    BOOL selected = index == _selectedIndex;
    if (selected) {
        [[accent colorWithAlphaComponent:0.3] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, -4, -4)] fill];
    }
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:rect];
    NSColor *fill = band.enabled ? accent : NSColor.controlBackgroundColor;
    [fill setFill];
    [circle fill];
    [(band.enabled ? NSColor.controlBackgroundColor : NSColor.secondaryLabelColor) setStroke];
    circle.lineWidth = 1.5;
    [circle stroke];

    NSString *number = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: band.enabled ? NSColor.whiteColor : NSColor.secondaryLabelColor,
    };
    NSSize size = [number sizeWithAttributes:attributes];
    [number drawAtPoint:NSMakePoint(NSMidX(rect) - size.width / 2, NSMidY(rect) - size.height / 2)
         withAttributes:attributes];
}

- (NSRect)focusRingMaskBounds {
    if (_selectedIndex == NSNotFound) {
        return self.plotRect;
    }
    return NSInsetRect([self nodeRectForBandAtIndex:_selectedIndex], -1, -1);
}

- (void)drawFocusRingMask {
    if (_selectedIndex == NSNotFound) {
        NSRectFill(self.plotRect);
    } else {
        [[NSBezierPath bezierPathWithOvalInRect:[self nodeRectForBandAtIndex:_selectedIndex]] fill];
    }
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
    [self.window makeFirstResponder:self];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger index = [self nodeIndexAtPoint:point];
    [self selectBand:index];
    if (index == NSNotFound) {
        return;
    }
    _heldRange = self.rangeDB;
    [self anchorDragAt:point option:(event.modifierFlags & NSEventModifierFlagOption) != 0];
}

// A drag's changes are measured from its anchor, which moves when Option is
// pressed or let go, so switching mid-drag never jumps.
- (void)anchorDragAt:(NSPoint)point option:(BOOL)option {
    _dragMode = option ? VibeEQDragModeQ : VibeEQDragModeMove;
    _dragAnchor = point;
    _dragAnchorBand = _bands[_selectedIndex];
    NSPoint center = [self nodeCenterForBandAtIndex:_selectedIndex];
    _grabOffset = NSMakePoint(center.x - point.x, center.y - point.y);
}

- (void)mouseDragged:(NSEvent *)event {
    if (_dragMode == VibeEQDragModeNone || _selectedIndex == NSNotFound) {
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL option = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    if (option != (_dragMode == VibeEQDragModeQ)) {
        [self anchorDragAt:point option:option];
    }
    VibeEQBand *band = _dragAnchorBand;
    if (_dragMode == VibeEQDragModeQ) {
        double q = VibeEQRoundQ(VibeEQQForVerticalDrag(band.q, point.y - _dragAnchor.y));
        [self replaceBandAtIndex:_selectedIndex with:VibeEQBandMoved(band, band.frequency, band.gainDB, q)];
        return;
    }
    NSRect plot = self.plotRect;
    double frequency = VibeEQRoundFrequency(VibeEQFrequencyForX(point.x + _grabOffset.x, NSMinX(plot), NSWidth(plot)));
    double gain = band.gainDB;
    if (VibeEQBandHasGain(band.type)) {
        double range = self.rangeDB;
        gain = VibeEQSnapGain(VibeEQGainForY(point.y + _grabOffset.y, NSMinY(plot), NSHeight(plot), range),
                              kVibeEQParametricStepDB, kVibeEQMaxGainDB);
    }
    [self replaceBandAtIndex:_selectedIndex with:VibeEQBandMoved(band, frequency, gain, band.q)];
    // A widened axis moves every node, so the grab is measured again.
    if (self.rangeDB > _heldRange) {
        _heldRange = self.rangeDB;
        [self anchorDragAt:point option:NO];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (_dragMode == VibeEQDragModeNone) {
        return;
    }
    _dragMode = VibeEQDragModeNone;
    self.needsDisplay = YES;
    [self endEdit];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger index = [self nodeIndexAtPoint:point];
    if (index == NSNotFound) {
        index = _selectedIndex;
    }
    if (!self.enabled || index == NSNotFound) {
        [super scrollWheel:event];
        return;
    }
    // Momentum after a trackpad's lift would edit after the edit ended.
    if (event.momentumPhase != NSEventPhaseNone) {
        return;
    }
    [self selectBand:index];
    CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10;
    VibeEQBand *band = _bands[index];
    double q = VibeEQRoundQ(VibeEQQForScroll(band.q, delta));
    [self replaceBandAtIndex:index with:VibeEQBandMoved(band, band.frequency, band.gainDB, q)];
    if (event.phase == NSEventPhaseNone || (event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled))) {
        [self endEdit];
    }
}

#pragma mark - Keys

- (BOOL)acceptsFirstResponder {
    return self.enabled;
}

- (BOOL)becomeFirstResponder {
    if (_selectedIndex == NSNotFound && _bands.count > 0) {
        [self selectBand:0];
    }
    self.needsDisplay = YES;
    return YES;
}

- (BOOL)resignFirstResponder {
    self.needsDisplay = YES;
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (!self.enabled || ![self handleKey:event]) {
        [super keyDown:event];
    }
}

// The arrows move the selected node: left and right a twelfth of an octave
// (a third with Shift), up and down 0.5 dB (0.1 with Shift), Option with up
// and down changes Q. Tab moves between the nodes, then out of the graph.
- (BOOL)handleKey:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length != 1) {
        return NO;
    }
    unichar key = [characters characterAtIndex:0];
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    if (key == NSTabCharacter || key == NSBackTabCharacter) {
        BOOL back = key == NSBackTabCharacter || shift;
        NSUInteger count = _bands.count;
        if (!back && _selectedIndex != NSNotFound && _selectedIndex + 1 < count) {
            [self selectBand:_selectedIndex + 1];
        } else if (back && _selectedIndex != NSNotFound && _selectedIndex > 0) {
            [self selectBand:_selectedIndex - 1];
        } else if (back) {
            [self.window selectPreviousKeyView:self];
        } else {
            [self.window selectNextKeyView:self];
        }
        return YES;
    }
    if (_selectedIndex == NSNotFound) {
        return NO;
    }
    VibeEQBand *band = _bands[_selectedIndex];
    switch (key) {
        case NSLeftArrowFunctionKey:
        case NSRightArrowFunctionKey: {
            double octaves = (shift ? 1.0 / 3 : 1.0 / 12) * (key == NSLeftArrowFunctionKey ? -1 : 1);
            double frequency = VibeEQRoundFrequency(VibeEQFrequencyByOctaves(band.frequency, octaves));
            [self stepBand:VibeEQBandMoved(band, frequency, band.gainDB, band.q)];
            return YES;
        }
        case NSUpArrowFunctionKey:
        case NSDownArrowFunctionKey: {
            BOOL up = key == NSUpArrowFunctionKey;
            if (option) {
                double q = VibeEQRoundQ(band.q * (up ? 1.1 : 1 / 1.1));
                if (q == band.q) {
                    q = VibeEQClamp(band.q + (up ? 0.01 : -0.01), kVibeEQMinQ, kVibeEQMaxQ);
                }
                [self stepBand:VibeEQBandMoved(band, band.frequency, band.gainDB, q)];
            } else if (VibeEQBandHasGain(band.type)) {
                double step = shift ? kVibeEQParametricStepDB : kVibeEQGraphicStepDB;
                double gain = VibeEQSnapGain(band.gainDB + (up ? step : -step), kVibeEQParametricStepDB, kVibeEQMaxGainDB);
                [self stepBand:VibeEQBandMoved(band, band.frequency, gain, band.q)];
            }
            return YES;
        }
        case NSDeleteCharacter:
        case NSDeleteFunctionKey: {
            NSMutableArray<VibeEQBand *> *bands = [_bands mutableCopy];
            [bands removeObjectAtIndex:_selectedIndex];
            NSUInteger next = VibeEQSelectionAfterRemoving(_selectedIndex, bands.count);
            self.bands = bands;
            [self.owner face:self didChangeBands:_bands];
            _selectedIndex = NSNotFound;
            [self selectBand:next];
            [self.owner faceDidEndEditing:self];
            return YES;
        }
        default:
            return NO;
    }
}

- (void)stepBand:(VibeEQBand *)band {
    [self replaceBandAtIndex:_selectedIndex with:band];
    [self endEdit];
}

#pragma mark - Accessibility

- (NSArray<VibeEQAccessibilitySlider *> *)nodeElements {
    if (!_elements) {
        NSMutableArray<VibeEQAccessibilitySlider *> *elements = [NSMutableArray array];
        __weak VibeEQCurveView *weakSelf = self;
        for (NSUInteger i = 0; i < _bands.count; i++) {
            VibeEQAccessibilitySlider *element = [[VibeEQAccessibilitySlider alloc] init];
            element.accessibilityParent = self;
            element.accessibilityLabel = VibeEQBandName(self.strings, i);
            element.valueBlock = ^NSString * {
                VibeEQCurveView *view = weakSelf;
                return view && i < view.bands.count ? VibeEQNodeAccessibilityValue(view.bands[i], view.locale) : @"";
            };
            element.frameBlock = ^NSRect {
                return NSInsetRect([weakSelf nodeRectForBandAtIndex:i], -4, -4);
            };
            element.stepBlock = ^(BOOL up) {
                [weakSelf accessibilityStepBandAtIndex:i up:up];
            };
            element.focusBlock = ^{
                [weakSelf selectBand:i];
            };
            [elements addObject:element];
        }
        _elements = elements;
    }
    return _elements;
}

// A VoiceOver step moves a gain by 0.5 dB, and a pass filter's frequency by
// a twelfth of an octave.
- (void)accessibilityStepBandAtIndex:(NSUInteger)index up:(BOOL)up {
    if (index >= _bands.count) {
        return;
    }
    [self selectBand:index];
    VibeEQBand *band = _bands[index];
    if (VibeEQBandHasGain(band.type)) {
        double gain = VibeEQSnapGain(band.gainDB + (up ? kVibeEQGraphicStepDB : -kVibeEQGraphicStepDB),
                                     kVibeEQParametricStepDB, kVibeEQMaxGainDB);
        [self stepBand:VibeEQBandMoved(band, band.frequency, gain, band.q)];
    } else {
        double frequency = VibeEQRoundFrequency(VibeEQFrequencyByOctaves(band.frequency, up ? 1.0 / 12 : -1.0 / 12));
        [self stepBand:VibeEQBandMoved(band, frequency, band.gainDB, band.q)];
    }
}

- (NSArray *)accessibilityChildren {
    return self.nodeElements;
}

- (BOOL)isAccessibilityEnabled {
    return self.enabled;
}

@end
