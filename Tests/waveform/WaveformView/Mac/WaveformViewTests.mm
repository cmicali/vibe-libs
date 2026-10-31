//
//  WaveformViewTests.mm
//  vibe-libs
//
//  The mac waveform view as drawn: its layer tree rendered into a bitmap with
//  no window server. The renderers' own geometry is WaveformStyles'
//  AudioWaveformTests'; this covers what the view adds over them: the theme it
//  resolves, the playhead line, the three states, and the seek it reports.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "WaveformViewInternal.h"
#import "WaveformView+Loading.h"
#import "WaveformTestSupport.h"

// The morph eases on a 60 Hz timer. The tests draw its settled state.
@interface WaveformView (TestSettle)
- (void)settleForTest;
@end

@implementation WaveformView (TestSettle)
- (void)settleForTest {
    [_currentWaveformRenderer settleMorphImmediately];
}
@end

@interface RecordingWaveformDelegate : NSObject <WaveformViewDelegate>
@property (nonatomic) NSMutableArray<NSNumber *> *seeks;
// Each scrub report, with a seek recorded as "seek" between them.
@property (nonatomic) NSMutableArray<NSNumber *> *scrubs;
@property (nonatomic) NSUInteger resolutions;
@end

@implementation RecordingWaveformDelegate
- (instancetype)init {
    if ((self = [super init])) {
        _seeks = [NSMutableArray array];
        _scrubs = [NSMutableArray array];
    }
    return self;
}
- (void)waveformView:(WaveformView *)waveformView didSeek:(float)percentage {
    [self.seeks addObject:@(percentage)];
    [self.scrubs addObject:@(NAN)];
}
- (void)waveformView:(WaveformView *)waveformView didScrubToProgress:(CGFloat)progress {
    [self.scrubs addObject:@(progress)];
}
- (void)waveformViewDidResolveTheme:(WaveformView *)waveformView {
    self.resolutions++;
}
@end

// Counts the gestures the view hands to the window, and moves nothing.
@interface WindowDragRecordingWindow : NSWindow
@property (nonatomic) NSUInteger windowDrags;
@end

@implementation WindowDragRecordingWindow
- (void)performWindowDragWithEvent:(NSEvent *)event {
    self.windowDrags++;
}
@end

static const CGFloat kWidth = 400;
static const CGFloat kHeight = 60;

// A loud, constant waveform, so every bar reaches the midline.
static CodableAudioWaveform *LoudWaveform(void) {
    return [[CodableAudioWaveform alloc] initWithWaveform:VibeTestSteadyWaveform(64, {-0.8f, 0.8f, 0.64f})];
}

static NSColor *Opaque(NSColor *color) {
    return [color colorWithAlphaComponent:1];
}

@interface WaveformViewTests : XCTestCase
@end

@implementation WaveformViewTests {
    // The state a provider maps onto a theme, as an app maps its own store.
    // It is the identifier, its custom pair, 3-Band's wells, and the line's
    // color.
    NSString *_themeIdentifier;
    NSColor *_customPlayed;
    NSColor *_customUnplayed;
    NSArray<NSColor *> *_bandWells;
    NSColor *_playheadColor;
    WaveformView *_view;
    RecordingWaveformDelegate *_delegate;
}

