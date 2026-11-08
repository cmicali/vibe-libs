//
//  VibeDropWellsView.m
//  vibe-libs
//

#import <QuartzCore/QuartzCore.h>

#import "NSImage+Util.h"
#import "VibeDropWellsView.h"

static const CGFloat kWellInset = 20;        // well edge from the view edge
static const CGFloat kWellCornerRadius = 10;
static const CGFloat kWellStrokeWidth = 2;
static const CGFloat kWellDashLength = 6;    // 6 on / 6 off, round caps
static const CGFloat kWellGap = 16;          // between two wells
static const CGFloat kDropIconPointSize = 26;
static const CGFloat kDropIconLabelGap = 10;
static const CGFloat kWellLabelInset = 12;   // label text from the well border
// The swap between rest and drag-over: a fast fade, deliberately not springy.
static const CFTimeInterval kStateFadeDuration = 0.12;

@implementation VibeDropWell

+ (instancetype)wellWithIdentifier:(NSString *)identifier title:(NSString *)title symbolName:(NSString *)symbolName {
    VibeDropWell *well = [[self alloc] initPrivately];
    well->_identifier = [identifier copy];
    well->_title = [title copy];
    well->_symbolName = [symbolName copy];
    return well;
}

- (instancetype)initPrivately {
    return [super init];
}

@end

@implementation VibeDropWellsStyle

+ (instancetype)systemStyle {
    VibeDropWellsStyle *style = [[self alloc] init];
    style.strokeColor = NSColor.tertiaryLabelColor;
    style.hoverStrokeColor = NSColor.keyboardFocusIndicatorColor;
    style.hoverFillColor = [NSColor.keyboardFocusIndicatorColor colorWithAlphaComponent:0.08];
    style.contentColor = NSColor.secondaryLabelColor;
    style.hoverContentColor = NSColor.labelColor;
    style.font = [NSFont systemFontOfSize:14];
    return style;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _strokeColor = NSColor.tertiaryLabelColor;
        _hoverStrokeColor = NSColor.keyboardFocusIndicatorColor;
        _contentColor = NSColor.secondaryLabelColor;
        _hoverContentColor = NSColor.labelColor;
        _font = [NSFont systemFontOfSize:14];
    }
    return self;
}

- (id)copyWithZone:(nullable NSZone *)zone {
    VibeDropWellsStyle *copy = [[[self class] alloc] init];
    copy.strokeColor = _strokeColor;
    copy.hoverStrokeColor = _hoverStrokeColor;
    copy.hoverFillColor = _hoverFillColor;
    copy.contentColor = _contentColor;
    copy.hoverContentColor = _hoverContentColor;
    copy.font = _font;
    return copy;
}

@end

// A child canvas so the drawing composites above the blur subview. The
// parent keeps all state and drawing.
@interface VibeDropWellsCanvas : NSView
@property (nonatomic, weak) VibeDropWellsView *wellsView;
@end

@interface VibeDropWellsView ()
- (void)drawCanvas;
@end

@implementation VibeDropWellsCanvas

- (void)drawRect:(NSRect)dirtyRect {
    [self.wellsView drawCanvas];
}

- (nullable NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end

@implementation VibeDropWellsView {
    NSVisualEffectView *_blurView;
    VibeDropWellsCanvas *_canvas;
    // Tinted symbols by name and color: drag-over redraws at mouse-move rate.
    NSMutableDictionary<NSString *, NSImage *> *_symbolCache;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _wells = @[];
        _style = [VibeDropWellsStyle systemStyle];
        _fadesStateChanges = YES;
        _symbolCache = [NSMutableDictionary new];
        self.wantsLayer = YES;
        // A collapsed host squashes the view, and views do not clip by
        // default since 10.14, so the drawing would spill over its neighbors.
        self.clipsToBounds = YES;

        _blurView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
        _blurView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        _blurView.material = NSVisualEffectMaterialHUDWindow;
        _blurView.state = NSVisualEffectStateActive;
        _blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _blurView.hidden = YES;
        [self addSubview:_blurView];

        _canvas = [[VibeDropWellsCanvas alloc] initWithFrame:self.bounds];
        _canvas.wellsView = self;
        _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_canvas];
    }
    return self;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [_symbolCache removeAllObjects];
    _canvas.needsDisplay = YES;
}

