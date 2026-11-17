//
//  ShortcutRulesTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>

#import "ShortcutRules.h"

@interface ShortcutRulesTests : XCTestCase
@end

@implementation ShortcutRulesTests

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShift = NSEventModifierFlagShift;
static const NSEventModifierFlags kOption = NSEventModifierFlagOption;

// The test's own command table, in the order a duplicate resolves: bare keys
// by key code, Command defaults by character, and one command with none.
static NSArray<NSArray *> *Table(void) {
    return @[
        @[@"play",      @(VibeShortcutMake(kVibeKeyCodeSpace, 0))],   // Space
        @[@"select",    @(VibeShortcutMake(kVibeKeyCodeReturn, 0))],
        @[@"next",      @(VibeShortcutMake(45, 0))],   // N
        @[@"shuffle",   @(VibeShortcutMakeCharacter('s', kCmd | kOption))],
        @[@"repeat",    @(VibeShortcutMakeCharacter('r', kCmd))],
        @[@"skip",      @(VibeShortcutMake(0, 0))],    // A
        @[@"skip_back", @(VibeShortcutMake(6, 0))],    // Z
        @[@"low_kill",  @(VibeShortcutMake(12, 0))],   // Q
        @[@"delay",     @(VibeShortcutMake(15, 0))],   // R
        @[@"pitch",     @(VibeShortcutMake(35, 0))],   // P
        @[@"pin",       @(kVibeShortcutNone)],
        @[@"open",      @(VibeShortcutMakeCharacter('o', kCmd))],
        @[@"save",      @(VibeShortcutMakeCharacter('s', kCmd))],
        @[@"copy_name", @(VibeShortcutMakeCharacter('c', kCmd | kShift))],
        @[@"remove",    @(VibeShortcutMake(kVibeKeyCodeDelete, 0))],
        @[@"trash",     @(VibeShortcutMake(kVibeKeyCodeDelete, kCmd))],
        @[@"add",       @(VibeShortcutMakeCharacter('o', kCmd | kShift))],
        @[@"reveal",    @(VibeShortcutMakeCharacter('r', kCmd | kShift))],
    ];
}

// The command a key-code press performs, typing no character.
static NSString *CommandForKey(unsigned short keyCode, NSEventModifierFlags modifiers, NSDictionary *overrides) {
    return VibeShortcutOwner(Table(), VibeShortcutMake(keyCode, modifiers), 0, overrides, nil);
}

// What a key-code shortcut's menu item carries, the key typing character.
static VibeShortcut MenuItemForKey(NSString *identifier, VibeShortcut shortcut, unichar character,
                                   NSDictionary *overrides) {
    return VibeShortcutForMenuItem(Table(), identifier, shortcut, kVibeShortcutKeyMask, character, overrides);
}

- (void)testBareKeysMatchByPhysicalKeyWithTheirExactModifiers {
    XCTAssertEqualObjects(CommandForKey(0, 0, nil), @"skip");
    XCTAssertEqualObjects(CommandForKey(12, 0, nil), @"low_kill");
    XCTAssertEqualObjects(CommandForKey(kVibeKeyCodeSpace, 0, nil), @"play");
    // Shift, or any modifier, is a different shortcut.
    XCTAssertNil(CommandForKey(0, kShift, nil));
    // Caps Lock and the function flag are not part of a shortcut.
    XCTAssertEqualObjects(CommandForKey(0, NSEventModifierFlagCapsLock | NSEventModifierFlagFunction, nil), @"skip");
    // Character defaults match by character, never by key code.
    XCTAssertNil(CommandForKey(31, kCmd, nil));
    XCTAssertEqual(VibeShortcutDefault(Table(), @"menu_gone"), kVibeShortcutNone);
}

