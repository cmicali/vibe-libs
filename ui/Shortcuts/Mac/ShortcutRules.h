//
//  ShortcutRules.h
//  vibe-libs
//
//  Remappable shortcuts: the encoding, the reserved keys, and the decisions a
//  key monitor, a menu bar and a recorder pane must agree on, over the app's
//  own command table. Carbon-free, so the host-less tests compile it: the
//  caller translates a key code to its character under the current layout.
//
//  The command table is the app's: @[identifier, @(default)] pairs, in the
//  order a hand-edited duplicate resolves. The first command wins. Every
//  function that takes `commands` takes that table.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// One NSUInteger, stored as an NSNumber: the key in the low 16 bits, a
// character flag above it, and the four modifier flags at AppKit's own bits.
// A key-code shortcut names the physical key, so a default bare key stays put
// under AZERTY or Greek. A character shortcut is only ever a default — the
// Command shortcuts, which follow the letter as every Mac app's do — and is
// matched by the character the press types.
typedef NSUInteger VibeShortcut;

static const VibeShortcut kVibeShortcutKeyMask = 0xFFFF;
static const VibeShortcut kVibeShortcutCharacterFlag = 1UL << 16;
static const NSEventModifierFlags kVibeShortcutModifierMask =
        NSEventModifierFlagShift | NSEventModifierFlagControl
        | NSEventModifierFlagOption | NSEventModifierFlagCommand;
// Unassigned: stored over a default to remove it.
static const VibeShortcut kVibeShortcutNone = 0xFFFF;

// HIToolbox kVK_* codes the rules and their callers name, inline so Carbon
// stays unimported.
static const unsigned short kVibeKeyCodeReturn = 36;
static const unsigned short kVibeKeyCodeTab = 48;
static const unsigned short kVibeKeyCodeSpace = 49;
static const unsigned short kVibeKeyCodeDelete = 51;
static const unsigned short kVibeKeyCodeEscape = 53;
static const unsigned short kVibeKeyCodeKeypadClear = 71;
static const unsigned short kVibeKeyCodeKeypadEnter = 76;
static const unsigned short kVibeKeyCodeForwardDelete = 117;
static const unsigned short kVibeKeyCodeLeftArrow = 123;
static const unsigned short kVibeKeyCodeRightArrow = 124;
static const unsigned short kVibeKeyCodeDownArrow = 125;
static const unsigned short kVibeKeyCodeUpArrow = 126;

static inline VibeShortcut VibeShortcutMake(unsigned short keyCode, NSEventModifierFlags modifiers) {
    return (keyCode & kVibeShortcutKeyMask) | (modifiers & kVibeShortcutModifierMask);
}

static inline VibeShortcut VibeShortcutMakeCharacter(unichar character, NSEventModifierFlags modifiers) {
    return character | kVibeShortcutCharacterFlag | (modifiers & kVibeShortcutModifierMask);
}

static inline BOOL VibeShortcutIsCharacter(VibeShortcut shortcut) {
    return (shortcut & kVibeShortcutCharacterFlag) != 0;
}

// The key code, or the character for a character shortcut.
static inline unsigned short VibeShortcutKey(VibeShortcut shortcut) {
    return (unsigned short)(shortcut & kVibeShortcutKeyMask);
}

static inline NSEventModifierFlags VibeShortcutModifiers(VibeShortcut shortcut) {
    return shortcut & kVibeShortcutModifierMask;
}

// Keypad Enter is Return and Forward Delete is Delete. A binding of either
// answers both.
static inline unsigned short VibeShortcutCanonicalKeyCode(unsigned short keyCode) {
    switch (keyCode) {
        case kVibeKeyCodeKeypadEnter:   return kVibeKeyCodeReturn;
        case kVibeKeyCodeForwardDelete: return kVibeKeyCodeDelete;
    }
    return keyCode;
}

// The shortcut with its key code folded, as a recording stores it. None and
// a character shortcut are returned as they are.
static inline VibeShortcut VibeShortcutCanonical(VibeShortcut shortcut) {
    if (shortcut == kVibeShortcutNone || VibeShortcutIsCharacter(shortcut)) {
        return shortcut;
    }
    return VibeShortcutMake(VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut)), VibeShortcutModifiers(shortcut));
}

// The keypad's digits, operators, decimal and Clear; Enter folds into Return.
static inline BOOL VibeShortcutIsKeypadKey(unsigned short keyCode) {
    switch (keyCode) {
        case 65: case 67: case 69: case kVibeKeyCodeKeypadClear: case 75: case 78: case 81:
        case 82: case 83: case 84: case 85: case 86: case 87: case 88: case 89: case 91: case 92:
            return YES;
    }
    return NO;
}

