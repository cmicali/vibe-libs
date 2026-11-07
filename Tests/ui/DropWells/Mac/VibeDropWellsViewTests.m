//
//  VibeDropWellsViewTests.m
//  DropWellsTests
//
//  The wells' geometry, hit-testing, light, blur, and stacking, in a window
//  kept off every display.
//

#import <XCTest/XCTest.h>

#import "VibeDropWellsView.h"

@interface VibeDropWellsViewTests : XCTestCase
@end

@implementation VibeDropWellsViewTests {
    NSWindow *_window;
    VibeDropWellsView *_view;
}

- (void)setUp {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 600, 400)
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:YES];
    _window.releasedWhenClosed = NO;
    _view = [[VibeDropWellsView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    _window.contentView = _view;
}

- (void)tearDown {
    [_window close];
    _window = nil;
}

- (NSArray<VibeDropWell *> *)wells:(NSUInteger)count {
    NSMutableArray<VibeDropWell *> *wells = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *name = [NSString stringWithFormat:@"w%lu", (unsigned long)i];
        [wells addObject:[VibeDropWell wellWithIdentifier:name title:name symbolName:@"plus"]];
    }
    return wells;
}

// The view's own coordinates are the window's, since it is the content view.
- (NSPoint)centerOf:(NSUInteger)index {
    NSRect rect = [_view rectOfWellAtIndex:index];
    return NSMakePoint(NSMidX(rect), NSMidY(rect));
}

- (void)testOneWellSpansTheInsetView {
    _view.wells = [self wells:1];
    XCTAssertTrue(NSEqualRects([_view rectOfWellAtIndex:0], NSMakeRect(20, 20, 560, 360)));
    XCTAssertTrue(NSEqualRects([_view rectOfWellAtIndex:1], NSZeroRect));
}

- (void)testTwoWellsSitSideBySideWithTheSlackInTheGap {
    _view.frame = NSMakeRect(0, 0, 601, 400);
    _view.wells = [self wells:2];
    // (561 - 16) / 2 = 272.5, floored, and the second anchors right.
    XCTAssertTrue(NSEqualRects([_view rectOfWellAtIndex:0], NSMakeRect(20, 20, 272, 360)));
    XCTAssertTrue(NSEqualRects([_view rectOfWellAtIndex:1], NSMakeRect(309, 20, 272, 360)));
}

- (void)testThreeWellsShareTheRow {
    _view.wells = [self wells:3];
    XCTAssertFalse(_view.stacked);
    NSRect first = [_view rectOfWellAtIndex:0];
    NSRect second = [_view rectOfWellAtIndex:1];
    NSRect third = [_view rectOfWellAtIndex:2];
    XCTAssertEqual(NSWidth(first), 176);
    XCTAssertEqual(NSMinX(second), NSMaxX(first) + 16);
    XCTAssertEqual(NSMaxX(third), 580);
    XCTAssertEqual(NSMinY(third), 20);
}

- (void)testWellsStackBelowTheirMinimumWidth {
    _view.wells = [self wells:3];
    _view.minimumWellWidth = 200;
    XCTAssertTrue(_view.stacked);
    NSRect top = [_view rectOfWellAtIndex:0];
    NSRect bottom = [_view rectOfWellAtIndex:2];
    XCTAssertEqual(NSWidth(top), 560);
    XCTAssertEqual(NSMaxY(top), 380, @"the first well is the top one");
    XCTAssertEqual(NSMinY(bottom), 20);
    XCTAssertGreaterThan(NSMinY(top), NSMaxY([_view rectOfWellAtIndex:1]));
    _view.minimumWellWidth = 0;
    XCTAssertFalse(_view.stacked, @"0 never stacks");
}

- (void)testTheDragLightsTheWellUnderThePointer {
    _view.wells = [self wells:2];
    XCTAssertFalse(_view.dragActive);
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:0]];
    XCTAssertTrue(_view.dragActive);
    XCTAssertEqualObjects(_view.hoveredIdentifier, @"w0");
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:1]];
    XCTAssertEqualObjects(_view.hoveredIdentifier, @"w1");
    [_view fileDragUpdatedAtWindowPoint:NSMakePoint(300, 5)];
    XCTAssertTrue(_view.dragActive, @"the margin keeps the wells");
    XCTAssertNil(_view.hoveredIdentifier);
    [_view fileDragEnded];
    XCTAssertFalse(_view.dragActive);
    XCTAssertNil(_view.hoveredIdentifier);
}

- (void)testTheDropReadsTheWellAfterTheDragEnds {
    _view.wells = [self wells:2];
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:1]];
    [_view fileDragEnded];
    XCTAssertEqualObjects([_view wellIdentifierAtWindowPoint:[self centerOf:1]], @"w1");
    XCTAssertNil([_view wellIdentifierAtWindowPoint:NSMakePoint(300, 5)]);
}

- (void)testAHiddenOrSquashedViewShowsNothing {
    _view.wells = [self wells:2];
    _view.hidden = YES;
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:0]];
    XCTAssertFalse(_view.dragActive);
    XCTAssertNil([_view wellIdentifierAtWindowPoint:[self centerOf:0]]);
    _view.hidden = NO;
    _view.frame = NSMakeRect(0, 0, 600, 60);
    XCTAssertFalse(_view.effectivelyVisible, @"too short for a well");
    [_view fileDragUpdatedAtWindowPoint:NSMakePoint(100, 30)];
    XCTAssertFalse(_view.dragActive);
}

- (void)testTheBlurShowsOnlyDuringADragWhenAsked {
    _view.wells = [self wells:2];
    NSView *blur = nil;
    for (NSView *subview in _view.subviews) {
        if ([subview isKindOfClass:NSVisualEffectView.class]) {
            blur = subview;
        }
    }
    XCTAssertNotNil(blur);
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:0]];
    XCTAssertTrue(blur.hidden, @"off by default");
    _view.showsBlur = YES;
    XCTAssertFalse(blur.hidden);
    [_view fileDragEnded];
    XCTAssertTrue(blur.hidden);
}

- (void)testNewWellsDropALightTheyNoLongerHold {
    _view.wells = [self wells:2];
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:1]];
    _view.wells = [self wells:1];
    XCTAssertNil(_view.hoveredIdentifier);
}

- (void)testTheWellsTakeNoClickAndDraw {
    _view.wells = [self wells:3];
    XCTAssertNil([_view hitTest:[self centerOf:0]]);
    [_view fileDragUpdatedAtWindowPoint:[self centerOf:0]];
    NSBitmapImageRep *rep = [_view bitmapImageRepForCachingDisplayInRect:_view.bounds];
    [_view cacheDisplayInRect:_view.bounds toBitmapImageRep:rep];
    XCTAssertNotNil(rep, @"it draws with a style of system colors");
}

@end
