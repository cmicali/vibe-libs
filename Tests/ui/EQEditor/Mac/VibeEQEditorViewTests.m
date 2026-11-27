//
//  VibeEQEditorViewTests.m
//  EQEditorTests
//
//  The editor in a window kept off every display: which face shows, what a
//  drag, a key, a field, and VoiceOver change, what the delegate hears, and
//  how it draws in both appearances.
//

#import <XCTest/XCTest.h>

#import "DrawnControls.h"
#import "DrawnViewTestSupport.h"
#import "VibeEQEditorMath.h"
#import "VibeEQEditorParts.h"
#import "VibeEQEditorView.h"

@interface VibeEQEditorViewTests : XCTestCase <VibeEQEditorViewDelegate>
@end

@implementation VibeEQEditorViewTests {
    NSWindow *_window;
    VibeEQEditorView *_editor;
    NSMutableArray<VibeListeningSettings *> *_changes;
    NSUInteger _ends;
    NSUInteger _faceChanges;
}

- (void)setUp {
    _window = VibeOffscreenWindow(NSMakeSize(640, 460));
    _editor = [[VibeEQEditorView alloc] initWithFrame:NSMakeRect(0, 0, 640, 460)];
    _editor.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    _editor.delegate = self;
    _window.contentView = _editor;
    [_editor layoutSubtreeIfNeeded];
    _changes = [NSMutableArray array];
    _ends = 0;
    _faceChanges = 0;
}

- (void)tearDown {
    [_window close];
    _window = nil;
}

#pragma mark - Delegate

- (void)eqEditorView:(VibeEQEditorView *)view didChangeSettings:(VibeListeningSettings *)settings {
    XCTAssertEqual(view, _editor);
    XCTAssertEqualObjects(settings, view.settings);
    [_changes addObject:settings];
}

- (void)eqEditorViewDidEndEditing:(VibeEQEditorView *)view {
    _ends++;
}

- (void)eqEditorViewDidChangeFace:(VibeEQEditorView *)view {
    _faceChanges++;
}

#pragma mark - Helpers

- (VibeListeningSettings *)settingsWithBands:(NSArray<VibeEQBand *> *)bands {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    settings.eqEnabled = YES;
    settings.preampAutomatic = NO;
    settings.preampDB = -6;
    settings.crossfeed = VibeCrossfeedMedium;
    settings.balance = 0.25;
    settings.bands = bands;
    return [settings copy];
}

- (VibeListeningSettings *)graphicSettings {
    return [self settingsWithBands:[VibeListeningSettings graphicBandsWithGains:@[@0, @0, @0, @0, @0, @3, @0, @0, @0, @0]]];
}

- (VibeListeningSettings *)parametricSettings {
    return [self settingsWithBands:@[
        [VibeEQBand bandWithType:VibeEQBandTypeHighPass frequency:30 gainDB:0 q:0.71],
        [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:1000 gainDB:3 q:1.4],
        [VibeEQBand bandWithType:VibeEQBandTypeHighShelf frequency:8000 gainDB:-4 q:0.7],
    ]];
}

- (void)showParametric:(VibeListeningSettings *)settings {
    _editor.settings = settings;
    _editor.face = VibeEQEditorFaceParametric;
    [_editor layoutSubtreeIfNeeded];
}

- (NSEvent *)mouse:(NSEventType)type at:(NSPoint)point in:(NSView *)view flags:(NSEventModifierFlags)flags clicks:(NSInteger)clicks {
    return [NSEvent mouseEventWithType:type
                              location:[view convertPoint:point toView:nil]
                         modifierFlags:flags
                             timestamp:0
                          windowNumber:_window.windowNumber
                               context:nil
                           eventNumber:0
                            clickCount:clicks
                              pressure:1];
}

// A press at from, moves through each point, and a release at the last.
- (void)dragIn:(NSView *)view from:(NSPoint)from through:(NSArray<NSValue *> *)points flags:(NSEventModifierFlags)flags {
    [view mouseDown:[self mouse:NSEventTypeLeftMouseDown at:from in:view flags:flags clicks:1]];
    NSPoint last = from;
    for (NSValue *value in points) {
        last = value.pointValue;
        [view mouseDragged:[self mouse:NSEventTypeLeftMouseDragged at:last in:view flags:flags clicks:1]];
    }
    [view mouseUp:[self mouse:NSEventTypeLeftMouseUp at:last in:view flags:flags clicks:1]];
}

// A click's action, sent straight to the target, as a click on an enabled
// control sends it. A disabled control sends nothing.
- (void)fire:(NSControl *)control {
    if (!control.isEnabled) {
        return;
    }
    void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[control.target methodForSelector:control.action];
    send(control.target, control.action, control);
}

- (NSEvent *)key:(unichar)key flags:(NSEventModifierFlags)flags {
    NSString *characters = [NSString stringWithCharacters:&key length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                            location:NSZeroPoint
                       modifierFlags:flags
                           timestamp:0
                        windowNumber:_window.windowNumber
                             context:nil
                          characters:characters
         charactersIgnoringModifiers:characters
                           isARepeat:NO
                             keyCode:0];
}

- (void)assertKeptTheRestOf:(VibeListeningSettings *)settings {
    XCTAssertTrue(settings.eqEnabled);
    XCTAssertFalse(settings.preampAutomatic);
    XCTAssertEqual(settings.preampDB, -6);
    XCTAssertEqual(settings.crossfeed, VibeCrossfeedMedium);
    XCTAssertEqual(settings.balance, 0.25);
}

