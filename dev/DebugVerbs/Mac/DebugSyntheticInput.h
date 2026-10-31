//
//  DebugSyntheticInput.h
//  vibe-libs
//
//  Synthesized key, mouse, drag, and scroll events, posted into the app's own
//  event queue. Each poster answers the verb's JSON reply.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

@class VibeDebugStandardOptions;

NS_ASSUME_NONNULL_BEGIN

// The input table: key, key_down, key_up, click, mouse_down, mouse_up,
// mouse_move, drag, and scroll. An app opts into it beside the standard
// table. The mouse verbs and scroll aim at the options' targetWindow. The key
// verbs post into the key window. When the app has none, as when it is not
// active, they send to the target window directly, and the app stays behind.
NSArray<NSDictionary *> *VibeDebugInputVerbs(VibeDebugStandardOptions *options);

// tokens[0] is the verb: key, key_down, or key_up. Posts into window while
// the app has a key window. With none, sends to window after the reply, through
// VibeSendKeyToWindow. The reply's queued says which.
NSString *VibeInjectKey(NSWindow *window, NSArray<NSString *> *tokens, BOOL down, BOOL up);

// Hands a key event to window as NSApp hands one to its key window, but with
// no key status needed, and with window standing in for the key window.
// Local monitors never see it.
void VibeSendKeyToWindow(NSWindow *window, NSEvent *event);

// Runs block with window standing in for the key window when AppKit looks up
// an action's target. A menu item with no target, or a sendAction:to:nil,
// that finds none then looks in window's responder chain, then its delegate.
// An app that is not active has no key window, so without one such an item
// reads as disabled. A nil window runs block as it is. Main thread only.
void VibeWithStandInKeyWindow(NSWindow *_Nullable window, void (NS_NOESCAPE ^block)(void));

// tokens[0] is the verb: click, mouse_down, mouse_up, or mouse_move. Makes
// window key first.
NSString *VibeInjectMouse(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectDrag(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectScroll(NSWindow *window, NSArray<NSString *> *tokens);

// Activates the app and spins the run loop up to a second for window to
// become key. A non-key window swallows a first click.
void VibeMakeWindowKeyForInjection(NSWindow *window);

// Content-view points with a top-left origin, the frame dump_screenshot
// renders, to and from window points.
NSPoint VibeWindowPointForContentPoint(NSWindow *window, double x, double y);
NSPoint VibeContentPointForWindowPoint(NSWindow *window, NSPoint point);

// The ANSI key code for a key name the key verbs take, lowercased, or nil.
NSNumber *_Nullable VibeKeyCodeForName(NSString *name);

// The modifier names in tokens from start on, plus the repeat token. NO with
// *errorJSON set to the reply on an unknown name.
BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start, NSEventModifierFlags *flags,
                        BOOL *repeat, NSString *_Nullable *_Nonnull errorJSON);

NS_ASSUME_NONNULL_END