- (void)setUp {
    [super setUp];
    _themeIdentifier = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    _view = [[WaveformView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
    _view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    __weak WaveformViewTests *weakSelf = self;
    _view.themeProvider = ^WaveformTheme *(BOOL isDark, NSColor *artworkColor) {
        return [weakSelf themeIsDark:isDark artworkColor:artworkColor];
    };
    _view.centered = YES;
    _view.normalizesLevels = YES;
    _delegate = [RecordingWaveformDelegate new];
    _view.delegate = _delegate;
}

// A provider over the state above, as an app writes one, with a flat fill.
- (WaveformTheme *)themeIsDark:(BOOL)isDark artworkColor:(NSColor *)artworkColor {
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:_themeIdentifier isDark:isDark artworkColor:artworkColor
                                                customPlayed:_customPlayed customUnplayed:_customUnplayed];
    theme.flatFill = YES;
    if (_bandWells) {
        theme.bandColors = [WaveformTheme bandColorsForWells:_bandWells shaded:NO isDark:isDark];
    }
    theme.playheadColor = _playheadColor;
    return theme;
}

- (void)showStyle:(NSString *)style progress:(CGFloat)progress {
    [_view setWaveformStyle:style];
    [_view prepareForWaveformLoad];
    [_view showWaveform:LoudWaveform()];
    _view.progress = progress;
    [_view settleForTest];
}

- (NSBitmapImageRep *)render {
    [_view settleForTest];
    return VibeRenderLayer(_view.layer);
}

- (NSColor *)pixel:(NSBitmapImageRep *)rep x:(CGFloat)x {
    return VibePixel(rep, NO, x, kHeight / 2);
}

#pragma mark - States

- (void)testTheEmptyAndLoadingStatesAreTheMidlineAndExcludeEachOther {
    XCTAssertTrue(VibeBitmapIsBlank([self render]), @"nothing installed yet");

    [_view showEmptyPlaceholder];
    NSBitmapImageRep *empty = [self render];
    XCTAssertGreaterThan([self pixel:empty x:kWidth / 2].alphaComponent, 0, @"the empty midline");
    XCTAssertEqual(VibePixel(empty, NO, kWidth / 2, 5).alphaComponent, 0, @"only the midline is drawn");

    [_view showLoadingIndicator];
    XCTAssertTrue(_view.loadingIndicatorShown);
    XCTAssertGreaterThan([self pixel:[self render] x:kWidth - 2].alphaComponent, 0, @"the loading track");
    [_view showEmptyPlaceholder];
    XCTAssertFalse(_view.loadingIndicatorShown, @"empty replaces loading");

    [_view showLoadingIndicator];
    [_view prepareForWaveformLoad];
    XCTAssertFalse(_view.loadingIndicatorShown);
    XCTAssertTrue(VibeBitmapIsBlank([self render]), @"a load clears both");
}

#pragma mark - Played and unplayed

- (void)testThePlayedSideDiffersAndTheBoundaryIsTheProgress {
    for (NSString *style in @[@"detailed", @"basic", @"cupertino", @"sonic_cirrus"]) {
        [self showStyle:style progress:0.5];
        NSBitmapImageRep *rep = [self render];
        NSColor *played = [self pixel:rep x:kWidth * 0.2];
        NSColor *unplayed = [self pixel:rep x:kWidth * 0.8];
        XCTAssertGreaterThan(played.alphaComponent, 0, @"%@ nonblank", style);
        XCTAssertGreaterThan(unplayed.alphaComponent, 0, @"%@ nonblank", style);
        XCTAssertFalse(VibeColorsClose(played, unplayed, 0.02), @"%@: the halves must differ", style);
        XCTAssertGreaterThan(played.alphaComponent, unplayed.alphaComponent, @"%@: played is brighter", style);

        // The last column drawn in the played color.
        CGFloat boundary = -1;
        for (CGFloat x = 0; x < kWidth; x++) {
            NSColor *c = [self pixel:rep x:x];
            if (c.alphaComponent > 0 && VibeColorsClose(c, played, 0.02)) {
                boundary = x;
            }
        }
        // Bar renderers snap the boundary to a bar.
        XCTAssertEqualWithAccuracy(boundary, kWidth * 0.5, 8, @"%@", style);
    }
}

- (void)testProgressMovesTheBoundaryWithoutANewWaveform {
    [self showStyle:@"detailed" progress:0.25];
    NSColor *before = [self pixel:[self render] x:kWidth * 0.5];
    _view.progress = 0.75;
    NSColor *after = [self pixel:[self render] x:kWidth * 0.5];
    XCTAssertGreaterThan(after.alphaComponent, before.alphaComponent, @"the middle became played");
}

- (void)testAPlayheadLineDrawsEverythingPlayedAndMarksThePosition {
    _playheadColor = NSColor.redColor;
    [self showStyle:@"detailed" progress:0.5];
    NSBitmapImageRep *rep = [self render];
    XCTAssertTrue(VibeColorsClose([self pixel:rep x:kWidth * 0.2], [self pixel:rep x:kWidth * 0.8], 0.02),
                  @"both sides draw as played under a line");
    BOOL found = NO;
    for (CGFloat x = kWidth * 0.5 - 2; x <= kWidth * 0.5 + 2; x++) {
        NSColor *c = [self pixel:rep x:x];
        found = found || (c.redComponent > 0.9 && c.greenComponent < 0.1 && c.blueComponent < 0.1);
    }
    XCTAssertTrue(found, @"the red line sits at the progress");

    [_view prepareForWaveformLoad];
    NSBitmapImageRep *empty = [self render];
    for (CGFloat x = 0; x < kWidth; x++) {
        XCTAssertLessThan([self pixel:empty x:x].redComponent * [self pixel:empty x:x].alphaComponent, 0.5,
                          @"no line with nothing loaded");
    }
}

#pragma mark - Theme

- (void)testTheThemesColorsBeatTheStyle {
    _themeIdentifier = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
    _customPlayed = NSColor.blueColor;
    _customUnplayed = [NSColor.redColor colorWithAlphaComponent:0.5];
    for (NSString *style in @[@"detailed", @"basic", @"cupertino", @"sonic_cirrus"]) {
        [self showStyle:style progress:0.5];
        NSBitmapImageRep *rep = [self render];
        NSColor *played = Opaque([self pixel:rep x:kWidth * 0.2]);
        NSColor *unplayed = Opaque([self pixel:rep x:kWidth * 0.8]);
        XCTAssertGreaterThan(played.blueComponent, 0.9, @"%@ %@", style, played);
        XCTAssertLessThan(played.redComponent, 0.1, @"%@ %@", style, played);
        XCTAssertGreaterThan(unplayed.redComponent, 0.9, @"%@ %@", style, unplayed);
        XCTAssertLessThan(unplayed.blueComponent, 0.1, @"%@ %@", style, unplayed);
    }
}

// 3-Band's palette is the theme's band wells, not the style's own.
- (void)testTheThemesBandWellsBeatThreeBandsPalette {
    _bandWells = @[NSColor.greenColor, NSColor.greenColor, NSColor.greenColor];
    [self showStyle:@"three_band" progress:0.5];
    NSColor *played = Opaque([self pixel:[self render] x:kWidth * 0.2]);
    XCTAssertGreaterThan(played.greenComponent, 0.9, @"%@", played);
    XCTAssertLessThan(played.redComponent, 0.1, @"%@", played);
    XCTAssertLessThan(played.blueComponent, 0.1, @"%@", played);
}

// Album Art keeps the played side at the base and colors what is to come.
- (void)testTheAlbumArtColorRidesTheArtworkInstall {
    _themeIdentifier = SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART;
    [self showStyle:@"detailed" progress:0.5];
    NSColor *noArt = Opaque([self pixel:[self render] x:kWidth * 0.8]);
    XCTAssertEqualWithAccuracy(noArt.redComponent, noArt.greenComponent, 0.02, @"no art is Mono's gray");
    NSUInteger resolutions = _delegate.resolutions;

    _view.artworkThemeColor = [NSColor colorWithSRGBRed:0.1 green:0.8 blue:0.2 alpha:1];
    XCTAssertEqual(_delegate.resolutions, resolutions, @"the color waits for the install's refresh");
    [_view refreshThemeColors];
    XCTAssertEqual(_delegate.resolutions, resolutions + 1);
    NSBitmapImageRep *rep = [self render];
    NSColor *unplayed = Opaque([self pixel:rep x:kWidth * 0.8]);
    XCTAssertGreaterThan(unplayed.greenComponent, unplayed.redComponent + 0.2, @"green art, green bars: %@", unplayed);
    NSColor *played = Opaque([self pixel:rep x:kWidth * 0.2]);
    XCTAssertEqualWithAccuracy(played.redComponent, played.greenComponent, 0.02, @"the played side stays the base");
}

- (void)testTheAppearanceFlipReResolvesTheTheme {
    [self showStyle:@"detailed" progress:0.5];
    NSColor *dark = Opaque([self pixel:[self render] x:kWidth * 0.2]);
    NSUInteger resolutions = _delegate.resolutions;
    _view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    XCTAssertGreaterThan(_delegate.resolutions, resolutions);
    NSColor *light = Opaque([self pixel:[self render] x:kWidth * 0.2]);
    XCTAssertGreaterThan(dark.redComponent, 0.5, @"Mono is white on dark");
    XCTAssertLessThan(light.redComponent, 0.5, @"and black on light");
}

#pragma mark - Seek

- (void)testAClickSeeksToItsFraction {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    XCTAssertFalse(_view.dragSeeks, @"a drag moves the window unless pushed otherwise");
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.3 in:window];
    XCTAssertEqual(_delegate.seeks.count, 1u);
    XCTAssertEqualWithAccuracy(_delegate.seeks.firstObject.floatValue, 0.3, 1e-6);
    XCTAssertEqualWithAccuracy(_view.progress, 0, 1e-9, @"the position comes back through the owner");
}