#pragma mark - Faces

- (void)testCompactEditorKeepsTheCurveAboveTheGraphicSliders {
    _editor.settings = [self graphicSettings];
    _editor.compactPresentation = YES;
    [_editor layoutSubtreeIfNeeded];
    XCTAssertTrue(_editor.faceControl.hidden);
    XCTAssertFalse(_editor.curveView.hidden);
    XCTAssertFalse(_editor.graphicView.hidden);
    XCTAssertFalse(_editor.curveView.enabled);
    XCTAssertEqual(NSMaxY(_editor.curveView.frame), NSMinY(_editor.graphicView.frame));

    _editor.face = VibeEQEditorFaceParametric;
    [_editor layoutSubtreeIfNeeded];
    XCTAssertTrue(_editor.curveView.enabled);
    XCTAssertTrue(_editor.bandList.hidden);
    XCTAssertTrue(NSEqualRects(_editor.curveView.frame, _editor.bounds));
    _editor.selectedBandIndex = 4;
    XCTAssertEqual(_editor.curveView.selectedIndex, 4u);
    [_editor addBand:nil];
    XCTAssertEqual(_editor.settings.bands.count, 11u);
    XCTAssertEqual(_editor.selectedBandIndex, 10u);
    [_editor removeBand:nil];
    XCTAssertEqual(_editor.settings.bands.count, 10u);
    _editor.compactPresentation = NO;
    XCTAssertFalse(_editor.faceControl.hidden);
    XCTAssertFalse(_editor.bandList.hidden);
}

- (void)testNeutralSettingsShowFlatSliders {
    XCTAssertEqualObjects(_editor.settings, [VibeListeningSettings neutralSettings]);
    XCTAssertTrue(_editor.graphicFaceAvailable);
    XCTAssertEqual(_editor.face, VibeEQEditorFaceGraphic);
    XCTAssertFalse(_editor.graphicView.hidden);
    XCTAssertTrue(_editor.curveView.hidden);
    XCTAssertTrue(_editor.bandList.hidden);
    for (NSUInteger i = 0; i < 10; i++) {
        XCTAssertEqual([_editor.graphicView gainAtSlider:i], 0);
    }
}

- (void)testBandsThatDontFitDisableTheGraphicTab {
    _editor.settings = [self parametricSettings];
    _editor.face = VibeEQEditorFaceGraphic;
    XCTAssertFalse(_editor.graphicFaceAvailable);
    XCTAssertEqual(_editor.face, VibeEQEditorFaceParametric);
    XCTAssertTrue(_editor.graphicView.hidden);
    XCTAssertFalse(_editor.curveView.hidden);
    XCTAssertFalse([_editor.faceControl isEnabledForSegment:VibeEQEditorFaceGraphic]);
    XCTAssertEqualObjects([_editor.faceControl toolTipForSegment:VibeEQEditorFaceGraphic],
                          _editor.strings.graphicUnavailable);
    XCTAssertEqual(_editor.faceControl.selectedSegment, VibeEQEditorFaceParametric);
    XCTAssertFalse([_editor.faceControl chooseSegment:VibeEQEditorFaceGraphic]);
    NSAccessibilityElement *graphicTab = _editor.faceControl.accessibilityChildren[0];
    XCTAssertEqualObjects(graphicTab.accessibilityRole, NSAccessibilityRadioButtonRole);
    XCTAssertEqualObjects(graphicTab.accessibilityLabel, @"Graphic");
    XCTAssertFalse(graphicTab.isAccessibilityEnabled);
    XCTAssertEqualObjects(graphicTab.accessibilityHelp, _editor.strings.graphicUnavailable);

    // Back to a graphic setting, the chosen face returns.
    _editor.settings = [self graphicSettings];
    XCTAssertEqual(_editor.face, VibeEQEditorFaceGraphic);
    XCTAssertTrue([_editor.faceControl isEnabledForSegment:VibeEQEditorFaceGraphic]);
    XCTAssertNil([_editor.faceControl toolTipForSegment:VibeEQEditorFaceGraphic]);
    XCTAssertEqual(_changes.count, 0u);
}

- (void)testSwitchingAGraphicSettingToParametricKeepsItsTenBands {
    VibeListeningSettings *graphic = [self graphicSettings];
    _editor.settings = graphic;
    XCTAssertTrue([_editor.faceControl chooseSegment:VibeEQEditorFaceParametric]);
    XCTAssertEqual(_editor.face, VibeEQEditorFaceParametric);
    XCTAssertEqual(_faceChanges, 1u);
    XCTAssertEqualObjects(_editor.settings, graphic);
    XCTAssertEqualObjects(_editor.curveView.bands, graphic.bands);
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 10);
    XCTAssertTrue([_editor.faceControl isEnabledForSegment:VibeEQEditorFaceGraphic]);
    XCTAssertEqual(_changes.count, 0u);
}

