//
//  VibeEQFaceTabs.m
//  vibe-libs
//
//  TRAP: drawn, since NSSegmentedControl is hosted in SwiftUI on macOS 26 and
//  pays its Metal startup (ui/Controls/AGENTS.md).
//

#import "VibeEQEditorParts.h"

#import "NSView+DarkMode.h"

static const CGFloat kCornerRadius = 6;
static const CGFloat kInset = 2;

// One tab as VoiceOver reads it: a radio button.
@interface VibeEQFaceTab : NSAccessibilityElement
@property (nonatomic, weak) VibeEQFaceTabs *tabs;
@property (nonatomic) NSInteger segment;
@end

@implementation VibeEQFaceTabs {
    NSMutableArray<NSNumber *> *_disabled;
    NSMutableDictionary<NSNumber *, NSString *> *_toolTips;
    NSArray<VibeEQFaceTab *> *_elements;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _labels = @[];
        _disabled = [NSMutableArray array];
        _toolTips = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setLabels:(NSArray<NSString *> *)labels {
    _labels = [labels copy];
    _elements = nil;
    self.needsDisplay = YES;
}

- (void)setSelectedSegment:(NSInteger)selectedSegment {
    _selectedSegment = selectedSegment;
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment {
    [_disabled removeObject:@(segment)];
    if (!enabled) {
        [_disabled addObject:@(segment)];
    }
    self.needsDisplay = YES;
}

- (BOOL)isEnabledForSegment:(NSInteger)segment {
    return ![_disabled containsObject:@(segment)];
}

- (void)setToolTip:(nullable NSString *)toolTip forSegment:(NSInteger)segment {
    _toolTips[@(segment)] = toolTip;
    [self updateToolTipRects];
}

- (nullable NSString *)toolTipForSegment:(NSInteger)segment {
    return _toolTips[@(segment)];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}

- (NSRect)rectOfSegment:(NSInteger)segment {
    NSRect bounds = NSInsetRect(self.bounds, kInset, kInset);
    CGFloat width = NSWidth(bounds) / (CGFloat)MAX(_labels.count, 1u);
    return NSMakeRect(NSMinX(bounds) + width * (CGFloat)segment, NSMinY(bounds), width, NSHeight(bounds));
}

- (NSInteger)segmentAtPoint:(NSPoint)point {
    for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
        if (NSPointInRect(point, [self rectOfSegment:i])) {
            return i;
        }
    }
    return -1;
}

- (void)updateToolTipRects {
    [self removeAllToolTips];
    for (NSNumber *segment in _toolTips) {
        [self addToolTipRect:[self rectOfSegment:segment.integerValue] owner:_toolTips[segment] userData:NULL];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateToolTipRects];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    BOOL dark = self.isDark;
    [[NSColor.labelColor colorWithAlphaComponent:dark ? 0.1 : 0.06] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:kCornerRadius yRadius:kCornerRadius] fill];
    for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
        NSRect rect = [self rectOfSegment:i];
        BOOL selected = i == _selectedSegment;
        BOOL enabled = self.isEnabled && [self isEnabledForSegment:i];
        if (selected) {
            [NSGraphicsContext saveGraphicsState];
            if (!dark) {
                NSShadow *shadow = [[NSShadow alloc] init];
                shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.18];
                shadow.shadowOffset = NSMakeSize(0, -0.5);
                shadow.shadowBlurRadius = 1;
                [shadow set];
            }
            [[NSColor colorWithWhite:1 alpha:dark ? 0.2 : 1] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:kCornerRadius - kInset yRadius:kCornerRadius - kInset] fill];
            [NSGraphicsContext restoreGraphicsState];
        }
        NSDictionary *attributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize
                                                   weight:selected ? NSFontWeightMedium : NSFontWeightRegular],
            NSForegroundColorAttributeName: !enabled ? NSColor.tertiaryLabelColor
                                          : selected ? NSColor.labelColor
                                                     : NSColor.secondaryLabelColor,
        };
        NSString *label = _labels[(NSUInteger)i];
        NSSize size = [label sizeWithAttributes:attributes];
        [label drawAtPoint:NSMakePoint(round(NSMidX(rect) - size.width / 2), round(NSMidY(rect) - size.height / 2))
            withAttributes:attributes];
    }
}

- (BOOL)isFlipped {
    return YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (NSRect)focusRingMaskBounds {
    return self.bounds;
}

- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:kCornerRadius yRadius:kCornerRadius] fill];
}

#pragma mark - Input

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (void)mouseDown:(NSEvent *)event {
    [self chooseSegment:[self segmentAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]];
}

// Selects an enabled tab other than the current one, and sends the action.
- (BOOL)chooseSegment:(NSInteger)segment {
    if (!self.isEnabled || segment < 0 || segment >= (NSInteger)_labels.count || segment == _selectedSegment ||
        ![self isEnabledForSegment:segment]) {
        return NO;
    }
    self.selectedSegment = segment;
    [self sendAction:self.action to:self.target];
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return self.isEnabled && NSApp.isFullKeyboardAccessEnabled;
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    unichar key = characters.length == 1 ? [characters characterAtIndex:0] : 0;
    if (key == NSLeftArrowFunctionKey) {
        [self chooseSegment:_selectedSegment - 1];
    } else if (key == NSRightArrowFunctionKey) {
        [self chooseSegment:_selectedSegment + 1];
    } else {
        [super keyDown:event];
    }
}

#pragma mark - Accessibility

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityTabGroupRole;
}

- (NSArray *)accessibilityChildren {
    if (!_elements) {
        NSMutableArray<VibeEQFaceTab *> *elements = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
            VibeEQFaceTab *tab = [[VibeEQFaceTab alloc] init];
            tab.tabs = self;
            tab.segment = i;
            tab.accessibilityParent = self;
            [elements addObject:tab];
        }
        _elements = elements;
    }
    return _elements;
}

- (NSArray *)accessibilityTabs {
    return self.accessibilityChildren;
}

@end

@implementation VibeEQFaceTab

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityRadioButtonRole;
}

- (NSString *)accessibilityLabel {
    NSArray<NSString *> *labels = self.tabs.labels;
    return self.segment < (NSInteger)labels.count ? labels[(NSUInteger)self.segment] : nil;
}

- (id)accessibilityValue {
    return @(self.tabs.selectedSegment == self.segment);
}

- (NSString *)accessibilityHelp {
    return [self.tabs toolTipForSegment:self.segment];
}

- (BOOL)isAccessibilityEnabled {
    return self.tabs.isEnabled && [self.tabs isEnabledForSegment:self.segment];
}

- (NSRect)accessibilityFrame {
    VibeEQFaceTabs *tabs = self.tabs;
    return tabs ? NSAccessibilityFrameInView(tabs, [tabs rectOfSegment:self.segment]) : NSZeroRect;
}

- (BOOL)accessibilityPerformPress {
    return [self.tabs chooseSegment:self.segment];
}

@end
