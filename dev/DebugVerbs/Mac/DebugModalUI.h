//
//  DebugModalUI.h
//  vibe-libs
//
//  What answers the windows that ask: a sheet, an app-modal window, an open
//  or save panel, a popover, and a menu that is open. answer_sheet,
//  answer_popover, and answer_menu read these. An app's own sheet verb may
//  call VibeDebugAnswerModal with windows in its own order.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Starts keeping the popovers that show and the menus that track, from their
// notifications. Once is enough, and a second call does nothing. The standard
// table's build calls it, so a popover or a menu opened before it is missed.
void VibeDebugWatchModalUI(void);

// The popovers showing now, oldest first.
NSArray<NSPopover *> *VibeDebugShownPopovers(void);

// The menus tracking now, outermost first: a pop-up, a context menu, or the
// menu bar's.
NSArray<NSMenu *> *VibeDebugTrackingMenus(void);

// Presses the button with the title, as a click does: nil, or the error to
// reply when none has it or it is disabled.
NSString *_Nullable VibeDebugPressButton(NSArray<NSButton *> *buttons, NSString *title);

// The window that asks, and its answer: NSApp.modalWindow, else the first of
// owners' attached sheets. With no button, its texts and buttons. With a
// button's title, that button pressed, as a click does. sheet and modal say
// which asks, and panel says it is an open or save panel, whose one button
// is Cancel (dev/DebugVerbs/AGENTS.md, "The windows that ask").
NSString *VibeDebugAnswerModal(NSArray<NSWindow *> *owners, NSString *_Nullable button);

NS_ASSUME_NONNULL_END