- (void)testAParametricEditThatBreaksTheLayoutDisablesTheGraphicTab {
    [self showParametric:[self graphicSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSPoint node = [curve nodeCenterForBandAtIndex:5];
    [self dragIn:curve from:node through:@[[NSValue valueWithPoint:NSMakePoint(node.x + 40, node.y)]] flags:0];
    XCTAssertFalse(_editor.settings.isGraphic);
    XCTAssertFalse([_editor.faceControl isEnabledForSegment:VibeEQEditorFaceGraphic]);
    XCTAssertEqual(_editor.face, VibeEQEditorFaceParametric);
}

// An edit that makes the bands fit again leaves the parametric face up, and
// the tabs say so; the graphic tab turns back on.
- (void)testAnEditNeverSwapsTheFace {
    _editor.face = VibeEQEditorFaceGraphic;
    _editor.settings = [self settingsWithBands:@[[VibeEQBand bandWithType:VibeEQBandTypePeak frequency:1000 gainDB:3 q:1]]];
    XCTAssertEqual(_editor.face, VibeEQEditorFaceParametric);
    [_editor layoutSubtreeIfNeeded];
    VibeEQCurveView *curve = _editor.curveView;
    XCTAssertTrue([_window makeFirstResponder:curve]);
    [curve keyDown:[self key:NSDeleteCharacter flags:0]];
    XCTAssertEqual(_editor.settings.bands.count, 0u);
    XCTAssertTrue(_editor.graphicFaceAvailable);
    XCTAssertEqual(_editor.face, VibeEQEditorFaceParametric);
    XCTAssertEqual(_editor.faceControl.selectedSegment, VibeEQEditorFaceParametric);
    XCTAssertTrue([_editor.faceControl isEnabledForSegment:VibeEQEditorFaceGraphic]);
    XCTAssertFalse(curve.hidden);
    XCTAssertEqual(_ends, 1u);
}

- (void)testHostSettingsCallNoDelegate {
    _editor.settings = [self parametricSettings];
    _editor.face = VibeEQEditorFaceGraphic;
    _editor.settings = nil;
    XCTAssertEqualObjects(_editor.settings, [VibeListeningSettings neutralSettings]);
    XCTAssertEqual(_changes.count, 0u);
    XCTAssertEqual(_ends, 0u);
    XCTAssertEqual(_faceChanges, 0u);
}

#pragma mark - The graphic face

- (void)testDraggingASliderChangesLiveAndEndsOnce {
    _editor.settings = [self graphicSettings];
    VibeEQGraphicView *graphic = _editor.graphicView;
    NSPoint knob = [graphic knobCenterForSlider:2];
    NSRect plot = graphic.plotRect;
    CGFloat perDB = NSHeight(plot) / 24;
    [self dragIn:graphic
            from:knob
         through:@[
             [NSValue valueWithPoint:NSMakePoint(knob.x, knob.y + perDB * 2)],
             [NSValue valueWithPoint:NSMakePoint(knob.x + 30, knob.y + perDB * 4.2)],
         ]
           flags:0];
    XCTAssertEqual(_changes.count, 2u);
    XCTAssertEqual(_ends, 1u);
    XCTAssertEqual([graphic gainAtSlider:2], 4);
    XCTAssertTrue(_editor.settings.isGraphic);
    XCTAssertEqual(_editor.settings.bands[2].gainDB, 4);
    XCTAssertEqual(_editor.settings.bands[5].gainDB, 3);
    [self assertKeptTheRestOf:_editor.settings];
    XCTAssertEqual(graphic.draggedSlider, (NSUInteger)NSNotFound);
}

- (void)testAPressThatMovesNothingEndsNoEdit {
    _editor.settings = [self graphicSettings];
    VibeEQGraphicView *graphic = _editor.graphicView;
    [self dragIn:graphic from:[graphic knobCenterForSlider:5] through:@[] flags:0];
    XCTAssertEqual(_changes.count, 0u);
    XCTAssertEqual(_ends, 0u);
}

- (void)testASliderStopsAtTwelve {
    VibeEQGraphicView *graphic = _editor.graphicView;
    NSPoint knob = [graphic knobCenterForSlider:0];
    [self dragIn:graphic from:knob through:@[[NSValue valueWithPoint:NSMakePoint(knob.x, knob.y + 5000)]] flags:0];
    XCTAssertEqual([graphic gainAtSlider:0], 12);
    // A flat setting gains the graphic layout on its first edit.
    XCTAssertTrue(_editor.settings.isGraphic);
}

- (void)testDoubleClickResetsASlider {
    _editor.settings = [self graphicSettings];
    VibeEQGraphicView *graphic = _editor.graphicView;
    NSPoint knob = [graphic knobCenterForSlider:5];
    [graphic mouseDown:[self mouse:NSEventTypeLeftMouseDown at:knob in:graphic flags:0 clicks:2]];
    XCTAssertEqual([graphic gainAtSlider:5], 0);
    XCTAssertEqual(_changes.count, 1u);
    XCTAssertEqual(_ends, 1u);
    XCTAssertEqual(_editor.settings.bands[5].gainDB, 0);
}

- (void)testKeysMoveTheFocusedSlider {
    _editor.settings = [self graphicSettings];
    VibeEQGraphicView *graphic = _editor.graphicView;
    XCTAssertTrue([_window makeFirstResponder:graphic]);
    graphic.focusedSlider = 5;
    [graphic keyDown:[self key:NSUpArrowFunctionKey flags:NSEventModifierFlagFunction]];
    XCTAssertEqual([graphic gainAtSlider:5], 3.5);
    [graphic keyDown:[self key:NSRightArrowFunctionKey flags:NSEventModifierFlagFunction]];
    XCTAssertEqual(graphic.focusedSlider, 6u);
    [graphic keyDown:[self key:NSDownArrowFunctionKey flags:NSEventModifierFlagFunction]];
    XCTAssertEqual([graphic gainAtSlider:6], -0.5);
    [graphic keyDown:[self key:'0' flags:0]];
    XCTAssertEqual([graphic gainAtSlider:6], 0);
    XCTAssertEqual(_changes.count, 3u);
    XCTAssertEqual(_ends, 3u);
}

#pragma mark - The parametric face

- (void)testNodesHitTestAtTheirCenters {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    for (NSUInteger i = 0; i < 3; i++) {
        NSPoint center = [curve nodeCenterForBandAtIndex:i];
        XCTAssertEqual([curve nodeIndexAtPoint:center], i);
        XCTAssertEqual([curve nodeIndexAtPoint:NSMakePoint(center.x + 6, center.y - 6)], i);
    }
    XCTAssertEqual([curve nodeIndexAtPoint:NSMakePoint(NSMidX(curve.plotRect), NSMinY(curve.plotRect) + 2)],
                   (NSUInteger)NSNotFound);
    // A pass filter's node sits on 0 dB at its frequency.
    NSRect plot = curve.plotRect;
    NSPoint pass = [curve nodeCenterForBandAtIndex:0];
    XCTAssertEqualWithAccuracy(pass.x, VibeEQXForFrequency(30, NSMinX(plot), NSWidth(plot)), 1e-9);
    XCTAssertEqualWithAccuracy(pass.y, NSMidY(plot), 1e-9);
}

- (void)testTheSelectedNodeWinsAnOverlap {
    [self showParametric:[self settingsWithBands:@[
        [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:1000 gainDB:3 q:1],
        [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:1000 gainDB:3 q:2],
    ]]];
    VibeEQCurveView *curve = _editor.curveView;
    NSPoint center = [curve nodeCenterForBandAtIndex:0];
    XCTAssertEqual([curve nodeIndexAtPoint:center], 1u);
    curve.selectedIndex = 0;
    XCTAssertEqual([curve nodeIndexAtPoint:center], 0u);
}

- (void)testClickingEmptySpaceClearsGraphFocus {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSPoint node = [curve nodeCenterForBandAtIndex:1];
    [curve mouseDown:[self mouse:NSEventTypeLeftMouseDown at:node in:curve flags:0 clicks:1]];
    XCTAssertEqual(_window.firstResponder, curve);
    XCTAssertEqual(curve.selectedIndex, 1u);
    NSPoint blank = NSMakePoint(NSMidX(curve.plotRect), NSMinY(curve.plotRect) + 2);
    [curve mouseDown:[self mouse:NSEventTypeLeftMouseDown at:blank in:curve flags:0 clicks:1]];
    XCTAssertEqual(curve.selectedIndex, (NSUInteger)NSNotFound);
    XCTAssertNotEqual(_window.firstResponder, curve);
    XCTAssertTrue(NSIsEmptyRect(curve.focusRingMaskBounds));
}

- (void)testDoubleClickAddsAPeakAtThePointerAndItsMenuRemovesThatBand {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSRect plot = curve.plotRect;
    NSPoint point = NSMakePoint(VibeEQXForFrequency(800, NSMinX(plot), NSWidth(plot)),
                                VibeEQYForGain(-6, NSMinY(plot), NSHeight(plot), curve.rangeDB));
    NSEvent *add = [self mouse:NSEventTypeLeftMouseDown at:point in:curve flags:0 clicks:2];
    [curve mouseDown:add];
    NSArray *bands = _editor.settings.bands;
    XCTAssertEqual(bands.count, 4u);
    VibeEQBand *added = bands.lastObject;
    XCTAssertEqual(added.type, VibeEQBandTypePeak);
    XCTAssertEqual(added.frequency, 800);
    XCTAssertEqualWithAccuracy(added.gainDB, -6, 0.001);
    XCTAssertEqual(curve.selectedIndex, 3u);
    XCTAssertEqual(_ends, 1u);
    [curve mouseDown:add];
    XCTAssertEqual(_editor.settings.bands.count, 4u);

    _editor.selectedBandIndex = 0;
    NSEvent *click = [self mouse:NSEventTypeRightMouseDown at:point in:curve flags:0 clicks:1];
    NSMenuItem *remove = [curve menuForEvent:click].itemArray.firstObject;
    XCTAssertEqualObjects(remove.title, _editor.strings.removeBand);
    XCTAssertEqual(curve.selectedIndex, 3u);
    [NSApp sendAction:remove.action to:remove.target from:remove];
    XCTAssertEqualObjects(_editor.settings, [self parametricSettings]);
    XCTAssertEqual(_ends, 2u);
    XCTAssertNil([curve menuForEvent:click]);
    _editor.enabled = NO;
    [curve mouseDown:add];
    XCTAssertEqual(_editor.settings.bands.count, 3u);
}

- (void)testDraggingANodeMovesItsFrequencyAndGain {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSRect plot = curve.plotRect;
    NSPoint node = [curve nodeCenterForBandAtIndex:1];
    NSPoint to = NSMakePoint(node.x + 50, node.y + 25);
    [curve mouseDown:[self mouse:NSEventTypeLeftMouseDown at:node in:curve flags:0 clicks:1]];
    XCTAssertTrue(NSIsEmptyRect(curve.focusRingMaskBounds));
    [curve mouseDragged:[self mouse:NSEventTypeLeftMouseDragged at:to in:curve flags:0 clicks:1]];
    XCTAssertTrue(NSIsEmptyRect(curve.focusRingMaskBounds));
    [curve mouseUp:[self mouse:NSEventTypeLeftMouseUp at:to in:curve flags:0 clicks:1]];
    XCTAssertTrue(NSPointInRect([curve nodeCenterForBandAtIndex:1], curve.focusRingMaskBounds));
    VibeEQBand *band = _editor.settings.bands[1];
    XCTAssertEqual(band.frequency, VibeEQRoundFrequency(VibeEQFrequencyForX(to.x, NSMinX(plot), NSWidth(plot))));
    XCTAssertEqualWithAccuracy(band.gainDB,
                               VibeEQSnapGain(VibeEQGainForY(to.y, NSMinY(plot), NSHeight(plot), 12), 0.1, 24), 1e-9);
    XCTAssertEqual(band.q, 1.4);
    XCTAssertEqual(band.type, VibeEQBandTypePeak);
    XCTAssertEqual(_changes.count, 1u);
    XCTAssertEqual(_ends, 1u);
    XCTAssertEqual(curve.selectedIndex, 1u);
    XCTAssertEqual(_editor.bandList.tableView.selectedRow, 1);
    [self assertKeptTheRestOf:_editor.settings];
}

- (void)testDraggingAPassFilterMovesOnlyItsFrequency {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSPoint node = [curve nodeCenterForBandAtIndex:0];
    [self dragIn:curve from:node through:@[[NSValue valueWithPoint:NSMakePoint(node.x + 20, node.y + 60)]] flags:0];
    VibeEQBand *band = _editor.settings.bands[0];
    XCTAssertGreaterThan(band.frequency, 30);
    XCTAssertEqual(band.gainDB, 0);
}

- (void)testOptionDragChangesOnlyQ {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSPoint node = [curve nodeCenterForBandAtIndex:1];
    [self dragIn:curve
            from:node
         through:@[[NSValue valueWithPoint:NSMakePoint(node.x + 30, node.y + 60)]]
           flags:NSEventModifierFlagOption];
    VibeEQBand *band = _editor.settings.bands[1];
    XCTAssertEqualWithAccuracy(band.q, 2.8, 1e-9);
    XCTAssertEqual(band.frequency, 1000);
    XCTAssertEqual(band.gainDB, 3);
    XCTAssertEqual(_ends, 1u);
}

- (void)testTheAxisWidensForABoostPastTwelveAndHoldsThroughTheDrag {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    XCTAssertEqual(curve.rangeDB, 12);
    NSPoint node = [curve nodeCenterForBandAtIndex:1];
    CGFloat top = NSMaxY(curve.plotRect);
    [curve mouseDown:[self mouse:NSEventTypeLeftMouseDown at:node in:curve flags:0 clicks:1]];
    [curve mouseDragged:[self mouse:NSEventTypeLeftMouseDragged at:NSMakePoint(node.x, top + 30) in:curve flags:0 clicks:1]];
    XCTAssertGreaterThan(_editor.settings.bands[1].gainDB, 12);
    XCTAssertEqual(curve.rangeDB, 24);
    // Back down mid-drag, the axis stays wide, so the node stays under the
    // pointer.
    [curve mouseDragged:[self mouse:NSEventTypeLeftMouseDragged at:node in:curve flags:0 clicks:1]];
    XCTAssertLessThan(_editor.settings.bands[1].gainDB, 12);
    XCTAssertEqual(curve.rangeDB, 24);
    [curve mouseUp:[self mouse:NSEventTypeLeftMouseUp at:node in:curve flags:0 clicks:1]];
    XCTAssertEqual(curve.rangeDB, 12);
    XCTAssertEqual(_ends, 1u);
}

- (void)testCombinedResponseFollowsEachCopyOfTheSameBand {
    VibeEQBand *boost = [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:1000 gainDB:8 q:1];
    VibeEQBand *off = [boost bandWithEnabled:NO];
    VibeEQCurveView *curve = _editor.curveView;
    [self showParametric:[self settingsWithBands:@[boost, boost]]];
    XCTAssertEqual(curve.rangeDB, 24);
    _editor.settings = [self settingsWithBands:@[boost, off]];
    XCTAssertEqual(curve.rangeDB, 12);
    _editor.settings = [self settingsWithBands:@[off, boost, boost]];
    XCTAssertEqual(curve.rangeDB, 24);
    _editor.settings = [self settingsWithBands:@[boost]];
    XCTAssertEqual(curve.rangeDB, 12);
}

- (void)testChangingOnlyThePlaybackRateRedrawsTheCombinedResponse {
    NSArray *bands = @[[VibeEQBand bandWithType:VibeEQBandTypePeak frequency:8000 gainDB:11 q:1.41],
                       [VibeEQBand bandWithType:VibeEQBandTypePeak frequency:16000 gainDB:11 q:1.41]];
    [self showParametric:[self settingsWithBands:bands]];
    // Their combined boost rises from 11.9 dB at 48 kHz to 12.9 dB at 96 kHz.
    XCTAssertEqual(_editor.curveView.rangeDB, 12);
    _editor.sampleRate = 96000;
    XCTAssertEqual(_editor.curveView.rangeDB, 24);
    _editor.sampleRate = 48000;
    XCTAssertEqual(_editor.curveView.rangeDB, 12);
}

- (void)testKeysMoveTheSelectedNode {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    XCTAssertTrue([_window makeFirstResponder:curve]);
    XCTAssertEqual(curve.selectedIndex, 0u);
    [curve keyDown:[self key:NSTabCharacter flags:0]];
    XCTAssertEqual(curve.selectedIndex, 1u);
    [curve keyDown:[self key:NSUpArrowFunctionKey flags:NSEventModifierFlagFunction]];
    XCTAssertEqual(_editor.settings.bands[1].gainDB, 3.5);
    [curve keyDown:[self key:NSRightArrowFunctionKey flags:NSEventModifierFlagFunction | NSEventModifierFlagShift]];
    XCTAssertEqual(_editor.settings.bands[1].frequency, 1260);
    [curve keyDown:[self key:NSUpArrowFunctionKey flags:NSEventModifierFlagFunction | NSEventModifierFlagOption]];
    XCTAssertEqualWithAccuracy(_editor.settings.bands[1].q, 1.5, 1e-9);
    XCTAssertEqual(_ends, 3u);
    [curve keyDown:[self key:NSDeleteCharacter flags:0]];
    XCTAssertEqual(_editor.settings.bands.count, 2u);
    XCTAssertEqual(curve.selectedIndex, 1u);
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 2);
    XCTAssertEqual(_ends, 4u);
}

- (void)testTypingInAFieldIsOneEdit {
    [self showParametric:[self parametricSettings]];
    NSTableView *table = _editor.bandList.tableView;
    XCTAssertEqual(table.numberOfRows, 3);
    NSTableCellView *cell = [table viewAtColumn:2 row:1 makeIfNecessary:YES];
    NSTextField *field = cell.textField;
    XCTAssertEqualObjects(field.stringValue, @"1000");
    field.stringValue = @"2.5k";
    [self fire:field];
    XCTAssertEqual(_editor.settings.bands[1].frequency, 2500);
    XCTAssertEqual(_changes.count, 1u);
    XCTAssertEqual(_ends, 1u);

    NSTextField *gain = [(NSTableCellView *)[table viewAtColumn:3 row:1 makeIfNecessary:YES] textField];
    XCTAssertEqualObjects(gain.stringValue, @"3.0");
    gain.stringValue = @"-30";
    [self fire:gain];
    XCTAssertEqual(_editor.settings.bands[1].gainDB, -24);

    // A word that holds no number puts the value back and changes nothing.
    NSTextField *q = [(NSTableCellView *)[table viewAtColumn:4 row:1 makeIfNecessary:YES] textField];
    q.stringValue = @"wide";
    [self fire:q];
    XCTAssertEqual(_changes.count, 2u);
    XCTAssertEqualObjects([(NSTableCellView *)[table viewAtColumn:4 row:1 makeIfNecessary:YES] textField].stringValue,
                          @"1.4");

    // A pass filter has no gain to type.
    NSTextField *passGain = [(NSTableCellView *)[table viewAtColumn:3 row:0 makeIfNecessary:YES] textField];
    XCTAssertFalse(passGain.isEditable);
}

- (void)testTheTypeAndSwitchEditABand {
    [self showParametric:[self parametricSettings]];
    NSTableView *table = _editor.bandList.tableView;
    NSPopUpButton *type = [table viewAtColumn:1 row:1 makeIfNecessary:YES];
    [type selectItemAtIndex:VibeEQBandTypeLowShelf];
    [self fire:type];
    XCTAssertEqual(_editor.settings.bands[1].type, VibeEQBandTypeLowShelf);
    XCTAssertEqual(_editor.settings.bands[1].frequency, 1000);

    NSTableCellView *onCell = [table viewAtColumn:0 row:2 makeIfNecessary:YES];
    XCTAssertEqualObjects(onCell.textField.stringValue, @"3");
    VibeSwitch *on = [onCell.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self isKindOfClass: %@",
                                                                                                   VibeSwitch.class]]
                         .firstObject;
    XCTAssertEqual(on.state, NSControlStateValueOn);
    XCTAssertEqualObjects(on.accessibilityLabel, @"Band 3");
    on.state = NSControlStateValueOff;
    [self fire:on];
    XCTAssertFalse(_editor.settings.bands[2].enabled);
    XCTAssertEqual(_ends, 2u);
}

