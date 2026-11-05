//
//  DebugStandardMacVerbs.m
//  vibe-libs
//
//  The standard table's mac verbs: the view tree, the menus, the screenshot,
//  the window raise, and the windows that ask: sheets, modal windows,
//  panels, popovers, and open menus.
//

#import "DebugStandardVerbs.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugModalUI.h"
#import "DebugScreenshot.h"
#import "DebugSyntheticInput.h"
#import "DebugViewTree.h"
#import "DebugWindowCapture.h"
#import "DebugWireFormat.h"
#import "IntegerTokenRules.h"

static NSWindow *VibeDebugTargetWindow(VibeDebugStandardOptions *options, id controller) {
    return (options.targetWindow ? options.targetWindow(controller) : nil) ?: NSApp.mainWindow;
}

// click_menu's dispatch when the app passes none.
static BOOL VibeDebugPerformMenuItem(NSMenuItem *item) {
    // TRAP: AppKit gives a submenu parent submenuAction: even when it was
    // built with action:NULL, and sending that to a responder that does not
    // implement it aborts the app.
    if (item.hasSubmenu) {
        return NO;
    }
    [item.menu update]; // the validation pass opening the menu would run
    return item.isEnabled && !item.isHiddenOrHasHiddenAncestor && item.action
            && [NSApp sendAction:item.action to:item.target from:item];
}

