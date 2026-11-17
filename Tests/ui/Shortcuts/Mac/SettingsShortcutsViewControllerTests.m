//
//  SettingsShortcutsViewControllerTests.m
//  ShortcutsTests
//
//  The Shortcuts pane over two rows and a store of the test's own, in a
//  window never shown. A key event sent through NSApp reaches the recorder's
//  monitor, as a real press does. Recording, clearing, and Reset All each
//  write through the pane's blocks.
//

#import <XCTest/XCTest.h>
#import "SettingsShortcutsViewController.h"
#import "ShortcutLayout.h"

static const NSEventModifierFlags kControlOption = NSEventModifierFlagControl | NSEventModifierFlagOption;

@interface SettingsShortcutsViewControllerTests : XCTestCase
@end

@implementation SettingsShortcutsViewControllerTests {
    NSMutableDictionary<NSString *, NSNumber *> *_store;
    NSMutableArray<NSString *> *_writes;
    SettingsShortcutsViewController *_pane;
    NSWindow *_window;
}

static __kindof NSView *_Nullable Find(NSView *view, Class kind, BOOL (^match)(id view)) {
    if ([view isKindOfClass:kind] && match(view)) {
        return view;
    }
    for (NSView *child in view.subviews) {
        NSView *found = Find(child, kind, match);
        if (found) {
            return found;
        }
    }
    return nil;
}

- (void)setUp {
    [NSApplication sharedApplication];
    VibeShortcutSetKeyNames(@"Space", @"Keypad %@", @"Key %ld", @"None");
    NSArray<NSArray *> *table = @[
        @[@"play", @(VibeShortcutMake(kVibeKeyCodeSpace, 0))],
        @[@"next", @(VibeShortcutMake(45, 0))],
    ];
    NSMutableDictionary<NSString *, NSNumber *> *store = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *writes = [NSMutableArray array];
    _store = store;
    _writes = writes;
    _pane = [[SettingsShortcutsViewController alloc]
            initWithEffectsSink:^(NSUInteger effects) {}
                    commandRows:^{ return @[@[@"Playback", @[@[@"play", @"Play"], @[@"next", @"Next"]]]]; }
             shortcutForCommand:^(NSString *identifier) { return VibeShortcutEffective(table, identifier, store); }
                      overrides:^{ return [store copy]; }
                   setOverrides:^(NSDictionary<NSString *, NSNumber *> *overrides) {
                       [writes addObject:[NSString stringWithFormat:@"set %lu", (unsigned long)overrides.count]];
                       [store setDictionary:overrides];
                   }
                         assign:^(VibeShortcut shortcut, NSString *identifier, NSString **loser) {
                             [writes addObject:[NSString stringWithFormat:@"assign %@ %lu", identifier,
                                                                          (unsigned long)shortcut]];
                             [store setDictionary:VibeShortcutOverridesByAssigning(table, store, identifier,
                                                                                   shortcut, 0, loser)];
                             return VibeShortcutAssignmentStored;
                         }];
    _pane.commandColumnTitle = @"Command";
    _pane.shortcutColumnTitle = @"Shortcut";
    _pane.recordTitle = @"Record";
    _pane.clearTitle = @"Clear";
    _pane.resetAllTitle = @"Reset All";
    _pane.explainer = @"Explainer";
    _pane.layoutNote = @"Layout";
    _pane.selectTip = @"Select";
    _pane.noneTip = @"No shortcut";
    _pane.defaultsTip = @"Defaults";
    _pane.undoActionName = @"Change Shortcut";
    _pane.recordingFormat = @"Recording %@";
    _pane.reservedFormat = @"%@ is reserved";
    _pane.unusableCaption = @"Unusable";
    _pane.reassignedFormat = @"%@ moved to %@ from %@";
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 520) styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed = NO;
    _window.contentViewController = _pane;
    [_pane refreshFromSettings];
}

- (void)tearDown {
    [_window close];
}

- (NSTableView *)table {
    return Find(_pane.view, NSTableView.class, ^BOOL(id view) { return YES; });
}