- (void)testAddAndRemoveBands {
    [self showParametric:[self parametricSettings]];
    VibeEQBandListView *list = _editor.bandList;
    XCTAssertFalse(list.removeButton.isEnabled);
    [self fire:list.addButton];
    XCTAssertEqual(_editor.settings.bands.count, 4u);
    VibeEQBand *added = _editor.settings.bands[3];
    XCTAssertEqual(added.type, VibeEQBandTypePeak);
    XCTAssertEqual(added.gainDB, 0);
    // In the widest gap on the log axis: between 30 Hz and 1 kHz.
    XCTAssertGreaterThan(added.frequency, 30);
    XCTAssertLessThan(added.frequency, 1000);
    XCTAssertEqual(list.tableView.selectedRow, 3);
    XCTAssertEqual(_editor.curveView.selectedIndex, 3u);
    XCTAssertEqual(_ends, 1u);

    list.selectedIndex = 1;
    XCTAssertTrue(list.removeButton.isEnabled);
    [self fire:list.removeButton];
    XCTAssertEqual(_editor.settings.bands.count, 3u);
    XCTAssertEqual(_editor.settings.bands[1].type, VibeEQBandTypeHighShelf);
    XCTAssertEqual(_ends, 2u);

    while (_editor.settings.bands.count < kVibeListeningMaxBands) {
        [self fire:list.addButton];
    }
    XCTAssertFalse(list.addButton.isEnabled);
    [self fire:list.addButton];
    XCTAssertEqual(_editor.settings.bands.count, kVibeListeningMaxBands);
}

