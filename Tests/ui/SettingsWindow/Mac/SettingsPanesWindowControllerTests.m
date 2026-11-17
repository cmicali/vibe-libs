//
//  SettingsPanesWindowControllerTests.m
//  SettingsWindowTests
//
//  The generic window over two panes, never shown: the sidebar drives the
//  selection, the title follows the pane, Back and Forward walk the history,
//  and the search narrows the sidebar.
//

#import <XCTest/XCTest.h>
#import "DrawnControls.h"
#import "SettingsPanesWindowController.h"
#import "SettingsPaneViewController.h"
#import "SettingsSidebarController.h"
#import "VibeDetentSlider.h"

// A pane of one titled row around one control.
@interface SettingsTestPane : SettingsPaneViewController
@property (nonatomic, copy) NSString *rowTitle;
@property (nonatomic, copy, nullable) NSString *rowCaption;
@property (nonatomic, readonly) SettingsRowView *row;
@property (nonatomic, strong) NSView *control;
@end

@implementation SettingsTestPane

- (void)loadView {
    SettingsRowView *row = [SettingsRowView rowWithTitle:self.rowTitle caption:self.rowCaption
                                                 control:self.control];
    _row = row;
    [self loadPaneWithSections:@[[SettingsSectionView sectionWithRows:@[row]]]];
}

@end

@interface SettingsPanesWindowControllerTests : XCTestCase
@end

@implementation SettingsPanesWindowControllerTests {
    SettingsPanesWindowController *_controller;
    NSMutableArray<NSNumber *> *_effects;
}

- (SettingsTestPane *)paneWithRowTitle:(NSString *)title control:(NSView *)control {
    NSMutableArray<NSNumber *> *effects = _effects;
    SettingsTestPane *pane = [[SettingsTestPane alloc] initWithEffectsSink:^(NSUInteger bits) {
        [effects addObject:@(bits)];
    }];
    pane.rowTitle = title;
    pane.control = control;
    return pane;
}

- (void)setUp {
    _effects = [NSMutableArray array];
    _controller = [self controllerOpeningOn:nil];
}

- (SettingsPanesWindowController *)controllerOpeningOn:(NSString *)identifier {
    NSTabViewItem *general = [SettingsPanesWindowController
            paneItemWithViewController:[self paneWithRowTitle:@"Dark mode" control:[[VibeSwitch alloc] init]]
                            identifier:@"general" label:@"General" symbolName:@"gearshape"];
    NSTabViewItem *sound = [SettingsPanesWindowController
            paneItemWithViewController:[self paneWithRowTitle:@"Volume" control:[[VibeDetentSlider alloc] init]]
                            identifier:@"sound" label:@"Sound" symbolName:@"speaker.wave.2"];
    if (!identifier) {
        return [[SettingsPanesWindowController alloc]
                initWithPaneGroups:@[@[general], @[sound]]
                         backTitle:@"Back" forwardTitle:@"Forward" undoTitle:@"Undo" redoTitle:@"Redo"
                 searchPlaceholder:@"Search" noResultsText:@"No Results"];
    }
    return [[SettingsPanesWindowController alloc]
            initWithPaneGroups:@[@[general], @[sound]] initialPaneIdentifier:identifier
                     backTitle:@"Back" forwardTitle:@"Forward" undoTitle:@"Undo" redoTitle:@"Redo"
             searchPlaceholder:@"Search" noResultsText:@"No Results"];
}

- (void)tearDown {
    [_controller.window close];
    _controller = nil;
}

- (SettingsSidebarController *)sidebar {
    NSSplitViewController *split = (NSSplitViewController *)_controller.window.contentViewController;
    return (SettingsSidebarController *)split.splitViewItems.firstObject.viewController;
}

- (void)testTheFirstPaneOpensSelectedAndTitled {
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"general");
    XCTAssertEqualObjects(_controller.window.title, @"General");
    XCTAssertEqualObjects(_controller.currentLocation, @"general");
    XCTAssertFalse([_controller canNavigateForward:NO]);
    XCTAssertFalse([_controller canNavigateForward:YES]);
    XCTAssertFalse(_controller.window.isVisible);
}

// The window opens on the pane named, and the history starts there.
- (void)testTheWindowOpensOnTheNamedPane {
    [_controller.window close];
    _controller = [self controllerOpeningOn:@"sound"];
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"sound");
    XCTAssertEqualObjects(_controller.window.title, @"Sound");
    XCTAssertEqualObjects(_controller.currentLocation, @"sound");
    XCTAssertFalse([_controller canNavigateForward:NO]);
    XCTAssertFalse([_controller canNavigateForward:YES]);
    NSTableView *table = [self sidebar].tableView;
    // Row 1 is the group's spacer.
    XCTAssertEqual(table.selectedRow, 2);
    NSView *pane = _controller.selectedTabItem.viewController.view;
    XCTAssertNotNil(pane.superview);
    XCTAssertGreaterThan(NSHeight(pane.frame), 0);

    // The first move away is the first thing Back holds.
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    XCTAssertEqualObjects(_controller.currentLocation, @"general");
    XCTAssertTrue([_controller canNavigateForward:NO]);
    [_controller navigateForward:NO];
    XCTAssertEqualObjects(_controller.currentLocation, @"sound");
    XCTAssertFalse([_controller canNavigateForward:NO]);
}

- (void)testAnUnknownInitialPaneOpensTheFirst {
    [_controller.window close];
    _controller = [self controllerOpeningOn:@"gone"];
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"general");
    XCTAssertEqualObjects(_controller.window.title, @"General");
    XCTAssertEqualObjects(_controller.currentLocation, @"general");
    XCTAssertFalse([_controller canNavigateForward:NO]);
}