// Pushed dragSeeks: the drag tracks the cursor and seeks once, on release,
// to where it ended.
- (void)testAPushedSeekingDragSeeksOnceOnRelease {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    _view.dragSeeks = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.5 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.7 in:window];
    XCTAssertEqual(_delegate.seeks.count, 0u, @"no seek with the button down");
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.7 in:window];
    XCTAssertEqual(_delegate.seeks.count, 1u);
    XCTAssertEqualWithAccuracy(_delegate.seeks.firstObject.floatValue, 0.7, 1e-6);
}

// The drag reports each place it sits, clamped to the view, then its end
// after the release's seek. A click reports nothing.
- (void)testASeekingDragReportsWhereItSits {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    _view.dragSeeks = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.3 in:window];
    XCTAssertEqual(_delegate.scrubs.count, 1u);
    XCTAssertTrue(isnan(_delegate.scrubs.firstObject.doubleValue), @"a click only seeks");
    [_delegate.scrubs removeAllObjects];

    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.5 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 1.5 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.7 in:window];
    NSArray<NSNumber *> *scrubs = _delegate.scrubs;
    XCTAssertEqual(scrubs.count, 4u);
    XCTAssertEqualWithAccuracy(scrubs[0].doubleValue, 0.5, 1e-6);
    XCTAssertEqualWithAccuracy(scrubs[1].doubleValue, 1, 1e-6, @"clamped to the view");
    XCTAssertTrue(isnan(scrubs[2].doubleValue), @"the seek comes first");
    XCTAssertLessThan(scrubs[3].doubleValue, 0, @"then the drag's end");
}