// kVibeShortcutNone for an identifier that is not in the table.
static inline VibeShortcut VibeShortcutDefault(NSArray<NSArray *> *commands, NSString *identifier) {
    for (NSArray *entry in commands) {
        if ([entry[0] isEqualToString:identifier]) {
            return [entry[1] unsignedIntegerValue];
        }
    }
    return kVibeShortcutNone;
}

// A stored value is a number naming a key code and modifiers, or None. A
// character shortcut is never stored — recording always yields a key code.
static inline BOOL VibeShortcutIsStorable(id _Nullable value) {
    if (![value isKindOfClass:NSNumber.class]) {
        return NO;
    }
    VibeShortcut shortcut = [value unsignedIntegerValue];
    return (shortcut & ~(kVibeShortcutKeyMask | kVibeShortcutModifierMask)) == 0
            && (shortcut == kVibeShortcutNone || VibeShortcutKey(shortcut) < kVibeShortcutKeyMask);
}

// The override when it is well-formed, else the default.
static inline VibeShortcut VibeShortcutEffective(NSArray<NSArray *> *commands, NSString *identifier,
                                                 NSDictionary *_Nullable overrides) {
    id stored = overrides[identifier];
    return VibeShortcutIsStorable(stored) ? [stored unsignedIntegerValue] : VibeShortcutDefault(commands, identifier);
}

// The default reserved rule. Never assignable, and passed on by the monitor
// whatever is bound: the fixed system shortcuts (matched by character, as
// their menu items match), the arrows a list's selection uses with any
// modifier, Escape, and every keypad key but Enter, which a menu cannot draw
// apart from the main keyboard's.
// character is the key's lowercase character under the current layout, 0
// when it has none.
static inline BOOL VibeShortcutIsReserved(unsigned short keyCode, unichar character,
                                          NSEventModifierFlags modifiers) {
    keyCode = VibeShortcutCanonicalKeyCode(keyCode);
    modifiers &= kVibeShortcutModifierMask;
    switch (keyCode) {
        case kVibeKeyCodeEscape:
        case kVibeKeyCodeLeftArrow: case kVibeKeyCodeRightArrow:
        case kVibeKeyCodeDownArrow: case kVibeKeyCodeUpArrow:
            return YES;
    }
    if (VibeShortcutIsKeypadKey(keyCode)) {
        return YES;
    }
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    if (modifiers == cmd) {
        switch (character) {
            case ',': case 'h': case 'q': case 'w': case 'z': case 'x': case 'c': case 'v': case 'a': case 'm':
                return YES;
        }
        return NO;
    }
    if (modifiers == (cmd | NSEventModifierFlagOption)) {
        return character == 'h';
    }
    if (modifiers == (cmd | NSEventModifierFlagShift)) {
        return character == 'z';
    }
    return NO;
}

// An app's own reserved rule, in place of VibeShortcutIsReserved. The key
// code arrives canonical and the modifiers masked to the four flags.
typedef BOOL (*VibeShortcutReservedRule)(unsigned short keyCode, unichar character, NSEventModifierFlags modifiers);
// The key a menu would draw for a shortcut, nil for none. Two spellings may
// match only when the modifiers differ by Shift alone, since a menu folds
// Shift into the equivalent and nothing else; other pairs are never asked.
typedef NSString *_Nullable (*VibeShortcutSpellingRule)(VibeShortcut shortcut);
// An app's own rules for the table helpers below. The plain helpers take
// kVibeShortcutDefaultRules.
typedef struct {
    VibeShortcutReservedRule _Nullable isReserved;  // NULL: VibeShortcutIsReserved
    BOOL overridesOutrankOrder;                     // a stored override beats table order
    VibeShortcutSpellingRule _Nullable spelling;    // NULL: same key only by encoding
} VibeShortcutRules;

static const VibeShortcutRules kVibeShortcutDefaultRules = {NULL, NO, NULL};

static inline BOOL VibeShortcutIsReservedUnderRules(VibeShortcutRules rules, unsigned short keyCode,
                                                    unichar character, NSEventModifierFlags modifiers) {
    return rules.isReserved ? rules.isReserved(VibeShortcutCanonicalKeyCode(keyCode), character,
                                               modifiers & kVibeShortcutModifierMask)
                            : VibeShortcutIsReserved(keyCode, character, modifiers);
}

// What a recording comes to: stored, or refused before anything is stored.
typedef NS_ENUM(NSInteger, VibeShortcutAssignment) {
    VibeShortcutAssignmentStored,
    VibeShortcutAssignmentReserved,   // the rules' reserved rule
    VibeShortcutAssignmentUnusable,   // a key no layout names, so no menu could draw it
};

