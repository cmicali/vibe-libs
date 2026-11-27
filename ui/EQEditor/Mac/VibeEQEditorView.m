//
//  VibeEQEditorView.m
//  vibe-libs
//

#import "VibeEQEditorView.h"

#import "VibeEQEditorParts.h"

@implementation VibeEQEditorStrings

- (instancetype)init {
    self = [super init];
    if (self) {
        _graphicFace = @"Graphic";
        _parametricFace = @"Parametric";
        _graphicUnavailable = @"These bands don't fit the graphic EQ's ten sliders. Edit them here.";
        _bandTypes = @[@"Peak", @"Low Shelf", @"High Shelf", @"Low-Pass", @"High-Pass"];
        _onColumn = @"On";
        _typeColumn = @"Type";
        _frequencyColumn = @"Hz";
        _gainColumn = @"dB";
        _qColumn = @"Q";
        _addBand = @"Add Band";
        _removeBand = @"Remove Band";
        _bandFormat = @"Band %ld";
        _curveAccessibilityLabel = @"EQ curve";
        _slidersAccessibilityLabel = @"Graphic EQ";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    VibeEQEditorStrings *copy = [[[self class] alloc] init];
    copy.graphicFace = self.graphicFace;
    copy.parametricFace = self.parametricFace;
    copy.graphicUnavailable = self.graphicUnavailable;
    copy.bandTypes = self.bandTypes;
    copy.onColumn = self.onColumn;
    copy.typeColumn = self.typeColumn;
    copy.frequencyColumn = self.frequencyColumn;
    copy.gainColumn = self.gainColumn;
    copy.qColumn = self.qColumn;
    copy.addBand = self.addBand;
    copy.removeBand = self.removeBand;
    copy.bandFormat = self.bandFormat;
    copy.curveAccessibilityLabel = self.curveAccessibilityLabel;
    copy.slidersAccessibilityLabel = self.slidersAccessibilityLabel;
    return copy;
}

@end

static const CGFloat kFaceControlHeight = 24;
static const CGFloat kGap = 10;

@interface VibeEQEditorView () <VibeEQFaceOwner> {
    VibeEQFaceTabs *_faceControl;
    VibeEQGraphicView *_graphicView;
    VibeEQCurveView *_curveView;
    VibeEQBandListView *_bandList;
    // The face the host or the user chose. The graphic face shows only while
    // the bands fit it.
    VibeEQEditorFace _chosenFace;
}
@end

@implementation VibeEQEditorView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _settings = [VibeListeningSettings neutralSettings];
        _enabled = YES;
        _strings = [[VibeEQEditorStrings alloc] init];
        _locale = NSLocale.currentLocale;

        _faceControl = [[VibeEQFaceTabs alloc] initWithFrame:NSZeroRect];
        _faceControl.target = self;
        _faceControl.action = @selector(chooseFace:);
        [self addSubview:_faceControl];

        _graphicView = [[VibeEQGraphicView alloc] initWithFrame:NSZeroRect];
        _curveView = [[VibeEQCurveView alloc] initWithFrame:NSZeroRect];
        _bandList = [[VibeEQBandListView alloc] initWithFrame:NSZeroRect];
        for (id part in @[_graphicView, _curveView, _bandList]) {
            [part setOwner:self];
            [self addSubview:part];
        }
        [self pushStrings];
        [self pushBandsExceptFrom:nil];
        [self updateFace];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    if (_compactPresentation) {
        CGFloat sliders = _face == VibeEQEditorFaceGraphic ? MIN(100, round(NSHeight(bounds) * 0.45)) : 0;
        NSRect curve, faders;
        NSDivideRect(bounds, &faders, &curve, sliders, NSMaxYEdge);
        _curveView.frame = curve;
        _graphicView.frame = faders;
        return;
    }
    CGFloat controlWidth = MIN(NSWidth(bounds), 240);
    _faceControl.frame = NSMakeRect(round((NSWidth(bounds) - controlWidth) / 2), 0, controlWidth, kFaceControlHeight);
    CGFloat top = kFaceControlHeight + kGap;
    NSRect content = NSMakeRect(0, top, NSWidth(bounds), MAX(0, NSHeight(bounds) - top));
    _graphicView.frame = content;
    // The list keeps room for three rows and its buttons; the graph takes
    // the rest, up to about three fifths.
    CGFloat listHeight = MAX(120, round(NSHeight(content) * 0.4));
    CGFloat curveHeight = MAX(0, NSHeight(content) - listHeight - kGap);
    _curveView.frame = NSMakeRect(0, top, NSWidth(bounds), curveHeight);
    _bandList.frame = NSMakeRect(0, top + curveHeight + kGap, NSWidth(bounds), MAX(0, NSHeight(content) - curveHeight - kGap));
}

#pragma mark - Properties

- (void)setSettings:(VibeListeningSettings *)settings {
    VibeListeningSettings *value = settings ? [settings copy] : [VibeListeningSettings neutralSettings];
    if ([value isEqual:_settings]) {
        return;
    }
    _settings = value;
    [self pushBandsExceptFrom:nil];
    [self updateFace];
}

- (void)setCompactPresentation:(BOOL)compact {
    if (compact == _compactPresentation) {
        return;
    }
    _compactPresentation = compact;
    [self updateFace];
}

- (NSUInteger)selectedBandIndex {
    return _curveView.selectedIndex;
}

- (void)setSelectedBandIndex:(NSUInteger)index {
    _curveView.selectedIndex = index;
    _bandList.selectedIndex = _curveView.selectedIndex;
}

- (IBAction)addBand:(id)sender {
    if (_enabled && _face == VibeEQEditorFaceParametric) {
        [_bandList addBand:sender];
    }
}

