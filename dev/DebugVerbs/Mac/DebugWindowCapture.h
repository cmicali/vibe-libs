//
//  DebugWindowCapture.h
//  vibe-libs
//
//  The real capture behind capture_window: the app's own windows as the
//  window server composites them, through ScreenCaptureKit. Glass, vibrancy,
//  blending, the title bar, the toolbar, sheets, popovers, and open menus all
//  show as they do on screen. It never captures another app's window, the
//  desktop, or the whole screen.
//
//  It needs no Screen Recording permission: since macOS 14.4 a process may
//  capture its own windows. It needs an unlocked screen and an awake display,
//  and the window on screen, not minimized or hidden. Where it can't run, it
//  says why and names dump_screenshot, the in-process render, instead.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// What the capture frames.
typedef NS_ENUM(NSInteger, VibeDebugCaptureFocus) {
    // The window, plus any menu or popover of the app's that sticks out of it.
    VibeDebugCaptureFocusWindow,
    // The open menus alone, with a margin.
    VibeDebugCaptureFocusMenu,
    // The showing popovers alone, with a margin.
    VibeDebugCaptureFocusPopover,
};

// A capture_window command's arguments.
typedef struct {
    VibeDebugCaptureFocus focus;
    // Makes the window key, and the app active, before the capture.
    BOOL key;
    // A crop in points from the framed region's top left. Empty for none.
    NSRect crop;
} VibeDebugCaptureRequest;

// Parses capture_window's tokens, tokens[0] being the verb:
// [key] [menu|popover] [crop <x> <y> <w> <h>], and the client's -. NO, with
// *errorJSON set, on a bad token.
BOOL VibeDebugParseCaptureRequest(NSArray<NSString *> *tokens, VibeDebugCaptureRequest *request,
                                  NSString *_Nullable *_Nonnull errorJSON);

// The region to capture, in Cocoa screen coordinates: the window's frame,
// grown to take in each extra frame (a menu's or a popover's) for the window
// focus, or the extras' union with a margin for the others, then cropped.
// NSZeroRect when the focus has no frames, or the crop misses the region.
NSRect VibeDebugCaptureRegion(NSRect windowFrame, NSArray<NSValue *> *extraFrames,
                              VibeDebugCaptureFocus focus, NSRect crop);

// Why a capture can't run now, or nil: a locked screen, a sleeping display,
// or a window that isn't on screen. *kind is locked, asleep, or hidden, the
// error reply's blocker. Each message names dump_screenshot instead.
NSString *_Nullable VibeDebugCaptureBlocker(NSWindow *window, NSString *_Nullable *_Nullable kind);

// Whether the screen is locked, when no app can become active and the window
// server draws no window.
BOOL VibeDebugScreenIsLocked(void);

// Whether the display window is on, or the main display, is asleep.
BOOL VibeDebugDisplayIsAsleep(NSWindow *_Nullable window);

// A Cocoa screen rect, whose origin is the primary screen's bottom left, as
// Quartz's, whose origin is its top left, or back: the flip is its own
// inverse.
NSRect VibeDebugFlipScreenRect(NSRect rect);

// Captures window, as the request frames it, to a PNG at path, and calls
// completion on main with the verb's JSON reply: ok, path, width, height,
// scale, method, windowKey, appActive, occluded, dark, region (in points
// from the window's top left), and windows (each its id, kind, and title).
// Or an error reply, with blocker where the window server draws nothing,
// which names the in-process render as the fallback. Main thread only.
void VibeDebugCaptureWindow(NSWindow *window, VibeDebugCaptureRequest request, NSString *path,
                            void (^completion)(NSString *replyJSON));

NS_ASSUME_NONNULL_END