- (void)testCharacterDefaultsMatchTheirLetterWithTheirExactModifiers {
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(15, kCmd), 'r', nil, nil), @"repeat");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(35, kCmd), 'r', nil, nil), @"repeat",
                          @"Dvorak's R is QWERTY's P");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(15, kCmd), 'p', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd | kOption), 's', nil, nil), @"shuffle");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd), 's', nil, nil), @"save");
    // Shift is part of the set, against every character default.
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd | kShift), 's', nil, nil));
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd | kOption | kShift), 's', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(15, kCmd | kShift), 'r', nil, nil), @"reveal",
                          @"⇧⌘R is its own command, never ⌘R's");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(31, kCmd | kShift), 'o', nil, nil), @"add");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(8, kShift), 'c', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(15, 0), 'r', nil, nil), @"delay",
                          @"bare R is the delay's key code, not ⌘R's letter");
}

- (void)testAPressIsTriedAsTypedThenUnmodifiedAndAReservedOnePassesOn {
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 15, kCmd, 'r', 0x03C1, nil), @"repeat",
                          @"Greek types ρ, and r under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 1, kCmd | kOption, 0x00DF, 's', nil), @"shuffle",
                          @"⌥⌘S types ß");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 31, kCmd, 'o', 'r', nil), @"open",
                          @"Dvorak – QWERTY ⌘'s R key types o under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 0, 0, 0, 'a', nil), @"skip");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 12, kCmd, 'q', 'q', nil), @"⌘Q is the system's");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 12, kCmd, 'q', 0x03C2, nil), @"reserved under either form");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 126, 0, 0, 0, nil), @"an arrow is the list's");
}

- (void)testKeypadEnterAndForwardDeleteFoldIntoTheirTwins {
    XCTAssertEqualObjects(CommandForKey(76, 0, nil), @"select");
    XCTAssertEqualObjects(CommandForKey(117, 0, nil), @"remove");
    XCTAssertEqualObjects(CommandForKey(117, kCmd, nil), @"trash");
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"play", VibeShortcutMake(76, kCmd), 0, NULL);
    XCTAssertEqualObjects(overrides[@"play"], @(VibeShortcutMake(36, kCmd)));
    XCTAssertEqualObjects(CommandForKey(36, kCmd, overrides), @"play");
}

- (void)testReservedShortcutsAreTheSystemOnesTheArrowsEscapeAndTheKeypad {
    for (NSString *key in @[@",", @"h", @"q", @"w", @"z", @"x", @"c", @"v", @"a", @"m"]) {
        XCTAssertTrue(VibeShortcutIsReserved(0, [key characterAtIndex:0], kCmd), @"⌘%@", key);
    }
    XCTAssertTrue(VibeShortcutIsReserved(4, 'h', kCmd | NSEventModifierFlagOption));
    XCTAssertTrue(VibeShortcutIsReserved(6, 'z', kCmd | kShift));
    XCTAssertTrue(VibeShortcutIsReserved(125, 0, kShift));
    XCTAssertTrue(VibeShortcutIsReserved(53, 0, 0));
    XCTAssertTrue(VibeShortcutIsReserved(123, 0, kCmd));
    XCTAssertTrue(VibeShortcutIsReserved(83, '1', 0), @"keypad digits");
    XCTAssertTrue(VibeShortcutIsReserved(67, '*', kOption), @"keypad operators");
    XCTAssertTrue(VibeShortcutIsReserved(65, '.', 0), @"keypad decimal");
    XCTAssertTrue(VibeShortcutIsReserved(71, 0, 0), @"keypad Clear");
    XCTAssertFalse(VibeShortcutIsReserved(18, '1', 0), @"the top row's 1");
    XCTAssertFalse(VibeShortcutIsReserved(76, 0, 0), @"keypad Enter is Return");
    XCTAssertFalse(VibeShortcutIsKeypadKey(76));
    // Only the exact combination is reserved, matched by character.
    XCTAssertFalse(VibeShortcutIsReserved(12, 'q', 0));
    XCTAssertFalse(VibeShortcutIsReserved(12, 'q', kCmd | kShift));
    XCTAssertFalse(VibeShortcutIsReserved(0, 0x0444, kCmd), @"a Cyrillic ⌘ф is free");
    XCTAssertFalse(VibeShortcutIsReserved(46, 'm', 0), @"bare M is an ordinary key; ⌘M is Window > Minimize");
}