- (IBAction)removeBand:(id)sender {
    if (_enabled && _face == VibeEQEditorFaceParametric) {
        [_bandList removeBand:sender];
    }
}

- (BOOL)graphicFaceAvailable {
    return _settings.bands.count == 0 || _settings.isGraphic;
}

- (void)setFace:(VibeEQEditorFace)face {
    _chosenFace = face;
    [self updateFace];
}

- (double)sampleRate {
    return _curveView.sampleRate;
}

- (void)setSampleRate:(double)sampleRate {
    _curveView.sampleRate = sampleRate;
}

- (void)setAccentColor:(NSColor *)accentColor {
    _accentColor = accentColor;
    _curveView.needsDisplay = YES;
    _graphicView.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    _faceControl.enabled = enabled;
    _graphicView.enabled = enabled;
    [self updateCurveEnabled];
    _bandList.enabled = enabled;
    CGFloat alpha = enabled ? 1 : 0.5;
    for (NSView *part in @[_faceControl, _graphicView, _curveView, _bandList]) {
        part.alphaValue = alpha;
    }
    NSResponder *responder = self.window.firstResponder;
    if (!enabled && [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self]) {
        [self.window makeFirstResponder:nil];
    }
}

- (NSView *)hitTest:(NSPoint)point {
    return self.enabled ? [super hitTest:point] : nil;
}

- (void)setStrings:(VibeEQEditorStrings *)strings {
    _strings = strings ? [strings copy] : [[VibeEQEditorStrings alloc] init];
    [self pushStrings];
}

- (void)setLocale:(NSLocale *)locale {
    _locale = locale ? [locale copy] : NSLocale.currentLocale;
    _graphicView.locale = _locale;
    _curveView.locale = _locale;
    _bandList.locale = _locale;
}

- (void)pushStrings {
    _faceControl.labels = @[_strings.graphicFace, _strings.parametricFace];
    _graphicView.strings = _strings;
    _curveView.strings = _strings;
    _bandList.strings = _strings;
    [self updateFaceControl];
}

- (void)pushBandsExceptFrom:(nullable NSView *)source {
    NSArray<VibeEQBand *> *bands = _settings.bands;
    if (source != _graphicView) {
        _graphicView.bands = bands;
    }
    if (source != _curveView) {
        _curveView.bands = bands;
    }
    if (source != _bandList) {
        _bandList.bands = bands;
    }
}

// The face is worked out again only when the host sets the settings or a
// face, so a user's edit never swaps the face under the pointer. An edit in
// the parametric face can make the bands fit again, and the face stays.
- (void)updateFace {
    _face = _chosenFace == VibeEQEditorFaceGraphic && self.graphicFaceAvailable ? VibeEQEditorFaceGraphic
                                                                               : VibeEQEditorFaceParametric;
    BOOL graphic = _face == VibeEQEditorFaceGraphic;
    _graphicView.hidden = !graphic;
    _curveView.hidden = graphic && !_compactPresentation;
    _bandList.hidden = graphic || _compactPresentation;
    _faceControl.hidden = _compactPresentation;
    [self updateCurveEnabled];
    [self updateFaceControl];
    self.needsLayout = YES;
}

// Above the compact graphic sliders the curve only shows the response.
- (void)updateCurveEnabled {
    _curveView.enabled = _enabled && !(_compactPresentation && _face == VibeEQEditorFaceGraphic);
}

- (void)updateFaceControl {
    BOOL available = self.graphicFaceAvailable;
    [_faceControl setEnabled:available forSegment:VibeEQEditorFaceGraphic];
    [_faceControl setToolTip:available ? nil : _strings.graphicUnavailable forSegment:VibeEQEditorFaceGraphic];
    _faceControl.selectedSegment = _face;
}

// The tabs send only an enabled tab other than the current one.
- (void)chooseFace:(VibeEQFaceTabs *)sender {
    self.face = (VibeEQEditorFace)sender.selectedSegment;
    if ([self.delegate respondsToSelector:@selector(eqEditorViewDidChangeFace:)]) {
        [self.delegate eqEditorViewDidChangeFace:self];
    }
}

#pragma mark - VibeEQFaceOwner

- (void)face:(NSView *)face didChangeBands:(NSArray<VibeEQBand *> *)bands {
    BOOL wasAvailable = self.graphicFaceAvailable;
    VibeMutableListeningSettings *settings = [_settings mutableCopy];
    settings.bands = bands;
    _settings = [settings copy];
    [self pushBandsExceptFrom:face];
    if (self.graphicFaceAvailable != wasAvailable) {
        [self updateFaceControl];
    }
    [self.delegate eqEditorView:self didChangeSettings:_settings];
}

- (void)faceDidEndEditing:(NSView *)face {
    [self.delegate eqEditorViewDidEndEditing:self];
}

- (void)face:(NSView *)face didSelectBandAtIndex:(NSUInteger)index {
    if (face != _curveView) {
        _curveView.selectedIndex = index;
    }
    if (face != _bandList) {
        _bandList.selectedIndex = index;
    }
    if ([self.delegate respondsToSelector:@selector(eqEditorViewDidSelectBand:)]) {
        [self.delegate eqEditorViewDidSelectBand:self];
    }
}

@end

@implementation VibeEQEditorView (Parts)

- (VibeEQFaceTabs *)faceControl {
    return _faceControl;
}

- (VibeEQGraphicView *)graphicView {
    return _graphicView;
}

- (VibeEQCurveView *)curveView {
    return _curveView;
}

- (VibeEQBandListView *)bandList {
    return _bandList;
}

@end