// A presentation reset cancels a drag in flight, and says it ended.
- (void)testAResetEndsADragInFlight {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    _view.dragSeeks = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.6 in:window];
    [_view prepareForWaveformLoad];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.6 in:window];
    XCTAssertEqual(_delegate.scrubs.count, 2u);
    XCTAssertLessThan(_delegate.scrubs.lastObject.doubleValue, 0);
    XCTAssertEqual(_delegate.seeks.count, 0u, @"the release seeks nothing");
}

// A drag whose release cannot seek still says it ended.
- (void)testADragThatCannotSeekStillEnds {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    _view.dragSeeks = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.6 in:window];
    _view.frame = NSMakeRect(0, 0, 0, kHeight);
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.6 in:window];
    XCTAssertEqual(_delegate.scrubs.count, 2u);
    XCTAssertLessThan(_delegate.scrubs.lastObject.doubleValue, 0);
    XCTAssertEqual(_delegate.seeks.count, 0u);
}

- (WindowDragRecordingWindow *)recordingWindow {
    WindowDragRecordingWindow *window =
        [[WindowDragRecordingWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, kHeight)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:YES];
    window.releasedWhenClosed = NO;
    [window.contentView addSubview:_view];
    return window;
}

// The default hands an empty view's press, and a drag that does not seek,
// to the window.
- (void)testByDefaultTheGesturesThatDoNotSeekMoveTheWindow {
    WindowDragRecordingWindow *window = [self recordingWindow];
    XCTAssertTrue(_view.dragsWindow);
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    XCTAssertEqual(window.windowDrags, 1u, @"nothing loaded");
    [self showStyle:@"detailed" progress:0];
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.5 in:window];
    XCTAssertEqual(window.windowDrags, 2u, @"a drag with dragSeeks off");
}