// Cut and Paste own ⌘X and ⌘V. Neither can be recorded, and an override
// stored before they existed reaches neither the key monitor nor a menu item.
- (void)testCutAndPasteKeysAreReservedAndAStoredOverrideOnThemIsInert {
    XCTAssertTrue(VibeShortcutIsReserved(7, 'x', kCmd));
    XCTAssertTrue(VibeShortcutIsReserved(9, 'v', kCmd));
    XCTAssertTrue(VibeShortcutIsReserved(47, 'v', kCmd), @"Dvorak's V key types v under ⌘");
    XCTAssertFalse(VibeShortcutIsReserved(7, 'x', 0), @"bare X is an ordinary key");
    XCTAssertFalse(VibeShortcutIsReserved(9, 'v', kCmd | kShift));
    XCTAssertFalse(VibeShortcutIsReserved(9, 'v', kCmd | kOption));

    VibeShortcut pasteKey = VibeShortcutMake(9, kCmd);
    NSDictionary *overrides = @{@"next": @(pasteKey)};
    XCTAssertEqual(VibeShortcutEffective(Table(), @"next", overrides), pasteKey, @"kept as stored");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 9, kCmd, 'v', 'v', overrides), @"the press passes on to Paste");
    XCTAssertEqual(MenuItemForKey(@"next", pasteKey, 'v', overrides), kVibeShortcutNone, @"no shadowing equivalent");
    XCTAssertEqual(MenuItemForKey(@"skip_back", VibeShortcutMake(7, kCmd), 'x', nil), kVibeShortcutNone);
    // The same key under a layout that types another letter there is free.
    XCTAssertEqual(MenuItemForKey(@"next", pasteKey, 0x043C, overrides), pasteKey, @"Russian ⌘м");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 9, kCmd, 0x043C, 0x043C, overrides), @"next");
}

- (void)testAMenuItemCarriesEveryShortcutButAReservedOne {
    for (NSArray *entry in Table()) {
        VibeShortcut shortcut = [entry[1] unsignedIntegerValue];
        XCTAssertEqual(MenuItemForKey(entry[0], shortcut, 0, nil), shortcut, @"%@", entry[0]);
    }
    XCTAssertEqual(MenuItemForKey(@"play", kVibeShortcutNone, 'v', nil), kVibeShortcutNone);
    XCTAssertEqual(MenuItemForKey(@"pin", VibeShortcutMake(12, kCmd), 'q', nil), kVibeShortcutNone, @"⌘Q");
    XCTAssertEqual(MenuItemForKey(@"pin", VibeShortcutMake(126, kCmd), 0, nil), kVibeShortcutNone, @"an arrow");
    VibeShortcut commandK = VibeShortcutMake(40, kCmd);
    XCTAssertEqual(MenuItemForKey(@"pin", commandK, 'k', @{@"pin": @(commandK)}), commandK);
}

- (void)testAssigningTakesTheShortcutFromItsOwnerAndStaysSparse {
    NSString *loser = nil;
    // K is free: stored, no loser.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"skip", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{@"skip": @(VibeShortcutMake(40, 0))});
    XCTAssertNil(CommandForKey(0, 0, overrides), @"A is now free");

    // Taking N from next leaves next unassigned, stored as None over its default.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"play", VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, @"next");
    XCTAssertEqual(VibeShortcutEffective(Table(), @"next", overrides), kVibeShortcutNone);
    XCTAssertEqualObjects(CommandForKey(45, 0, overrides), @"play");

    // skip loses K in turn, and stays unassigned rather than reverting to A.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"next", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertEqualObjects(loser, @"skip");
    XCTAssertEqual(VibeShortcutEffective(Table(), @"skip", overrides), kVibeShortcutNone);

    // Back to its default is absence; reassigning to self names no loser.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"next", VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, @"play");
    XCTAssertNil(overrides[@"next"]);
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"next", VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertNil(loser);

    // Clearing names no loser and needs no character.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"pin", kVibeShortcutNone, 0, &loser);
    XCTAssertNil(loser);
    XCTAssertNil(overrides[@"pin"], @"already None by default");
}

