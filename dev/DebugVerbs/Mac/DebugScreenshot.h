//
//  DebugScreenshot.h
//  vibe-libs
//
//  The in-process window render behind dump_screenshot, and a notifyutil hook
//  that runs the same render.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// What every in-process render's reply says of itself: for layout and text
// only, and capture_window for the real window.
extern NSString *const VibeDebugRenderNote;

// Renders window's frame view, the title bar and the toolbar with it, to a
// PNG at path. NO when the window has no content or the write fails.
//
// It renders the window's layer tree in-process, with no window-server
// capture, so it needs no permission and works with the display asleep or
// the window occluded. NSGlassEffectView and CABackdropLayer layers render
// white this way. So a backdrop gives way to an opaque, appearance-matched
// fill in its place, in its z-order, and a glass view is hidden, over the same
// fill, with its content rendered on top, in its place. So what a material
// covers on screen stays covered, such as rows scrolled under a toolbar or a
// header. Those changes force a model-tree render, so such a window's animations land at their target
// values. Any other window renders the presentation tree mid-flight. Metal
// content does not render either. The PNG's resolution is 72 dpi times the
// backing scale.
BOOL VibeDebugRenderWindow(NSWindow *window, NSString *path);

// VibeDebugRenderWindow of the key window, else the main window, else the
// frontmost visible one.
BOOL VibeDumpWindowSnapshot(NSString *path);

// Writes image to a PNG at path, its resolution 72 dpi times scale, so a
// reader of the file alone knows its points. NO when the write fails.
BOOL VibeDebugWritePNG(CGImageRef image, CGFloat scale, NSString *path);

// Renders to path whenever notificationName is posted, so a terminal can take
// a screenshot with no client:
//
//     notifyutil -p <notificationName>
//
// A sandboxed app's path is in its own container, so read it from there.
// dump_screenshot writes a file per command instead, so two clients taking
// screenshots back to back never read each other's pixels.
void VibeInstallDebugScreenshotHook(NSString *notificationName, NSString *path);

NS_ASSUME_NONNULL_END
