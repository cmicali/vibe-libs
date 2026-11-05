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
@interface VibeDebugCaptureRequest : NSObject
@property (nonatomic) VibeDebugCaptureFocus focus;
// Makes the window key, and the app active, before the capture.
@property (nonatomic) BOOL key;
// A crop in points from the framed region's top left. Empty for none.
@property (nonatomic) NSRect crop;
@end

// Parses capture_window's tokens, tokens[0] being the verb:
// [key] [menu|popover] [crop <x> <y> <w> <h>], and a trailing - or label,
// which is the client's. Nil, with *errorJSON set, on a bad token.
VibeDebugCaptureRequest *_Nullable VibeDebugParseCaptureRequest(NSArray<NSString *> *tokens,
                                                                NSString *_Nullable *_Nonnull errorJSON);

// The region to capture, in Cocoa screen coordinates: the window's frame,
// grown to take in each extra frame (a menu's or a popover's) for the window
// focus, or the extras' union with a margin for the others, then cropped.
// NSZeroRect when the focus has no frames, or the crop misses the region.
NSRect VibeDebugCaptureRegion(NSRect windowFrame, NSArray<NSValue *> *extraFrames,
                              VibeDebugCaptureFocus focus, NSRect crop);

// Why a capture can't run now, or nil: a locked screen, a sleeping display,
// or a window that isn't on screen. Each says to use dump_screenshot, the
// in-process render, instead.
NSString *_Nullable VibeDebugCaptureBlocker(NSWindow *window);

// Captures window, as the request frames it, to a PNG at path, and calls
// completion on main with the verb's JSON reply: ok, path, width, height,
// scale, method, windowKey, appActive, region, and the windows it took in.
// Or an error reply, which names the in-process render as the fallback.
// Main thread only.
void VibeDebugCaptureWindow(NSWindow *window, VibeDebugCaptureRequest *request, NSString *path,
                            void (^completion)(NSString *replyJSON));

NS_ASSUME_NONNULL_END