// Off: no gesture reaches the window, a drag seeks nothing, and a click
// still seeks.
- (void)testWithDraggingTheWindowOffNoGestureReachesTheWindow {
    WindowDragRecordingWindow *window = [self recordingWindow];
    _view.dragsWindow = NO;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.3 in:window];
    [self showStyle:@"detailed" progress:0];
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.5 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.5 in:window];
    XCTAssertEqual(window.windowDrags, 0u);
    XCTAssertEqual(_delegate.seeks.count, 0u, @"an empty press and a drag seek nothing");
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.3 in:window];
    XCTAssertEqual(_delegate.seeks.count, 1u);
    XCTAssertEqualWithAccuracy(_delegate.seeks.firstObject.floatValue, 0.3, 1e-6);
}

- (void)mouse:(NSEventType)type at:(CGFloat)x in:(NSWindow *)window {
    NSEvent *event = [NSEvent mouseEventWithType:type location:NSMakePoint(x, kHeight / 2) modifierFlags:0
                                       timestamp:0 windowNumber:window.windowNumber context:nil
                                     eventNumber:0 clickCount:1 pressure:1];
    switch (type) {
        case NSEventTypeLeftMouseDown: [_view mouseDown:event]; break;
        case NSEventTypeLeftMouseDragged: [_view mouseDragged:event]; break;
        default: [_view mouseUp:event]; break;
    }
}

- (void)testAccessibilityStepsReportASeekOnlyWithAWaveform {
    XCTAssertFalse([_view accessibilityPerformIncrement]);
    [self showStyle:@"detailed" progress:0.5];
    XCTAssertEqualObjects(_view.accessibilityValue,
                          [NSNumberFormatter localizedStringFromNumber:@0.5 numberStyle:NSNumberFormatterPercentStyle]);
    XCTAssertTrue([_view accessibilityPerformIncrement]);
    XCTAssertTrue([_view accessibilityPerformDecrement]);
    XCTAssertEqualObjects(_delegate.seeks, (@[@0.55f, @0.45f]));
    _view.progress = 1;
    XCTAssertFalse([_view accessibilityPerformIncrement], @"already at the end");
}

// An app's provider speaks the value instead, from the clamped progress.
- (void)testAProviderSpeaksTheValueFromTheProgress {
    [self showStyle:@"detailed" progress:0.25];
    __block CGFloat asked = -1;
    _view.accessibilityValueProvider = ^NSString *(CGFloat progress) {
        asked = progress;
        return @"1:00 of 4:00";
    };
    XCTAssertEqualObjects(_view.accessibilityValue, @"1:00 of 4:00");
    XCTAssertEqualWithAccuracy(asked, 0.25, 1e-9);
    _view.progress = 1.5;
    (void)_view.accessibilityValue;
    XCTAssertEqualWithAccuracy(asked, 1, 1e-9, @"clamped, as the percentage is");
    _view.accessibilityValueProvider = nil;
    XCTAssertEqualObjects(_view.accessibilityValue,
                          [NSNumberFormatter localizedStringFromNumber:@1 numberStyle:NSNumberFormatterPercentStyle]);
}