- (void)testAKeyCodeCollidesWithACharacterDefaultByCharacter {
    NSString *loser = nil;
    // ⌘O recorded on a QWERTY layout lands on open's character default.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"pin", VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertEqualObjects(loser, @"open");
    XCTAssertEqual(VibeShortcutEffective(Table(), @"open", overrides), kVibeShortcutNone);
    // ⇧⌘C collides with copy_name; ⌘C alone is reserved, not owned.
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(8, kCmd | kShift), 'c', nil, nil), @"copy_name");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(8, kCmd), 'c', nil, nil));
    // With no character known, only key codes collide.
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(31, kCmd), 0, nil, nil));
}

- (void)testACharacterShortcutPassedInMatchesByItsCharacterAlone {
    // F12's key code is the code of 'o', so a key-code read would give pin.
    NSDictionary *overrides = @{@"pin": @(VibeShortcutMake(111, kCmd))};
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMakeCharacter('o', kCmd), 0, overrides, nil), @"open");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(111, kCmd), 0, overrides, nil), @"pin");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMakeCharacter('k', kCmd), 0, overrides, nil));
}

- (void)testOnlyAKeyCodeWithModifiersOrNoneIsStorable {
    XCTAssertTrue(VibeShortcutIsStorable(@(kVibeShortcutNone)));
    XCTAssertTrue(VibeShortcutIsStorable(@(VibeShortcutMake(40, kCmd | kShift | kOption | NSEventModifierFlagControl))));
    XCTAssertTrue(VibeShortcutIsStorable(@(VibeShortcutMake(0, 0))));
    XCTAssertFalse(VibeShortcutIsStorable(@(kVibeShortcutNone | kCmd)), @"None takes no modifiers");
    XCTAssertFalse(VibeShortcutIsStorable(@(VibeShortcutMakeCharacter('o', kCmd))));
    XCTAssertFalse(VibeShortcutIsStorable(@(VibeShortcutMake(40, 0) | NSEventModifierFlagCapsLock)));
    XCTAssertFalse(VibeShortcutIsStorable(@(-1)));
    XCTAssertFalse(VibeShortcutIsStorable(@(-40)));
    XCTAssertFalse(VibeShortcutIsStorable(nil));
    XCTAssertFalse(VibeShortcutIsStorable(@"40"));
    XCTAssertFalse(VibeShortcutIsStorable(@[@40]));
    XCTAssertFalse(VibeShortcutIsStorable(NSNull.null));
}

- (void)testAssigningAnIdentifierOutsideTheTableChangesNothing {
    NSDictionary *stored = @{@"skip": @(VibeShortcutMake(40, 0))};
    NSString *loser = @"stale";
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), stored, @"menu_gone", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, stored);
    overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"menu_gone", VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{}, @"open keeps ⌘O");
}

- (void)testMalformedOrForeignStoredValuesReadAsDefaultsAndAreDropped {
    NSDictionary *stored = @{
        @"play": @"space",
        @"next": @(VibeShortcutMakeCharacter('n', 0)), // never stored
        @"skip_back": @(1UL << 40),
        @"menu_gone": @(VibeShortcutMake(40, 0)),
    };
    XCTAssertEqual(VibeShortcutEffective(Table(), @"play", stored), VibeShortcutDefault(Table(), @"play"));
    XCTAssertEqual(VibeShortcutEffective(Table(), @"next", stored), VibeShortcutDefault(Table(), @"next"));
    XCTAssertEqual(VibeShortcutEffective(Table(), @"skip_back", stored), VibeShortcutDefault(Table(), @"skip_back"));
    NSDictionary *cleaned = VibeShortcutOverridesByAssigning(Table(), stored, @"pin", kVibeShortcutNone, 0, NULL);
    XCTAssertEqualObjects(cleaned, @{});
}