- (void)setWells:(NSArray<VibeDropWell *> *)wells {
    _wells = [wells copy];
    if (_hoveredIdentifier && ![[_wells valueForKey:@"identifier"] containsObject:_hoveredIdentifier]) {
        _hoveredIdentifier = nil;
    }
    _canvas.needsDisplay = YES;
}

// A nil style would draw with no font, which throws.
- (void)setStyle:(nullable VibeDropWellsStyle *)style {
    _style = style ? [style copy] : [VibeDropWellsStyle systemStyle];
    [_symbolCache removeAllObjects];
    _canvas.needsDisplay = YES;
}

- (void)setShowsBlur:(BOOL)showsBlur {
    _showsBlur = showsBlur;
    [self updateBlur];
}

- (void)setMinimumWellWidth:(CGFloat)minimumWellWidth {
    _minimumWellWidth = minimumWellWidth;
    _canvas.needsDisplay = YES;
}

- (void)updateBlur {
    _blurView.hidden = !(_dragActive && _showsBlur);
}

// A view may take the drag's frame changes while it shows.
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    _canvas.needsDisplay = YES;
}

#pragma mark - Geometry

// Stacked, every well and every gap must fit, or the wells' heights go
// negative.
- (BOOL)isEffectivelyVisible {
    NSUInteger rows = self.stacked ? _wells.count : 1;
    CGFloat least = 2 * kWellInset + rows * 2 * kWellCornerRadius + (rows - 1) * kWellGap;
    return self.window && !self.hiddenOrHasHiddenAncestor && NSHeight(self.bounds) > least;
}

- (NSRect)fullWellRect {
    return NSInsetRect(self.bounds, kWellInset, kWellInset);
}

- (BOOL)isStacked {
    NSUInteger count = _wells.count;
    if (count < 2 || _minimumWellWidth <= 0) {
        return NO;
    }
    return floor((NSWidth([self fullWellRect]) - kWellGap * (count - 1)) / count) < _minimumWellWidth;
}

- (NSRect)rectOfWellAtIndex:(NSUInteger)index {
    NSUInteger count = _wells.count;
    if (index >= count) {
        return NSZeroRect;
    }
    NSRect inset = [self fullWellRect];
    if (count == 1) {
        return inset;
    }
    if (self.stacked) {
        CGFloat height = floor((NSHeight(inset) - kWellGap * (count - 1)) / count);
        // The view is not flipped, so the first well is the top one. The
        // last is bottom-anchored, so the rounding slack lands in a gap.
        CGFloat y = index == count - 1 ? NSMinY(inset) : NSMaxY(inset) - height - index * (height + kWellGap);
        return NSMakeRect(NSMinX(inset), y, NSWidth(inset), height);
    }
    CGFloat width = floor((NSWidth(inset) - kWellGap * (count - 1)) / count);
    // The last is right-anchored, so the rounding slack lands in a gap, not
    // at the edge.
    CGFloat x = index == count - 1 ? NSMaxX(inset) - width : NSMinX(inset) + index * (width + kWellGap);
    return NSMakeRect(x, NSMinY(inset), width, NSHeight(inset));
}

- (nullable NSString *)identifierAtPoint:(NSPoint)point {
    for (NSUInteger i = 0; i < _wells.count; i++) {
        if (NSPointInRect(point, [self rectOfWellAtIndex:i])) {
            return _wells[i].identifier;
        }
    }
    return nil;
}

#pragma mark - Drag-over tracking

- (void)fileDragUpdatedAtWindowPoint:(NSPoint)point {
    if (![self isEffectivelyVisible]) {
        return;
    }
    NSString *hovered = [self identifierAtPoint:[self convertPoint:point fromView:nil]];
    if (_dragActive && (hovered == _hoveredIdentifier || [hovered isEqualToString:_hoveredIdentifier])) {
        return;
    }
    if (!_dragActive) {
        // Entering drag-over. Hover moves redraw plainly.
        [self addStateFade];
    }
    _dragActive = YES;
    _hoveredIdentifier = [hovered copy];
    [self updateBlur];
    _canvas.needsDisplay = YES;
}

