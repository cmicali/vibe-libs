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

// The input table: activate, key, key_down, key_up, click, mouse_down,
// mouse_up, mouse_move, drag, and scroll. An app opts into it beside the
// standard table. The mouse verbs and scroll aim at the options'
// targetWindow. With the options' requiresKeyWindow, a mouse verb fails, and
// posts nothing, while that window isn't key, since the window would swallow
// the click. The key verbs post into the key window. With none, as when the
// app is behind, they send to the target window directly. activate makes the
// target window key and the app active, from inside the app, if macOS lets it.
NSArray<NSDictionary *> *VibeDebugInputVerbs(VibeDebugStandardOptions *options);

// Nil while window is key. Otherwise the error reply verb answers, which says
// what is in front and to run activate first. Main thread only.
NSString *_Nullable VibeDebugInputFocusError(NSWindow *window, NSString *verb);

// Makes window key and the app active, as a click on the window would, and
// calls completion on main once both took, with nil, or after five seconds,
// with the error reply: a locked screen, or macOS keeping another app in
// front. It takes the keyboard from the app in front. Main thread only.
void VibeDebugActivateWindow(NSWindow *window, void (^completion)(NSString *_Nullable errorJSON));

// Deprecated: an app's own verb checks VibeDebugInputFocusError and leaves
// activation to the activate verb. Activates the app and spins the run loop up
// to a second for window to become key. It carries no deprecated attribute,
// since a caller that treats warnings as errors would stop building.
void VibeMakeWindowKeyForInjection(NSWindow *window);

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

// tokens[0] is the verb: click, mouse_down, mouse_up, or mouse_move. It
// posts whether or not window is key: the input table checks first, and a
// caller of its own checks VibeDebugInputFocusError.
NSString *VibeInjectMouse(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectDrag(NSWindow *window, NSArray<NSString *> *tokens);
NSString *VibeInjectScroll(NSWindow *window, NSArray<NSString *> *tokens);

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
