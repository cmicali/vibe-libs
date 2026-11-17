//
//  ShortcutLayoutTests.m
//  ShortcutsTests
//
//  A shortcut under the runner's own layout. Each test asks the layout what
//  a key types rather than naming a letter, so any ASCII-capable layout
//  passes.
//

#import <XCTest/XCTest.h>
#import "ShortcutLayout.h"

@interface ShortcutLayoutTests : XCTestCase
@end

@implementation ShortcutLayoutTests

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShift = NSEventModifierFlagShift;

- (void)setUp {
    VibeShortcutSetKeyNames(@"Space", @"Keypad %@", @"Key %ld", @"None");
}

- (void)testALetterKeyTypesALetterAndThatLetterNamesTheKey {
    // kVK_ANSI_A, a letter on every ASCII-capable layout.
    unichar character = VibeShortcutCharacterForKeyCode(0, 0);
    XCTAssertTrue([NSCharacterSet.lowercaseLetterCharacterSet characterIsMember:character]);
    XCTAssertEqual(VibeShortcutKeyCodeForCharacter(character, 0), 0);
    NSString *letter = [NSString stringWithCharacters:&character length:1];
    XCTAssertEqualObjects(VibeShortcutKeyLabel(0, 0), letter.uppercaseString);
    XCTAssertEqualObjects(VibeShortcutDisplayString(VibeShortcutMake(0, NSEventModifierFlagControl
                                                                         | NSEventModifierFlagOption | kCmd)),
                          [@"⌃⌥⌘" stringByAppendingString:VibeShortcutKeyLabel(0, kCmd)]);
}

- (void)testTheAppsNamesFillWhatNoLayoutNames {
    XCTAssertEqualObjects(VibeShortcutDisplayString(kVibeShortcutNone), @"None");
    XCTAssertEqualObjects(VibeShortcutDisplayString(VibeShortcutMake(kVibeKeyCodeSpace, NSEventModifierFlagOption)), @"⌥Space");
    XCTAssertTrue([VibeShortcutKeyLabel(83, 0) hasPrefix:@"Keypad "], @"keypad 1");
    XCTAssertEqualObjects(VibeShortcutDisplayString(VibeShortcutMake(200, 0)), @"Key 200");
    XCTAssertNil(VibeShortcutKeyLabel(200, 0));
    XCTAssertEqualObjects(VibeShortcutKeyLabel(kVibeKeyCodeReturn, 0), @"↩");
}

- (void)testAShiftedKeyRidesInTheCharacterShiftTypes {
    NSEventModifierFlags mask = 0;
    NSString *letter = VibeShortcutKeyEquivalent(VibeShortcutMake(0, kCmd | kShift), &mask);
    XCTAssertEqualObjects(letter, VibeShortcutKeyLabel(0, kCmd));
    XCTAssertEqual(mask, kCmd);
    XCTAssertEqualObjects(VibeShortcutKeyEquivalent(VibeShortcutMakeCharacter('o', kCmd), &mask), @"o");
    XCTAssertEqual(mask, kCmd);
    XCTAssertEqualObjects(VibeShortcutKeyEquivalent(VibeShortcutMake(kVibeKeyCodeDelete, kShift),
                                                    &mask), @"\b");
    XCTAssertEqual(mask, kShift, @"a special key keeps the flag");
    XCTAssertNil(VibeShortcutKeyEquivalent(kVibeShortcutNone, &mask));
    XCTAssertEqual(mask, 0u);
}