#pragma mark - Disabled and hidden

- (void)testDisabledDimsAndIgnoresInput {
    _editor.settings = [self graphicSettings];
    _editor.enabled = NO;
    XCTAssertEqual(_editor.graphicView.alphaValue, 0.5);
    XCTAssertNil([_editor hitTest:NSMakePoint(320, 200)]);
    XCTAssertFalse(_editor.graphicView.acceptsFirstResponder);
    XCTAssertFalse(_editor.faceControl.isEnabled);
    VibeEQGraphicView *graphic = _editor.graphicView;
    NSPoint knob = [graphic knobCenterForSlider:5];
    [self dragIn:graphic from:knob through:@[[NSValue valueWithPoint:NSMakePoint(knob.x, knob.y + 50)]] flags:0];
    XCTAssertFalse([graphic.sliderElements[5] accessibilityPerformIncrement]);
    [self showParametric:[self parametricSettings]];
    NSPoint node = [_editor.curveView nodeCenterForBandAtIndex:1];
    [self dragIn:_editor.curveView from:node through:@[[NSValue valueWithPoint:NSMakePoint(node.x + 50, node.y)]] flags:0];
    [self fire:_editor.bandList.addButton];
    XCTAssertEqual(_changes.count, 0u);
    XCTAssertEqual(_ends, 0u);

    _editor.enabled = YES;
    XCTAssertEqual(_editor.curveView.alphaValue, 1);
    XCTAssertNotNil([_editor hitTest:NSMakePoint(320, 200)]);
}