- (void)fileDragEnded {
    if (!_dragActive) {
        return;
    }
    _dragActive = NO;
    _hoveredIdentifier = nil;
    [self addStateFade];
    [self updateBlur];
    _canvas.needsDisplay = YES;
}

- (nullable NSString *)wellIdentifierAtWindowPoint:(NSPoint)point {
    if (![self isEffectivelyVisible]) {
        return nil;
    }
    return [self identifierAtPoint:[self convertPoint:point fromView:nil]];
}

- (void)addStateFade {
    if (!_fadesStateChanges) {
        return;
    }
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kStateFadeDuration;
    [self.layer addAnimation:fade forKey:@"stateFade"];
}

// The wells take no click: the window under them keeps its own.
- (nullable NSView *)hitTest:(NSPoint)point {
    return nil;
}

#pragma mark - Drawing

- (void)drawCanvas {
    // The clip alone would still show slivers of off-center content
    // mid-resize.
    if (!_dragActive || ![self isEffectivelyVisible]) {
        return;
    }
    for (NSUInteger i = 0; i < _wells.count; i++) {
        [self drawWell:_wells[i] inRect:[self rectOfWellAtIndex:i]];
    }
}

// One path, so the dash pattern runs evenly through the corners.
static void VibeStrokeWellBorder(NSRect wellRect, NSColor *strokeColor, NSColor *_Nullable fillColor) {
    NSRect r = NSInsetRect(wellRect, kWellStrokeWidth / 2, kWellStrokeWidth / 2);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:kWellCornerRadius yRadius:kWellCornerRadius];
    if (fillColor) {
        [fillColor setFill];
        [path fill];
    }
    path.lineWidth = kWellStrokeWidth;
    path.lineCapStyle = NSLineCapStyleRound;
    CGFloat dash[2] = {kWellDashLength, kWellDashLength};
    [path setLineDash:dash count:2 phase:0];
    [strokeColor setStroke];
    [path stroke];
}

// Not drawAtPoint:, which cannot truncate a long translation.
static void VibeDrawTextCenteredAt(NSAttributedString *text, CGFloat centerX, CGFloat y, CGFloat maxWidth) {
    CGFloat width = MIN(ceil(text.size.width), maxWidth);
    [text drawWithRect:NSMakeRect(centerX - width / 2, y, width, ceil(text.size.height))
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
               context:nil];
}

- (void)drawWell:(VibeDropWell *)well inRect:(NSRect)rect {
    BOOL hovered = [_hoveredIdentifier isEqualToString:well.identifier];
    VibeDropWellsStyle *style = _style;
    VibeStrokeWellBorder(rect, hovered ? style.hoverStrokeColor : style.strokeColor,
                         hovered ? style.hoverFillColor : nil);

    NSColor *contentColor = hovered ? style.hoverContentColor : style.contentColor;
    NSImage *icon = [self symbolImage:well.symbolName color:contentColor];
    NSAttributedString *text = [[NSAttributedString alloc]
        initWithString:well.title
            attributes:@{NSFontAttributeName: style.font, NSForegroundColorAttributeName: contentColor}];

    NSSize iconSize = icon.size;
    NSSize textSize = text.size;
    CGFloat totalHeight = iconSize.height + kDropIconLabelGap + textSize.height;
    CGFloat textY = NSMidY(rect) - totalHeight / 2;
    CGFloat iconY = textY + textSize.height + kDropIconLabelGap;

    [icon drawInRect:NSMakeRect(NSMidX(rect) - iconSize.width / 2, iconY, iconSize.width, iconSize.height)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
    VibeDrawTextCenteredAt(text, NSMidX(rect), textY, NSWidth(rect) - 2 * kWellLabelInset);
}

- (NSImage *)symbolImage:(NSString *)name color:(NSColor *)color {
    NSString *key = [NSString stringWithFormat:@"%@/%@", name, color];
    NSImage *image = _symbolCache[key];
    if (!image) {
        image = [NSImage symbolNamed:name
                           pointSize:kDropIconPointSize
                              weight:NSFontWeightMedium
                             palette:@[color]
            accessibilityDescription:nil];
        _symbolCache[key] = image;
    }
    return image;
}

@end