- (void)testADuplicateResolvesToTheFirstCommandInTableOrder {
    NSDictionary *stored = @{@"pitch": @(VibeShortcutMake(kVibeKeyCodeSpace, 0))}; // Space, as play's default
    XCTAssertEqualObjects(CommandForKey(kVibeKeyCodeSpace, 0, stored), @"play");
    // The menu bar agrees: only play's item carries Space.
    XCTAssertEqual(MenuItemForKey(@"play", VibeShortcutMake(kVibeKeyCodeSpace, 0), ' ', stored), VibeShortcutMake(kVibeKeyCodeSpace, 0));
    XCTAssertEqual(MenuItemForKey(@"pitch", VibeShortcutMake(kVibeKeyCodeSpace, 0), ' ', stored), kVibeShortcutNone);
}

- (void)testCanonicalFoldsAKeyCodeAndLeavesTheRest {
    XCTAssertEqual(VibeShortcutCanonical(VibeShortcutMake(kVibeKeyCodeKeypadEnter, kCmd)),
                   VibeShortcutMake(kVibeKeyCodeReturn, kCmd));
    XCTAssertEqual(VibeShortcutCanonical(VibeShortcutMake(kVibeKeyCodeForwardDelete, 0)),
                   VibeShortcutMake(kVibeKeyCodeDelete, 0));
    XCTAssertEqual(VibeShortcutCanonical(VibeShortcutMakeCharacter('o', kCmd)), VibeShortcutMakeCharacter('o', kCmd));
    XCTAssertEqual(VibeShortcutCanonical(kVibeShortcutNone), kVibeShortcutNone);
}

#pragma mark - An app's own rules

// An app whose defaults are ⌘ and an arrow: an arrow is reserved only without
// Command, and bare Return is the lists'.
static BOOL AppIsReserved(unsigned short keyCode, unichar character, NSEventModifierFlags modifiers) {
    switch (keyCode) {
        case kVibeKeyCodeLeftArrow: case kVibeKeyCodeRightArrow:
        case kVibeKeyCodeDownArrow: case kVibeKeyCodeUpArrow:
            return (modifiers & kCmd) == 0;
        case kVibeKeyCodeReturn:
            return modifiers == 0;
    }
    return VibeShortcutIsReserved(keyCode, character, modifiers);
}

// A menu's spelling over a few US keys, with no layout: a shifted letter or =
// rides in its Shift character, as VibeShortcutKeyEquivalent does.
static NSString *_Nullable AppSpelling(VibeShortcut shortcut) {
    if (shortcut == kVibeShortcutNone) {
        return nil;
    }
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    unichar character = 0;
    if (VibeShortcutIsCharacter(shortcut)) {
        character = VibeShortcutKey(shortcut);
    } else {
        switch (VibeShortcutKey(shortcut)) {
            case 24: character = '='; break;
            case 31: character = 'o'; break;
            case 40: character = 'k'; break;
            default: return nil;
        }
    }
    if (modifiers & kShift) {
        if (character == '=') {
            character = '+';
            modifiers &= ~kShift;
        } else if (character >= 'a' && character <= 'z') {
            character = character - 'a' + 'A';
            modifiers &= ~kShift;
        }
    }
    return [NSString stringWithFormat:@"%lx %C", (unsigned long)modifiers, character];
}

// The app's own table: mark's default is the key the user later gave play.
static NSArray<NSArray *> *AppTable(void) {
    return @[
        @[@"mark",       @(VibeShortcutMake(40, 0))],   // K
        @[@"next_track", @(VibeShortcutMake(kVibeKeyCodeRightArrow, kCmd))],
        @[@"zoom_in",    @(VibeShortcutMakeCharacter('+', kCmd))],
        @[@"play",       @(VibeShortcutMake(kVibeKeyCodeSpace, 0))],
        @[@"open",       @(VibeShortcutMakeCharacter('o', kCmd))],
        @[@"select",     @(kVibeShortcutNone)],
    ];
}

