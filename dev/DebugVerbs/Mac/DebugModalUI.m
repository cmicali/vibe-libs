//
//  DebugModalUI.m
//  vibe-libs
//

#import "DebugModalUI.h"

#if DEBUG

#import "DebugWireFormat.h"

#import "DebugViewTree.h"

// Each kept weakly, in the order it showed or began tracking.
static NSPointerArray *gShownPopovers;
static NSPointerArray *gTrackingMenus;

// The object kept or dropped. A slot whose object went goes too, since
// compact leaves such a slot unless a NULL was added.
static void VibeDebugKeep(NSPointerArray *kept, id object, BOOL keep) {
    for (NSUInteger i = kept.count; i > 0; i--) {
        void *pointer = [kept pointerAtIndex:i - 1];
        if (!pointer || pointer == (__bridge void *)object) {
            [kept removePointerAtIndex:i - 1];
        }
    }
    if (keep) {
        [kept addPointer:(__bridge void *)object];
    }
}

static void VibeDebugObserve(NSNotificationName name, NSPointerArray *kept, BOOL keep) {
    [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
        VibeDebugKeep(kept, note.object, keep);
    }];
}

void VibeDebugWatchModalUI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gShownPopovers = [NSPointerArray weakObjectsPointerArray];
        gTrackingMenus = [NSPointerArray weakObjectsPointerArray];
        // Its will-show, since its did-show waits for the animation, and shown
        // is true from the will-show on.
        VibeDebugObserve(NSPopoverWillShowNotification, gShownPopovers, YES);
        VibeDebugObserve(NSPopoverDidCloseNotification, gShownPopovers, NO);
        VibeDebugObserve(NSMenuDidBeginTrackingNotification, gTrackingMenus, YES);
        VibeDebugObserve(NSMenuDidEndTrackingNotification, gTrackingMenus, NO);
    });
}

NSArray<NSPopover *> *VibeDebugShownPopovers(void) {
    // A popover closed with no notice, as when its window went, is no
    // longer shown.
    return [gShownPopovers.allObjects ?: @[] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
        NSPopover *popover, NSDictionary *bindings) {
        return popover.shown;
    }]];
}

NSArray<NSMenu *> *VibeDebugTrackingMenus(void) {
    return gTrackingMenus.allObjects ?: @[];
}

NSString *_Nullable VibeDebugPressButton(NSArray<NSButton *> *buttons, NSString *title) {
    for (NSButton *button in buttons) {
        if ([button.title isEqualToString:title]) {
            if (!button.enabled) {
                return VibeErrorJSON(@"%@ is disabled", title);
            }
            [button performClick:nil];
            return nil;
        }
    }
    return VibeErrorJSON(@"no button %@ in %@", title,
                         buttons.count ? [[buttons valueForKey:@"title"] componentsJoinedByString:@", "] : @"none");
}

NSString *VibeDebugAnswerModal(NSArray<NSWindow *> *owners, NSString *_Nullable title) {
    NSWindow *window = NSApp.modalWindow;
    BOOL modal = window != nil;
    for (NSUInteger i = 0; !window && i < owners.count; i++) {
        window = owners[i].attachedSheet;
    }
    if (!window) {
        return VibeJSONString(@{@"ok": @YES, @"sheet": @NO, @"modal": @NO});
    }
    BOOL panel = [window isKindOfClass:NSSavePanel.class];
    NSMutableDictionary *reply = [@{@"ok": @YES, @"sheet": @((BOOL)!modal), @"modal": @(modal), @"panel": @(panel)}
                                      mutableCopy];
    NSArray<NSButton *> *buttons = @[];
    if (panel) {
        // Out of process, so its one button is Cancel.
        NSString *message = ((NSSavePanel *)window).message;
        reply[@"texts"] = message.length ? @[message] : @[];
        reply[@"buttons"] = @[@"Cancel"];
    } else {
        buttons = VibeDebugButtonsUnder((NSView *)window.contentView);
        reply[@"texts"] = VibeDebugTextsUnder((NSView *)window.contentView);
        reply[@"buttons"] = [buttons valueForKey:@"title"];
    }
    if (!title) {
        return VibeJSONString(reply);
    }
    if (panel && ![title isEqualToString:@"Cancel"]) {
        return VibeErrorJSON(@"no button %@ in Cancel", title);
    }
    NSString *error = panel ? nil : VibeDebugPressButton(buttons, title);
    if (error) {
        return error;
    }
    if (panel) {
        [(NSSavePanel *)window cancel:nil];
    }
    if (modal) {
        // The session's loop looks at its stop only after an event.
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                                       modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0
                                               data2:0]
                 atStart:NO];
    }
    [reply removeObjectForKey:@"buttons"];
    reply[@"pressed"] = title;
    return VibeJSONString(reply);
}

#endif