- (void)testAHiddenListFillsOnlyWhenShown {
    _editor.face = VibeEQEditorFaceParametric;
    _editor.hidden = YES;
    _editor.settings = [self parametricSettings];
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 0);
    _editor.hidden = NO;
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 3);

    // Behind the graphic face, too.
    _editor.settings = nil;
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 0);
    _editor.face = VibeEQEditorFaceGraphic;
    _editor.settings = [self graphicSettings];
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 0);
    _editor.face = VibeEQEditorFaceParametric;
    XCTAssertEqual(_editor.bandList.tableView.numberOfRows, 10);
}

#pragma mark - Accessibility

- (void)testEachSliderSpeaksItsFrequencyAndGain {
    _editor.settings = [self graphicSettings];
    NSArray<VibeEQAccessibilitySlider *> *sliders = _editor.graphicView.sliderElements;
    XCTAssertEqual(sliders.count, 10u);
    XCTAssertEqualObjects(_editor.graphicView.accessibilityChildren, sliders);
    XCTAssertEqualObjects(sliders[0].accessibilityRole, NSAccessibilitySliderRole);
    XCTAssertEqualObjects(sliders[0].accessibilityLabel, @"31 Hz");
    XCTAssertEqualObjects(sliders[5].accessibilityLabel, @"1,000 Hz");
    XCTAssertEqualObjects(sliders[9].accessibilityLabel, @"16,000 Hz");
    XCTAssertEqualObjects(sliders[5].accessibilityValue, @"+3.0 dB");
    XCTAssertEqualObjects(sliders[0].accessibilityValue, @"0.0 dB");
    XCTAssertTrue([sliders[5] accessibilityPerformIncrement]);
    XCTAssertEqualObjects(sliders[5].accessibilityValue, @"+3.5 dB");
    XCTAssertTrue([sliders[0] accessibilityPerformDecrement]);
    XCTAssertEqualObjects(sliders[0].accessibilityValue, @"-0.5 dB");
    XCTAssertEqual(_ends, 2u);
    XCTAssertFalse(NSIsEmptyRect(sliders[3].accessibilityFrame));
}