- (void)testAnAppsReservedRuleFreesCommandArrowAndReservesBareReturn {
    VibeShortcutRules rules = {AppIsReserved, NO, NULL};
    VibeShortcut nextKey = VibeShortcutMake(kVibeKeyCodeRightArrow, kCmd);
    XCTAssertEqual(VibeShortcutForMenuItemUnderRules(AppTable(), @"next_track", nextKey, kVibeShortcutKeyMask, 0,
                                                     nil, rules), nextKey);
    XCTAssertEqual(VibeShortcutForMenuItem(AppTable(), @"next_track", nextKey, kVibeShortcutKeyMask, 0, nil),
                   kVibeShortcutNone, @"the default rule reserves an arrow with any modifier");
    XCTAssertEqualObjects(VibeShortcutCommandForPressUnderRules(AppTable(), kVibeKeyCodeRightArrow, kCmd, 0, 0,
                                                                nil, rules), @"next_track");
    XCTAssertNil(VibeShortcutCommandForPress(AppTable(), kVibeKeyCodeRightArrow, kCmd, 0, 0, nil));
    XCTAssertNil(VibeShortcutCommandForPressUnderRules(AppTable(), kVibeKeyCodeRightArrow, 0, 0, 0, nil, rules),
                 @"a bare arrow is the list's");

    VibeShortcut returnKey = VibeShortcutMake(kVibeKeyCodeReturn, 0);
    NSDictionary *overrides = @{@"select": @(returnKey)};
    XCTAssertTrue(VibeShortcutIsReservedUnderRules(rules, kVibeKeyCodeKeypadEnter, 0, 0), @"Enter is Return");
    XCTAssertFalse(VibeShortcutIsReservedUnderRules(rules, kVibeKeyCodeReturn, 0, kCmd));
    XCTAssertFalse(VibeShortcutIsReservedUnderRules(kVibeShortcutDefaultRules, kVibeKeyCodeReturn, 0, 0));
    XCTAssertEqual(VibeShortcutForMenuItemUnderRules(AppTable(), @"select", returnKey, kVibeShortcutKeyMask, 0,
                                                     overrides, rules), kVibeShortcutNone);
    XCTAssertNil(VibeShortcutCommandForPressUnderRules(AppTable(), kVibeKeyCodeKeypadEnter, 0, 0, 0, overrides, rules));
    XCTAssertEqualObjects(VibeShortcutCommandForPress(AppTable(), kVibeKeyCodeReturn, 0, 0, 0, overrides), @"select");
    XCTAssertTrue(VibeShortcutIsReservedUnderRules(rules, 12, 'q', kCmd), @"the system's keys stay reserved");
}

- (void)testAnOverrideOutranksAnEarlierDefaultWhenTheRulesSaySo {
    VibeShortcutRules rules = {NULL, YES, NULL};
    VibeShortcut k = VibeShortcutMake(40, 0);
    NSDictionary *overrides = @{@"play": @(k)};
    XCTAssertEqualObjects(VibeShortcutOwner(AppTable(), k, 'k', overrides, nil), @"mark", @"table order");
    XCTAssertEqualObjects(VibeShortcutOwnerUnderRules(AppTable(), k, 'k', overrides, nil, rules), @"play");
    XCTAssertEqualObjects(VibeShortcutCommandForPressUnderRules(AppTable(), 40, 0, 0, 'k', overrides, rules), @"play");
    XCTAssertEqual(VibeShortcutForMenuItemUnderRules(AppTable(), @"play", k, kVibeShortcutKeyMask, 'k', overrides,
                                                     rules), k);
    XCTAssertEqual(VibeShortcutForMenuItemUnderRules(AppTable(), @"mark", k, kVibeShortcutKeyMask, 'k', overrides,
                                                     rules), kVibeShortcutNone);

    // A recording takes K from play, and from mark too, so mark never
    // surfaces with it.
    NSString *loser = nil;
    NSDictionary *next = VibeShortcutOverridesByAssigningUnderRules(AppTable(), overrides, @"open", k, 'k', &loser,
                                                                    rules);
    XCTAssertEqualObjects(loser, @"play");
    XCTAssertEqual(VibeShortcutEffective(AppTable(), @"play", next), kVibeShortcutNone);
    XCTAssertEqual(VibeShortcutEffective(AppTable(), @"mark", next), kVibeShortcutNone);
    XCTAssertEqualObjects(VibeShortcutOwnerUnderRules(AppTable(), k, 'k', next, nil, rules), @"open");

    // The default rules take K from mark alone, and play keeps it.
    next = VibeShortcutOverridesByAssigning(AppTable(), overrides, @"open", k, 'k', &loser);
    XCTAssertEqualObjects(loser, @"mark");
    XCTAssertEqualObjects(next[@"play"], @(k));
}