#pragma mark - Seekable, and the keyboard

// Not seekable: a click, a drag, and VoiceOver seek nothing, and a press
// goes where an empty view's does.
- (void)testANotSeekableViewSeeksNothing {
    WindowDragRecordingWindow *window = [self recordingWindow];
    [self showStyle:@"detailed" progress:0.5];
    XCTAssertTrue(_view.seekable);
    _view.seekable = NO;
    _view.dragSeeks = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.3 in:window];
    XCTAssertEqual(window.windowDrags, 1u, @"as an empty view's press");
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.6 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.6 in:window];
    XCTAssertFalse([_view accessibilityPerformIncrement]);
    XCTAssertEqual(_delegate.seeks.count, 0u);
    XCTAssertEqual(_delegate.scrubs.count, 0u);
    _view.seekable = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.3 in:window];
    XCTAssertEqual(_delegate.seeks.count, 1u, @"seekable again");
}

// Turning seeking off ends a drag in flight, which says so, and its release
// seeks nothing.
- (void)testTurningSeekingOffEndsADrag {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0];
    _view.dragSeeks = YES;
    [self mouse:NSEventTypeLeftMouseDown at:kWidth * 0.3 in:window];
    [self mouse:NSEventTypeLeftMouseDragged at:kWidth * 0.6 in:window];
    _view.seekable = NO;
    [self mouse:NSEventTypeLeftMouseUp at:kWidth * 0.6 in:window];
    XCTAssertEqual(_delegate.scrubs.count, 2u);
    XCTAssertLessThan(_delegate.scrubs.lastObject.doubleValue, 0);
    XCTAssertEqual(_delegate.seeks.count, 0u);
}

- (NSEvent *)arrow:(unichar)key modifiers:(NSEventModifierFlags)modifiers {
    NSString *characters = [NSString stringWithCharacters:&key length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                       modifierFlags:modifiers | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad
                           timestamp:0 windowNumber:0 context:nil characters:characters
         charactersIgnoringModifiers:characters isARepeat:NO
                             keyCode:key == NSRightArrowFunctionKey ? 124 : 123];
}

// The arrows step as VoiceOver does, only for an app that asks, and only
// while the view can seek. A modified arrow is not the view's.
- (void)testTheArrowsStepOnlyWhenAsked {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(kWidth, kHeight));
    [window.contentView addSubview:_view];
    [self showStyle:@"detailed" progress:0.5];
    XCTAssertFalse(_view.takesKeyboardFocus);
    XCTAssertFalse(_view.acceptsFirstResponder, @"no focus unless asked");
    [_view keyDown:[self arrow:NSRightArrowFunctionKey modifiers:0]];
    XCTAssertEqual(_delegate.seeks.count, 0u);

    _view.takesKeyboardFocus = YES;
    [_view keyDown:[self arrow:NSRightArrowFunctionKey modifiers:0]];
    [_view keyDown:[self arrow:NSLeftArrowFunctionKey modifiers:0]];
    XCTAssertEqualObjects(_delegate.seeks, (@[@0.55f, @0.45f]));
    [_view keyDown:[self arrow:NSRightArrowFunctionKey modifiers:NSEventModifierFlagCommand]];
    _view.seekable = NO;
    XCTAssertFalse(_view.acceptsFirstResponder);
    [_view keyDown:[self arrow:NSRightArrowFunctionKey modifiers:0]];
    XCTAssertEqual(_delegate.seeks.count, 2u);
}

@end