- (void)testEachNodeIsAnAdjustableElement {
    [self showParametric:[self parametricSettings]];
    NSArray<VibeEQAccessibilitySlider *> *nodes = _editor.curveView.nodeElements;
    XCTAssertEqual(nodes.count, 3u);
    XCTAssertEqualObjects(nodes[1].accessibilityRole, NSAccessibilitySliderRole);
    XCTAssertEqualObjects(nodes[1].accessibilityLabel, @"Band 2");
    XCTAssertEqualObjects(nodes[1].accessibilityValue, @"1,000 Hz, +3.0 dB, Q 1.4");
    XCTAssertEqualObjects(nodes[0].accessibilityValue, @"30 Hz, Q 0.71");
    XCTAssertEqualObjects(nodes[2].accessibilityValue, @"8,000 Hz, -4.0 dB, Q 0.70");
    XCTAssertTrue([nodes[1] accessibilityPerformIncrement]);
    XCTAssertEqualObjects(nodes[1].accessibilityValue, @"1,000 Hz, +3.5 dB, Q 1.4");
    XCTAssertTrue([nodes[0] accessibilityPerformIncrement]);
    XCTAssertGreaterThan(_editor.settings.bands[0].frequency, 30);
    XCTAssertEqual(_ends, 2u);

    // A band added makes its node.
    [self fire:_editor.bandList.addButton];
    XCTAssertEqual(_editor.curveView.nodeElements.count, 4u);
}