- (void)testACharacterDefaultCollidesWithARecordedKeyAMenuSpellsTheSame {
    VibeShortcutRules rules = {NULL, NO, AppSpelling};
    VibeShortcut shiftEquals = VibeShortcutMake(24, kCmd | kShift);
    XCTAssertNil(VibeShortcutOwner(AppTable(), shiftEquals, '=', nil, nil), @"the encodings differ");
    XCTAssertEqualObjects(VibeShortcutOwnerUnderRules(AppTable(), shiftEquals, '=', nil, nil, rules), @"zoom_in");
    XCTAssertEqualObjects(VibeShortcutCommandForPressUnderRules(AppTable(), 24, kCmd | kShift, '+', '=', nil, rules),
                          @"zoom_in");

    // Recorded on open, it takes the key from zoom_in.
    NSString *loser = nil;
    NSDictionary *overrides = VibeShortcutOverridesByAssigningUnderRules(AppTable(), nil, @"open", shiftEquals, '=',
                                                                         &loser, rules);
    XCTAssertEqualObjects(loser, @"zoom_in");
    XCTAssertEqual(VibeShortcutEffective(AppTable(), @"zoom_in", overrides), kVibeShortcutNone);

    // Both on the key at once: the menu bar gives it to the first.
    overrides = @{@"open": @(shiftEquals)};
    VibeShortcut plus = VibeShortcutMakeCharacter('+', kCmd);
    XCTAssertEqual(VibeShortcutForMenuItemUnderRules(AppTable(), @"zoom_in", plus, kVibeShortcutKeyMask, 0, overrides,
                                                     rules), plus, @"no key types + unshifted on US");
    XCTAssertEqual(VibeShortcutForMenuItemUnderRules(AppTable(), @"open", shiftEquals, kVibeShortcutKeyMask, '=',
                                                     overrides, rules), kVibeShortcutNone);
    XCTAssertEqual(VibeShortcutForMenuItem(AppTable(), @"open", shiftEquals, kVibeShortcutKeyMask, '=', overrides),
                   shiftEquals);

    // A recording a menu spells as the command's own default is the default.
    overrides = VibeShortcutOverridesByAssigningUnderRules(AppTable(), @{@"zoom_in": @(VibeShortcutMake(40, kCmd))},
                                                           @"zoom_in", shiftEquals, '=', &loser, rules);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{});
    overrides = VibeShortcutOverridesByAssigningUnderRules(AppTable(), nil, @"open", VibeShortcutMake(31, kCmd),
                                                           'o', &loser, rules);
    XCTAssertEqualObjects(overrides, @{});
    XCTAssertEqualObjects(VibeShortcutOverridesByAssigning(AppTable(), nil, @"open", VibeShortcutMake(31, kCmd), 'o',
                                                           &loser),
                          @{@"open": @(VibeShortcutMake(31, kCmd))}, @"the default rules compare encodings");
}

@end