NSArray<NSDictionary *> *VibeDebugStandardPlatformVerbs(VibeDebugStandardOptions *options) {
    VibeDebugWatchModalUI();
    return @[
        VibeDebugCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeViewTreeDump();
        }),
        VibeDebugCmd(@"dump_menu", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            __block NSArray *menu = nil;
            VibeWithStandInKeyWindow(NSApp.keyWindow ? nil : VibeDebugTargetWindow(options, controller), ^{
                menu = VibeMenuArray(NSApp.mainMenu);
            });
            // Behind, a stand-in key window validates the items, which can
            // differ from what the user would see in front.
            return VibeJSONString(@{@"menu": menu, @"appActive": @(NSApp.isActive)});
        }),
        VibeDebugCmd(@"dump_screenshot [- | <label>]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            // The arguments are the client's; see DebugClient.m.
            NSString *path = VibeDebugScreenshotPathForCommand(VibeDebugChannelName(), commandId);
            if (!VibeDumpWindowSnapshot(path)) {
                return VibeErrorJSON(@"screenshot failed to render or write; see app log");
            }
            // The size and scale come back from the file, so they are the
            // file's.
            // The render is no capture: say so in every reply.
            NSMutableDictionary *reply = [@{@"ok": @YES, @"path": path,
                    @"render": @"in-process, for layout and text only: glass, material, and blending draw flat. "
                               @"capture_window shows the real window"} mutableCopy];
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
            NSDictionary *properties = source
                    ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
            if (source) {
                CFRelease(source);
            }
            NSNumber *dpi = properties[(__bridge NSString *)kCGImagePropertyDPIWidth];
            reply[@"width"] = properties[(__bridge NSString *)kCGImagePropertyPixelWidth] ?: NSNull.null;
            reply[@"height"] = properties[(__bridge NSString *)kCGImagePropertyPixelHeight] ?: NSNull.null;
            reply[@"scale"] = dpi ? @(dpi.doubleValue / 72.0) : NSNull.null;
            return VibeJSONString(reply);
        }),
        // The target window as the window server composites it, with its
        // sheets, popovers, and open menus: glass, vibrancy, and blending
        // as on screen. Never another app's window. It replies later.
        VibeDebugCmd(@"capture_window [key] [menu|popover] [crop <x> <y> <w> <h>] [-]", 10,
                     ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            NSString *error = nil;
            VibeDebugCaptureRequest *request = VibeDebugParseCaptureRequest(tokens, &error);
            if (!request) {
                return error;
            }
            NSWindow *window = VibeDebugTargetWindow(options, controller);
            if (!window) {
                return VibeErrorJSON(@"no window to capture");
            }
            NSString *path = VibeDebugScreenshotPathForCommand(VibeDebugChannelName(), commandId);
            VibeDebugCaptureWindow(window, request, path, ^(NSString *reply) {
                VibeWriteDebugResponse(commandId, reply);
            });
            return nil;
        }),
        VibeDebugCmd(@"click_menu <identifier-or-title>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            if (tokens.count < 2) {
                return VibeErrorJSON(@"usage: click_menu <identifier-or-title>");
            }
            // The rest of the tokens, so titles with spaces work unquoted.
            NSString *name = VibeRestArgument(tokens);
            NSMenuItem *item = VibeFindMenuItem(NSApp.mainMenu, name);
            if (!item) {
                return VibeErrorJSON(@"no menu item with identifier or title '%@' (run `dump_menu` to list)", name);
            }
            // With no key window, as when the app is behind, the target
            // window stands in for it, so an item with no target finds one.
            BOOL behind = NSApp.keyWindow == nil;
            __block BOOL performed = NO;
            VibeWithStandInKeyWindow(NSApp.keyWindow ? nil : VibeDebugTargetWindow(options, controller), ^{
                performed = options.performMenuItem ? options.performMenuItem(controller, item)
                                                    : VibeDebugPerformMenuItem(item);
            });
            if (!performed) {
                if (item.hasSubmenu) {
                    return VibeErrorJSON(@"menu item '%@' opens a submenu; click one of its items", item.title);
                }
                if (item.isHiddenOrHasHiddenAncestor) {
                    return VibeErrorJSON(@"menu item '%@' is hidden", item.title);
                }
                // TRAP: behind, AppKit's own lookups skip the stand-in, such
                // as a window controller's supplementalTargetForAction:, so
                // an item with no target can read disabled only because the
                // app is behind.
                if (behind && !item.target) {
                    return VibeErrorJSON(@"menu item '%@' is %@ while the app is behind, which may be why: its target "
                                         @"may be one only a real key window finds. Run `activate`, then try again",
                                         item.title, item.isEnabled ? @"unhandled" : @"disabled");
                }
                return item.isEnabled
                        ? VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(item.action))
                        : VibeErrorJSON(@"menu item '%@' is disabled", item.title);
            }
            return VibeJSONString(@{
                @"ok": @YES,
                @"clicked": item.title,
                @"action": item.action ? NSStringFromSelector(item.action) : (id)NSNull.null,
                // Sent through the stand-in, with the app still behind.
                @"behind": @(behind),
            });
        }),
        // TRAP: a shell-driven launch lands behind the frontmost app (the
        // launch's cooperative activate is declined). An occluded window
        // shows nothing to a real capture, and the app may stop drawing it.
        // The channel keeps the app from being napped meanwhile
        // (dev/DebugChannel). Ordered front without activating, so the
        // frontmost app keeps the keyboard. No ordering helps a sleeping
        // display or a locked screen, where every window reads occluded.
        // Occlusion settles asynchronously, hence the spin.
        VibeDebugCmd(@"raise_window", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            NSWindow *window = VibeDebugTargetWindow(options, controller);
            if (!window) {
                return VibeErrorJSON(@"no window to raise");
            }
            [window orderFrontRegardless];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
            while (!(window.occlusionState & NSWindowOcclusionStateVisible) && deadline.timeIntervalSinceNow > 0) {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            return VibeJSONString(@{@"ok": @YES,
                    @"visible": @((BOOL)((window.occlusionState & NSWindowOcclusionStateVisible) != 0)),
                    @"displayAsleep": @((BOOL)(CGDisplayIsAsleep(CGMainDisplayID()) != 0))});
        }),
        // The alert that asks: an app-modal window, else the target window's
        // sheet, else any window's, front to back. With a button's title, the
        // rest of the tokens, it presses that button, as a click does.
        VibeDebugCmd(@"answer_sheet [button]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                              id controller) {
            NSMutableArray<NSWindow *> *owners = [NSApp.orderedWindows mutableCopy];
            NSWindow *target = VibeDebugTargetWindow(options, controller);
            if (target) {
                [owners insertObject:target atIndex:0];
            }
            return VibeDebugAnswerModal(owners, tokens.count > 1 ? VibeRestArgument(tokens) : nil);
        }),
        // The popovers showing, oldest first: their content's class, texts,
        // and buttons. With an index and close, that popover closes, as
        // Escape does. With an index and a button's title, the rest of the
        // tokens, it presses the button, as a click does.
        VibeDebugCmd(@"answer_popover [<index> <close|button>]", 0, ^NSString *(NSArray<NSString *> *tokens,
                                                                               NSString *commandId, id controller) {
            NSArray<NSPopover *> *popovers = VibeDebugShownPopovers();
            if (tokens.count == 1) {
                NSMutableArray *read = [NSMutableArray array];
                for (NSPopover *popover in popovers) {
                    NSView *content = popover.contentViewController.view;
                    [read addObject:@{
                        @"index": @(read.count),
                        @"content": popover.contentViewController.className ?: NSNull.null,
                        @"texts": content ? VibeDebugTextsUnder(content) : @[],
                        @"buttons": content ? [VibeDebugButtonsUnder(content) valueForKey:@"title"] : @[],
                    }];
                }
                return VibeJSONString(@{@"ok": @YES, @"popovers": read});
            }
            NSUInteger index = 0;
            if (tokens.count < 3 || !VibeParseNonnegativeInteger(tokens[1], &index)) {
                return VibeErrorJSON(@"usage: answer_popover [<index> <close|button>]");
            }
            if (index >= popovers.count) {
                return VibeErrorJSON(@"no popover %lu: %lu show", (unsigned long)index, (unsigned long)popovers.count);
            }
            NSPopover *popover = popovers[index];
            NSString *title = VibeRestArgument([tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]);
            if ([title isEqualToString:@"close"]) {
                [popover performClose:nil];
                return VibeJSONString(@{@"ok": @YES, @"closed": @YES});
            }
            NSView *content = popover.contentViewController.view;
            NSString *error = VibeDebugPressButton(content ? VibeDebugButtonsUnder(content) : @[], title);
            return error ?: VibeJSONString(@{@"ok": @YES, @"pressed": title});
        }),
        // The menus open now, outermost first, with their items as dump_menu
        // lists them. With cancel, each ends its tracking, as Escape does,
        // and no item is sent.
        VibeDebugCmd(@"answer_menu [cancel]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                             id controller) {
            BOOL cancel = tokens.count == 2 && [tokens[1] isEqualToString:@"cancel"];
            if (tokens.count > 1 && !cancel) {
                return VibeErrorJSON(@"usage: answer_menu [cancel]");
            }
            NSArray<NSMenu *> *menus = VibeDebugTrackingMenus();
            NSMutableArray *read = [NSMutableArray array];
            for (NSMenu *menu in menus) {
                [read addObject:@{@"title": menu.title ?: @"", @"items": VibeMenuArray(menu)}];
            }
            if (cancel) {
                for (NSMenu *menu in menus.reverseObjectEnumerator) {
                    [menu cancelTracking];
                }
            }
            return VibeJSONString(@{@"ok": @YES, @"menus": read, @"cancelled": @(cancel ? menus.count : 0)});
        }),
    ];
}

#endif