- (void)testASpecialKeysEquivalentTurnsBackIntoItsKey {
    const unsigned short special[] = {
        kVibeKeyCodeReturn, kVibeKeyCodeTab, kVibeKeyCodeSpace, kVibeKeyCodeDelete, kVibeKeyCodeEscape,
        kVibeKeyCodeLeftArrow, kVibeKeyCodeRightArrow, kVibeKeyCodeDownArrow, kVibeKeyCodeUpArrow,
        kVibeKeyCodeKeypadClear, 115, 119, 116, 121, // Home, End, Page Up, Page Down
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, // F1 … F20
    };
    const NSEventModifierFlags layers[] = {
        0, kCmd, kCmd | kShift, NSEventModifierFlagControl | NSEventModifierFlagOption,
    };
    for (size_t i = 0; i < sizeof(special) / sizeof(special[0]); i++) {
        for (size_t j = 0; j < sizeof(layers) / sizeof(layers[0]); j++) {
            VibeShortcut shortcut = VibeShortcutMake(special[i], layers[j]);
            NSEventModifierFlags mask = 0;
            NSString *equivalent = VibeShortcutKeyEquivalent(shortcut, &mask);
            XCTAssertNotNil(equivalent, @"key %u", special[i]);
            XCTAssertEqual(VibeShortcutForKeyEquivalent(equivalent, mask), shortcut, @"key %u", special[i]);
        }
    }
    // No key the layout names spells a special key.
    for (unsigned short keyCode = 0; keyCode < 128; keyCode++) {
        NSEventModifierFlags mask = 0;
        NSString *equivalent = VibeShortcutKeyEquivalent(VibeShortcutMake(keyCode, kCmd), &mask);
        VibeShortcut back = equivalent ? VibeShortcutForKeyEquivalent(equivalent, mask) : kVibeShortcutNone;
        if (back != kVibeShortcutNone && !VibeShortcutIsCharacter(back)) {
            XCTAssertEqual(back, VibeShortcutMake(keyCode, kCmd), @"key %u", keyCode);
        }
    }
}

- (void)testAMenuItemsEquivalentTurnsBackIntoAShortcut {
    XCTAssertEqual(VibeShortcutForKeyEquivalent(@"", kCmd), kVibeShortcutNone);
    XCTAssertEqual(VibeShortcutForKeyEquivalent(@"o", kCmd), VibeShortcutMakeCharacter('o', kCmd));
    XCTAssertEqual(VibeShortcutForKeyEquivalent(@"O", kCmd),
                   VibeShortcutMakeCharacter('o', kCmd | kShift), @"a capital carries Shift");
    XCTAssertEqual(VibeShortcutForKeyEquivalent(@"+", kCmd), VibeShortcutMakeCharacter('+', kCmd));
    XCTAssertEqual(VibeShortcutForKeyEquivalent(@"ok", kCmd), kVibeShortcutNone, @"multi-character");
    const unichar folds[][2] = {
        {NSDeleteCharacter, kVibeKeyCodeDelete},
        {NSDeleteFunctionKey, kVibeKeyCodeDelete},
        {NSEnterCharacter, kVibeKeyCodeReturn},
    };
    for (size_t i = 0; i < sizeof(folds) / sizeof(folds[0]); i++) {
        XCTAssertEqual(VibeShortcutForKeyEquivalent([NSString stringWithCharacters:&folds[i][0] length:1], kCmd),
                       VibeShortcutMake(folds[i][1], kCmd), @"%u", folds[i][0]);
    }
    XCTAssertEqual(VibeShortcutForKeyEquivalent(@"o", kCmd | NSEventModifierFlagCapsLock),
                   VibeShortcutMakeCharacter('o', kCmd), @"only the four modifiers count");
}

- (void)testAKeyAndTheCharacterItTypesSpellTheSameInAMenu {
    XCTAssertNil(VibeShortcutMenuSpelling(kVibeShortcutNone));
    XCTAssertNil(VibeShortcutMenuSpelling(VibeShortcutMake(200, kCmd)));
    unichar character = VibeShortcutCharacterForKeyCode(0, kCmd);
    XCTAssertEqualObjects(VibeShortcutMenuSpelling(VibeShortcutMake(0, kCmd)),
                          VibeShortcutMenuSpelling(VibeShortcutMakeCharacter(character, kCmd)));
    XCTAssertEqualObjects(VibeShortcutMenuSpelling(VibeShortcutMake(0, kCmd | kShift)),
                          VibeShortcutMenuSpelling(VibeShortcutMakeCharacter(character, kCmd | kShift)));
    XCTAssertNotEqualObjects(VibeShortcutMenuSpelling(VibeShortcutMake(0, kCmd)),
                             VibeShortcutMenuSpelling(VibeShortcutMake(0, kCmd | kShift)));
    XCTAssertEqualObjects(VibeShortcutMenuSpelling(VibeShortcutMake(kVibeKeyCodeKeypadEnter, 0)),
                          VibeShortcutMenuSpelling(VibeShortcutMake(kVibeKeyCodeReturn, 0)), @"Enter is Return");
}

@end