- (NSButton *)buttonTitled:(NSString *)title {
    return Find(_pane.view, NSButton.class, ^BOOL(NSButton *button) { return [button.title isEqualToString:title]; });
}

- (NSString *)shortcutShownInRow:(NSInteger)row {
    NSTableCellView *cell = [self.table viewAtColumn:1 row:row makeIfNecessary:YES];
    return cell.textField.stringValue;
}

- (void)selectRow:(NSInteger)row {
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
}

- (void)sendKey:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers type:(NSEventType)type {
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers timestamp:0
                                  windowNumber:_window.windowNumber context:nil characters:@""
                   charactersIgnoringModifiers:@"" isARepeat:NO keyCode:keyCode];
    [NSApp sendEvent:event];
}

- (void)testListsTheGroupTitleThenEachCommandWithItsShortcut {
    XCTAssertEqual(self.table.numberOfRows, 3);
    XCTAssertEqualObjects([self shortcutShownInRow:1], @"Space");
    XCTAssertEqualObjects([self shortcutShownInRow:2], VibeShortcutDisplayString(VibeShortcutMake(45, 0)));
}

- (void)testRecordingAKeyAssignsItsEncodingAndShowsIt {
    [self selectRow:1];
    [[self buttonTitled:@"Record"] performClick:nil];
    XCTAssertFalse([self buttonTitled:@"Record"].enabled, @"recording disables Record");
    [self sendKey:0 modifiers:kControlOption type:NSEventTypeKeyDown];
    VibeShortcut recorded = VibeShortcutMake(0, kControlOption);
    XCTAssertEqualObjects(_writes, (@[[NSString stringWithFormat:@"assign play %lu", (unsigned long)recorded]]));
    XCTAssertEqualObjects(_store, (@{@"play": @(recorded)}));
    XCTAssertEqualObjects([self shortcutShownInRow:1], VibeShortcutDisplayString(recorded));
    XCTAssertTrue([[self shortcutShownInRow:1] hasPrefix:@"⌃⌥"]);
    // The release ends the recording; a later press reaches nothing.
    [self sendKey:0 modifiers:kControlOption type:NSEventTypeKeyUp];
    [self sendKey:1 modifiers:kControlOption type:NSEventTypeKeyDown];
    XCTAssertEqual(_writes.count, 1u);
    XCTAssertTrue([self buttonTitled:@"Record"].enabled);
}

- (void)testEscapeCancelsARecording {
    [self selectRow:2];
    [[self buttonTitled:@"Record"] performClick:nil];
    [self sendKey:53 modifiers:0 type:NSEventTypeKeyDown];
    [self sendKey:53 modifiers:0 type:NSEventTypeKeyUp];
    XCTAssertEqual(_writes.count, 0u);
    XCTAssertEqualObjects(_store, @{});
}

- (void)testClearAssignsNoneAndShowsTheUnassignedName {
    [self selectRow:2];
    [[self buttonTitled:@"Clear"] performClick:nil];
    XCTAssertEqualObjects(_writes, (@[[NSString stringWithFormat:@"assign next %lu", (unsigned long)kVibeShortcutNone]]));
    XCTAssertEqualObjects([self shortcutShownInRow:2], @"None");
    XCTAssertFalse([self buttonTitled:@"Clear"].enabled, @"nothing left to clear");
}

- (void)testResetAllReplacesTheStoreWithNone {
    [self selectRow:2];
    [[self buttonTitled:@"Clear"] performClick:nil];
    XCTAssertTrue([self buttonTitled:@"Reset All"].enabled);
    [[self buttonTitled:@"Reset All"] performClick:nil];
    XCTAssertEqualObjects(_writes.lastObject, @"set 0");
    XCTAssertEqualObjects(_store, @{});
    XCTAssertEqualObjects([self shortcutShownInRow:2], VibeShortcutDisplayString(VibeShortcutMake(45, 0)));
    XCTAssertFalse([self buttonTitled:@"Reset All"].enabled, @"every shortcut is its default");
}

@end