// What a debug walker reads of the sidebar, with no reach into the split view.
- (void)testTheWindowAnswersTheSidebarsSearchAndRows {
    XCTAssertEqualObjects(_controller.searchText, @"");
    XCTAssertEqualObjects(_controller.visiblePaneIdentifiers, (@[@"general", @"sound"]));
    [_controller searchSettingsFor:@"volu"];
    XCTAssertEqualObjects(_controller.searchText, @"volu");
    XCTAssertEqualObjects(_controller.visiblePaneIdentifiers, @[@"sound"]);
    [_controller searchSettingsFor:@""];
    XCTAssertEqualObjects(_controller.visiblePaneIdentifiers, (@[@"general", @"sound"]));
}

- (void)testAWindowWithNoNameSavesNoFrame {
    XCTAssertEqual(_controller.windowFrameAutosaveName.length, 0u);
    XCTAssertEqual(_controller.window.frameAutosaveName.length, 0u);
}

- (void)testTheSidebarGroupsPanesWithASpacer {
    // General, the spacer before Sound's group, and Sound.
    XCTAssertEqual(self.sidebar.tableView.numberOfRows, 3);
    XCTAssertEqualObjects(self.sidebar.visiblePaneIdentifiers, (@[@"general", @"sound"]));
}

- (void)testPickingASidebarRowSelectsItsPane {
    [self.sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"sound");
    XCTAssertEqualObjects(_controller.window.title, @"Sound");
    XCTAssertTrue([_controller canNavigateForward:NO]);
}

- (void)testBackAndForwardWalkTheHistory {
    [self.sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    [_controller navigateForward:NO];
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"general");
    XCTAssertEqual(self.sidebar.tableView.selectedRow, 0);
    XCTAssertTrue([_controller canNavigateForward:YES]);
    [_controller navigateForward:YES];
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"sound");
    XCTAssertFalse([_controller canNavigateForward:YES]);
}

- (void)testSearchNarrowsTheSidebarToMatchingPanes {
    XCTAssertEqualObjects([_controller searchSettingsFor:@"volume"], @[@"sound"]);
    XCTAssertEqualObjects(_controller.selectedTabItem.identifier, @"sound");
    XCTAssertEqualObjects([_controller searchSettingsFor:@"general"], @[@"general"]);
    XCTAssertEqualObjects([_controller searchSettingsFor:@"nothing here"], @[]);
    XCTAssertEqualObjects([_controller searchSettingsFor:@""], (@[@"general", @"sound"]));
}

- (void)testAPaneRequestsEffectsThroughItsSink {
    SettingsPaneViewController *pane =
            (SettingsPaneViewController *)[_controller tabItemWithIdentifier:@"sound"].viewController;
    [pane applyLiveEffects:5];
    XCTAssertEqualObjects(_effects, @[@5]);
}

- (void)testEveryPaneSharesOneSize {
    NSSize general = ((SettingsPaneViewController *)
            [_controller tabItemWithIdentifier:@"general"].viewController).sharedPaneSize;
    NSSize sound = ((SettingsPaneViewController *)
            [_controller tabItemWithIdentifier:@"sound"].viewController).sharedPaneSize;
    XCTAssertTrue(NSEqualSizes(general, sound));
    XCTAssertGreaterThanOrEqual(general.width, kSettingsPaneWidth);
    XCTAssertGreaterThanOrEqual(general.height, kSettingsPaneMinHeight);
}

// A caption too long for the design width wraps, and leaves every pane at
// that width, whether it is there at the start or comes later.
- (void)testALongCaptionLeavesThePanesAtTheDesignWidth {
    NSString *caption = @"A caption long enough to run well past any card of the design width, so it "
            @"must wrap under its title rather than push the controls and every pane out with it.";
    SettingsTestPane *general = [self paneWithRowTitle:@"Dark mode" control:[[VibeSwitch alloc] init]];
    general.rowCaption = caption;
    SettingsTestPane *sound = [self paneWithRowTitle:@"Volume" control:[[VibeSwitch alloc] init]];
    [_controller.window close];
    _controller = [[SettingsPanesWindowController alloc]
            initWithPaneGroups:@[@[[SettingsPanesWindowController paneItemWithViewController:general
                    identifier:@"general" label:@"General" symbolName:@"gearshape"],
                                   [SettingsPanesWindowController paneItemWithViewController:sound
                    identifier:@"sound" label:@"Sound" symbolName:@"speaker.wave.2"]]]
                     backTitle:@"Back" forwardTitle:@"Forward" undoTitle:@"Undo" redoTitle:@"Redo"
             searchPlaceholder:@"Search" noResultsText:@"No Results"];
    XCTAssertEqualWithAccuracy(general.sharedPaneSize.width, kSettingsPaneWidth, 0.5);
    XCTAssertEqualWithAccuracy(sound.sharedPaneSize.width, kSettingsPaneWidth, 0.5);
    XCTAssertEqualWithAccuracy(_controller.window.contentView.frame.size.width,
                               200 + 1 + kSettingsPaneWidth, 1.5);

    [sound.row setCaption:caption];
    [SettingsPaneViewController settleSharedSizeForPanes:@[general, sound]];
    XCTAssertEqualWithAccuracy(sound.sharedPaneSize.width, kSettingsPaneWidth, 0.5);

    // Laid out, the caption has wrapped inside its card.
    [general.view layoutSubtreeIfNeeded];
    NSTextField *label = general.row.captionLabel;
    XCTAssertGreaterThan(NSHeight(label.frame),
                         1.5 * [label.cell cellSizeForBounds:NSMakeRect(0, 0, 10000, 10000)].height);
    XCTAssertLessThanOrEqual(NSMaxX(label.frame), NSWidth(general.row.frame));
}

@end