- (void)testEveryFieldHasAName {
    [self showParametric:[self parametricSettings]];
    NSTableView *table = _editor.bandList.tableView;
    NSTableCellView *frequency = [table viewAtColumn:2 row:0 makeIfNecessary:YES];
    XCTAssertEqualObjects(frequency.textField.accessibilityLabel, @"Band 1, Hz");
    NSPopUpButton *type = [table viewAtColumn:1 row:2 makeIfNecessary:YES];
    XCTAssertEqualObjects(type.accessibilityLabel, @"Band 3, Type");
    XCTAssertEqualObjects(_editor.bandList.addButton.accessibilityLabel, @"Add Band");
}

#pragma mark - Drawing

- (NSColor *)accentIn:(NSAppearance *)appearance {
    __block NSColor *color;
    [appearance performAsCurrentDrawingAppearance:^{
        color = [NSColor.controlAccentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return color;
}

- (void)testBandNumberContrastsWithItsFill {
    [self showParametric:[self parametricSettings]];
    VibeEQCurveView *curve = _editor.curveView;
    NSPoint node = [curve nodeCenterForBandAtIndex:1];
    for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        _window.appearance = [NSAppearance appearanceNamed:name];
        for (NSColor *accent in @[NSColor.whiteColor, NSColor.yellowColor, NSColor.blueColor]) {
            _editor.accentColor = accent;
            NSBitmapImageRep *rep = VibeRenderView(curve);
            NSColor *ink = [accent isEqual:NSColor.blueColor] ? NSColor.whiteColor : NSColor.blackColor;
            XCTAssertTrue(VibeColorsClose(VibePixel(rep, NO, node.x - 4, node.y), accent, 0.08));
            // Only the numeral can draw the contrasting color this far inside the circle.
            NSUInteger inkPixels = 0;
            for (NSInteger dy = -3; dy <= 3; dy++) {
                for (NSInteger dx = -2; dx <= 2; dx++) {
                    if (VibeColorsClose(VibePixel(rep, NO, node.x + dx, node.y + dy), ink, 0.35)) inkPixels++;
                }
            }
            XCTAssertGreaterThan(inkPixels, 2u, @"%@, %@", name, accent);
        }
    }
}

- (void)testDrawsInBothAppearances {
    NSColor *plotBackgrounds[2];
    int index = 0;
    for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        NSAppearance *appearance = [NSAppearance appearanceNamed:name];
        _window.appearance = appearance;
        _editor.settings = [self graphicSettings];
        _editor.face = VibeEQEditorFaceGraphic;
        [_editor layoutSubtreeIfNeeded];

        // The sixth slider's fill, between 0 dB and its +3 dB knob, is the accent.
        VibeEQGraphicView *graphic = _editor.graphicView;
        NSBitmapImageRep *rep = VibeRenderView(graphic);
        NSPoint knob = [graphic knobCenterForSlider:5];
        CGFloat zero = NSMidY(graphic.plotRect);
        NSColor *fill = VibePixel(rep, NO, knob.x, (knob.y + zero) / 2 - 3);
        XCTAssertTrue(VibeColorsClose(fill, [self accentIn:appearance], 0.08), @"%@: %@", name, fill);
        NSColor *custom = [NSColor colorWithSRGBRed:0.8 green:0.15 blue:0.4 alpha:1];
        _editor.accentColor = custom;
        rep = VibeRenderView(graphic);
        XCTAssertTrue(VibeColorsClose(VibePixel(rep, NO, knob.x, (knob.y + zero) / 2 - 3), custom, 0.08));

        [self showParametric:[self parametricSettings]];
        VibeEQCurveView *curve = _editor.curveView;
        rep = VibeRenderView(curve);
        NSPoint node = [curve nodeCenterForBandAtIndex:1];
        XCTAssertTrue(VibeColorsClose(VibePixel(rep, NO, node.x - 4, node.y), custom, 0.08));
        _editor.accentColor = nil;
        rep = VibeRenderView(curve);
        XCTAssertTrue(VibeColorsClose(VibePixel(rep, NO, node.x - 4, node.y), [self accentIn:appearance], 0.08));
        plotBackgrounds[index++] = VibePixel(rep, NO, NSMinX(curve.plotRect) + 3, NSMaxY(curve.plotRect) - 3);
        XCTAssertFalse(VibeBitmapIsBlank(VibeRenderView(_editor.bandList)));
    }
    // The plot's tint follows the appearance.
    XCTAssertFalse(VibeColorsClose(plotBackgrounds[0], plotBackgrounds[1], 0.01));
}

// TRAP: AppKit hosts some controls in SwiftUI on macOS 26, with a Metal
// startup cost. ui/Controls' AGENTS.md has the rule.
- (void)testNoControlIsHostedInSwiftUI {
    [self showParametric:[self parametricSettings]];
    [_editor.bandList.tableView layoutSubtreeIfNeeded];
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:_editor];
    while (views.count > 0) {
        NSView *view = views.lastObject;
        [views removeLastObject];
        XCTAssertFalse([NSStringFromClass(view.class) containsString:@"HostingView"], @"%@", view);
        [views addObjectsFromArray:view.subviews];
    }
}

@end