// The command a key performs, or a recorded one would collide with, nil for
// none: a key-code shortcut matched by physical key, a character default by
// character (the key's lowercase character, 0 when unknown), each with the
// exact modifier set, or by the rules' spelling. A character shortcut passed
// in matches by its own character alone. The rules' order resolves a
// duplicate.
static inline NSString *_Nullable VibeShortcutOwnerUnderRules(NSArray<NSArray *> *commands, VibeShortcut shortcut,
        unichar character, NSDictionary *_Nullable overrides, NSString *_Nullable excluding,
        VibeShortcutRules rules) {
    if (shortcut == kVibeShortcutNone) {
        return nil;
    }
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    unsigned short keyCode = kVibeShortcutKeyMask;
    if (VibeShortcutIsCharacter(shortcut)) {
        character = VibeShortcutKey(shortcut);
    } else {
        keyCode = VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut));
    }
    NSString *spelled = nil;
    if (rules.spelling) {
        // A character default no key types spells as its character.
        spelled = keyCode != kVibeShortcutKeyMask ? rules.spelling(VibeShortcutMake(keyCode, modifiers)) : nil;
        if (!spelled && character != 0) {
            spelled = rules.spelling(VibeShortcutMakeCharacter(character, modifiers));
        }
    }
    NSString *firstAtDefault = nil;
    for (NSArray *entry in commands) {
        NSString *identifier = entry[0];
        if (excluding && [identifier isEqualToString:excluding]) {
            continue;
        }
        id stored = overrides[identifier];
        BOOL overridden = VibeShortcutIsStorable(stored);
        VibeShortcut owned = overridden ? [stored unsignedIntegerValue] : [entry[1] unsignedIntegerValue];
        if (owned == kVibeShortcutNone) {
            continue;
        }
        NSEventModifierFlags ownedModifiers = VibeShortcutModifiers(owned);
        BOOL same = ownedModifiers == modifiers
                && (VibeShortcutIsCharacter(owned) ? character != 0 && VibeShortcutKey(owned) == character
                                                   : VibeShortcutKey(owned) == keyCode);
        if (!same && spelled && ((ownedModifiers ^ modifiers) & ~NSEventModifierFlagShift) == 0) {
            same = [rules.spelling(owned) isEqualToString:spelled];
        }
        if (!same) {
            continue;
        }
        if (!rules.overridesOutrankOrder || overridden) {
            return identifier;
        }
        firstAtDefault = firstAtDefault ?: identifier;
    }
    return firstAtDefault;
}

// Under the default rules: a hand-edited duplicate resolves in table order.
static inline NSString *_Nullable VibeShortcutOwner(NSArray<NSArray *> *commands, VibeShortcut shortcut,
        unichar character, NSDictionary *_Nullable overrides, NSString *_Nullable excluding) {
    return VibeShortcutOwnerUnderRules(commands, shortcut, character, overrides, excluding,
                                       kVibeShortcutDefaultRules);
}

// Reserved keys carry no equivalent. Duplicate bindings go to the command
// the rules' order puts first, as in the key monitor.
// layoutKeyCode maps a character default, or kVibeShortcutKeyMask for none.
// layoutCharacter maps a physical key, or 0 for none.
static inline VibeShortcut VibeShortcutForMenuItemUnderRules(NSArray<NSArray *> *commands, NSString *identifier,
        VibeShortcut shortcut, unsigned short layoutKeyCode, unichar layoutCharacter,
        NSDictionary *_Nullable overrides, VibeShortcutRules rules) {
    if (shortcut == kVibeShortcutNone) {
        return kVibeShortcutNone;
    }
    BOOL isCharacter = VibeShortcutIsCharacter(shortcut);
    unsigned short keyCode = isCharacter ? layoutKeyCode : VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut));
    unichar character = isCharacter ? VibeShortcutKey(shortcut) : layoutCharacter;
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    if (VibeShortcutIsReservedUnderRules(rules, keyCode, character, modifiers)) {
        return kVibeShortcutNone;
    }
    NSString *owner = VibeShortcutOwnerUnderRules(commands, VibeShortcutMake(keyCode, modifiers), character,
                                                  overrides, nil, rules);
    return owner == nil || [owner isEqualToString:identifier] ? shortcut : kVibeShortcutNone;
}

static inline VibeShortcut VibeShortcutForMenuItem(NSArray<NSArray *> *commands, NSString *identifier,
        VibeShortcut shortcut, unsigned short layoutKeyCode, unichar layoutCharacter,
        NSDictionary *_Nullable overrides) {
    return VibeShortcutForMenuItemUnderRules(commands, identifier, shortcut, layoutKeyCode, layoutCharacter,
                                             overrides, kVibeShortcutDefaultRules);
}

