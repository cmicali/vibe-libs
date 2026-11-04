//
//  DebugViewTree.h
//  vibe-libs
//
//  What dump_view_tree, dump_menu, and click_menu read: the windows and their
//  view trees, the menu bar, and the menu item search. And the shown texts
//  and buttons under a view, which the answer verbs read.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Every window and its content view's tree, as the JSON reply.
NSString *VibeViewTreeDump(void);

// menu's items, validated as opening the menu would validate them.
NSArray *VibeMenuArray(NSMenu *menu);

// The first item in menu or its submenus whose identifier or title is
// identifierOrTitle, or nil.
NSMenuItem *_Nullable VibeFindMenuItem(NSMenu *menu, NSString *identifierOrTitle);

// Every shown text field's text under the view, in order, breadth first.
NSArray<NSString *> *VibeDebugTextsUnder(NSView *view);

// Every shown button with a title under the view, in order, breadth first.
NSArray<NSButton *> *VibeDebugButtonsUnder(NSView *view);

NS_ASSUME_NONNULL_END