// The command a press performs, nil to pass it on. Under Command a layout's
// ⌘ layer (Dvorak – QWERTY ⌘, Greek) types the Latin letter the menu bar
// matches while Option bends it (⌥⌘S types ß), so the press is tried as what
// it typed, 0 without ⌘, and as what it types unmodified. A key-code binding
// can land on a reserved shortcut after a layout switch; the system's wins.
static inline NSString *_Nullable VibeShortcutCommandForPressUnderRules(NSArray<NSArray *> *commands,
        unsigned short keyCode, NSEventModifierFlags modifiers, unichar typed, unichar unmodified,
        NSDictionary *_Nullable overrides, VibeShortcutRules rules) {
    keyCode = VibeShortcutCanonicalKeyCode(keyCode);
    modifiers &= kVibeShortcutModifierMask;
    if (VibeShortcutIsReservedUnderRules(rules, keyCode, typed, modifiers)
            || VibeShortcutIsReservedUnderRules(rules, keyCode, unmodified, modifiers)) {
        return nil;
    }
    VibeShortcut pressed = VibeShortcutMake(keyCode, modifiers);
    NSString *owner = typed != 0 && typed != unmodified
            ? VibeShortcutOwnerUnderRules(commands, pressed, typed, overrides, nil, rules) : nil;
    return owner ?: VibeShortcutOwnerUnderRules(commands, pressed, unmodified, overrides, nil, rules);
}

static inline NSString *_Nullable VibeShortcutCommandForPress(NSArray<NSArray *> *commands,
        unsigned short keyCode, NSEventModifierFlags modifiers, unichar typed, unichar unmodified,
        NSDictionary *_Nullable overrides) {
    return VibeShortcutCommandForPressUnderRules(commands, keyCode, modifiers, typed, unmodified, overrides,
                                                 kVibeShortcutDefaultRules);
}

// What the overrides hold for identifier: nil at its default, so the store
// stays sparse.
static inline NSNumber *_Nullable VibeShortcutStoredValue(NSArray<NSArray *> *commands, NSString *identifier,
                                                          VibeShortcut shortcut) {
    return shortcut == VibeShortcutDefault(commands, identifier) ? nil : @(shortcut);
}

// The overrides after giving identifier shortcut (None clears it). A command
// that held the shortcut loses it and is named in *loser; the recording
// wins rather than being refused. The caller has already refused a reserved
// shortcut. An identifier that is not in the table changes nothing. A
// recording is a key-code shortcut or None, never a character shortcut.
// When overrides outrank table order, every other command that holds the
// shortcut loses it, since a later holder would otherwise surface; *loser
// names the one that carried it. With a spelling, a recording a menu spells
// as identifier's default is the default.
static inline NSDictionary<NSString *, NSNumber *> *VibeShortcutOverridesByAssigningUnderRules(
        NSArray<NSArray *> *commands, NSDictionary *_Nullable overrides, NSString *identifier,
        VibeShortcut shortcut, unichar character, NSString *_Nullable *_Nullable loser, VibeShortcutRules rules) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    BOOL known = NO;
    for (NSArray *entry in commands) {
        NSString *command = entry[0];
        known = known || [command isEqualToString:identifier];
        if (VibeShortcutIsStorable(overrides[command])) {
            result[command] = overrides[command];
        }
    }
    NSString *owner = nil;
    if (known) {
        shortcut = VibeShortcutCanonical(shortcut);
        owner = VibeShortcutOwnerUnderRules(commands, shortcut, character, result, identifier, rules);
        for (NSString *holder = owner; holder;) {
            result[holder] = VibeShortcutStoredValue(commands, holder, kVibeShortcutNone);
            holder = rules.overridesOutrankOrder
                    ? VibeShortcutOwnerUnderRules(commands, shortcut, character, result, identifier, rules) : nil;
        }
        NSString *spelled = rules.spelling && shortcut != kVibeShortcutNone ? rules.spelling(shortcut) : nil;
        VibeShortcut ownDefault = VibeShortcutDefault(commands, identifier);
        BOOL spellsDefault = spelled && ownDefault != kVibeShortcutNone
                && [rules.spelling(ownDefault) isEqualToString:spelled];
        result[identifier] = spellsDefault ? nil : VibeShortcutStoredValue(commands, identifier, shortcut);
    }
    if (loser) {
        *loser = owner;
    }
    return result;
}

static inline NSDictionary<NSString *, NSNumber *> *VibeShortcutOverridesByAssigning(
        NSArray<NSArray *> *commands, NSDictionary *_Nullable overrides, NSString *identifier,
        VibeShortcut shortcut, unichar character, NSString *_Nullable *_Nullable loser) {
    return VibeShortcutOverridesByAssigningUnderRules(commands, overrides, identifier, shortcut, character, loser,
                                                      kVibeShortcutDefaultRules);
}

NS_ASSUME_NONNULL_END
