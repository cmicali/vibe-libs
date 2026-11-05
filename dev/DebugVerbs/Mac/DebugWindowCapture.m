//
//  DebugWindowCapture.m
//  vibe-libs
//

#import "DebugWindowCapture.h"

#if DEBUG

#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#import "DebugModalUI.h"
#import "DebugScreenshot.h"
#import "DebugSyntheticInput.h"
#import "DebugWireFormat.h"
#import "NSView+DarkMode.h"

// A menu's or a popover's frame with this much room around it, so its shadow
// and its edge show.
static const CGFloat VibeCaptureMargin = 12;

static NSString *const VibeCaptureFallback = @"dump_screenshot renders in-process instead, for layout and text only";

BOOL VibeDebugParseCaptureRequest(NSArray<NSString *> *tokens, VibeDebugCaptureRequest *request,
                                  NSString **errorJSON) {
    NSDictionary<NSString *, NSNumber *> *focuses = @{
        @"menu": @(VibeDebugCaptureFocusMenu),
        @"popover": @(VibeDebugCaptureFocusPopover),
    };
    *request = (VibeDebugCaptureRequest){VibeDebugCaptureFocusWindow, NO, NSZeroRect};
    for (NSUInteger i = 1; i < tokens.count; i++) {
        NSString *token = tokens[i];
        NSNumber *focus = focuses[token];
        if (focus) {
            if (request->focus != VibeDebugCaptureFocusWindow) {
                *errorJSON = VibeErrorJSON(@"capture_window takes one of menu and popover, not both");
                return NO;
            }
            request->focus = focus.integerValue;
        }
        else if ([token isEqualToString:@"key"]) {
            request->key = YES;
        }
        else if ([token isEqualToString:@"crop"]) {
            double values[4] = {0, 0, 0, 0};
            BOOL parsed = i + 4 < tokens.count;
            for (NSUInteger j = 0; parsed && j < 4; j++) {
                parsed = VibeParseDouble(tokens[i + 1 + j], &values[j]);
            }
            if (!parsed || values[2] <= 0 || values[3] <= 0) {
                *errorJSON = VibeErrorJSON(@"crop takes <x> <y> <w> <h>, in points from the region's top left, "
                                           @"with a width and a height above 0");
                return NO;
            }
            request->crop = NSMakeRect(values[0], values[1], values[2], values[3]);
            i += 4;
        }
        // The client's own: - writes the PNG to stdout.
        else if (![token isEqualToString:@"-"]) {
            *errorJSON = VibeErrorJSON(@"usage: capture_window [key] [menu|popover] [crop <x> <y> <w> <h>] [-]");
            return NO;
        }
    }
    return YES;
}

NSRect VibeDebugCaptureRegion(NSRect windowFrame, NSArray<NSValue *> *extraFrames, VibeDebugCaptureFocus focus,
                              NSRect crop) {
    NSRect region = focus == VibeDebugCaptureFocusWindow ? windowFrame : NSZeroRect;
    for (NSValue *value in extraFrames) {
        NSRect frame = value.rectValue;
        if (focus != VibeDebugCaptureFocusWindow) {
            frame = NSInsetRect(frame, -VibeCaptureMargin, -VibeCaptureMargin);
        }
        region = NSIsEmptyRect(region) ? frame : NSUnionRect(region, frame);
    }
    if (NSIsEmptyRect(region) || NSIsEmptyRect(crop)) {
        return region;
    }
    // The crop's origin is the region's top left, and Cocoa's y runs up.
    NSRect cropped = NSMakeRect(NSMinX(region) + NSMinX(crop), NSMaxY(region) - NSMinY(crop) - NSHeight(crop),
                                NSWidth(crop), NSHeight(crop));
    return NSIntersectionRect(region, cropped);
}

BOOL VibeDebugScreenIsLocked(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[@"CGSSessionScreenIsLocked"] boolValue];
}

BOOL VibeDebugDisplayIsAsleep(NSWindow *window) {
    NSNumber *screen = window.screen.deviceDescription[@"NSScreenNumber"];
    return CGDisplayIsAsleep(screen ? (CGDirectDisplayID)screen.unsignedIntValue : CGMainDisplayID()) != 0;
}

NSRect VibeDebugFlipScreenRect(NSRect rect) {
    CGFloat primaryHeight = NSMaxY(NSScreen.screens.firstObject.frame);
    return NSMakeRect(NSMinX(rect), primaryHeight - NSMaxY(rect), NSWidth(rect), NSHeight(rect));
}

NSString *VibeDebugCaptureBlocker(NSWindow *window, NSString **kind) {
    NSString *found = nil, *message = nil;
    if (VibeDebugScreenIsLocked()) {
        found = @"locked";
        message = @"the screen is locked, so the window server draws no window to capture; wait for the user to "
                  @"unlock it";
    }
    else if (VibeDebugDisplayIsAsleep(window)) {
        found = @"asleep";
        message = @"the display is asleep, so the window server draws no window to capture";
    }
    else if (!window.isVisible || window.isMiniaturized) {
        found = @"hidden";
        message = window.isMiniaturized ? @"the window is minimized, so there is nothing to capture"
                                        : @"the window isn't on screen, so there is nothing to capture";
    }
    if (kind) {
        *kind = found;
    }
    return message ? [NSString stringWithFormat:@"%@. %@", message, VibeCaptureFallback] : nil;
}

static NSDictionary *VibeRectJSON(NSRect rect) {
    return @{@"x": @(NSMinX(rect)), @"y": @(NSMinY(rect)), @"width": @(NSWidth(rect)), @"height": @(NSHeight(rect))};
}

// The window's sheets and child windows, a popover's among them, nested,
// each with its kind. What a sheet owns is the sheet's: on macOS 26 its
// glass is a child window of its own, which the window server draws in the
// sheet's place.
static void VibeCollectOwnedWindows(NSWindow *window, NSString *_Nullable inherited,
                                    NSMutableArray<NSWindow *> *windows, NSMutableArray<NSString *> *kinds) {
    for (NSWindow *child in [window.sheets arrayByAddingObjectsFromArray:window.childWindows ?: @[]]) {
        if (child.isVisible && ![windows containsObject:child]) {
            NSString *kind = inherited ?: ([window.sheets containsObject:child] ? @"sheet" : @"child");
            [windows addObject:child];
            [kinds addObject:kind];
            VibeCollectOwnedWindows(child, [kind isEqualToString:@"sheet"] ? kind : inherited, windows, kinds);
        }
    }
}

static void VibeCapture(NSWindow *window, VibeDebugCaptureRequest request, NSString *path,
                        SCShareableContent *content, void (^completion)(NSString *)) API_AVAILABLE(macos(14.4));

void VibeDebugCaptureWindow(NSWindow *window, VibeDebugCaptureRequest request, NSString *path,
                            void (^completion)(NSString *replyJSON)) {
    NSString *kind = nil;
    NSString *blocker = VibeDebugCaptureBlocker(window, &kind);
    if (blocker) {
        completion(VibeJSONString(@{@"error": blocker, @"blocker": kind}));
        return;
    }
    if (@available(macOS 14.4, *)) {
        void (^capture)(void) = ^{
            // The process's own windows, which it may capture with no consent
            // from the user. A getShareableContent… call would list every
            // app's, and needs Screen Recording.
            [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *shared,
                                                                                         NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!shared) {
                        completion(VibeErrorJSON(@"ScreenCaptureKit lists no content for this app: %@. %@",
                                                 error.localizedDescription, VibeCaptureFallback));
                        return;
                    }
                    VibeCapture(window, request, path, shared, completion);
                });
            }];
        };
        if (!request.key || (NSApp.isActive && window.isKeyWindow)) {
            capture();
            return;
        }
        VibeDebugActivateWindow(window, ^(NSString *error) {
            if (error) {
                completion(error);
                return;
            }
            // The window draws as key on its next pass, which the flush
            // commits. A frame later the window server has composited it.
            [window displayIfNeeded];
            [CATransaction flush];
            NSInteger fps = MAX(window.screen.maximumFramesPerSecond, 30);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / fps)), dispatch_get_main_queue(),
                           capture);
        });
    }
    else {
        completion(VibeErrorJSON(@"capture_window needs macOS 14.4, for ScreenCaptureKit's own-process capture. %@",
                                 VibeCaptureFallback));
    }
}

static void VibeCapture(NSWindow *window, VibeDebugCaptureRequest request, NSString *path,
                        SCShareableContent *content, void (^completion)(NSString *)) API_AVAILABLE(macos(14.4)) {
    // The list names other processes' windows too, redacted. Only this app's
    // are ever taken in.
    pid_t pid = NSProcessInfo.processInfo.processIdentifier;
    NSMutableDictionary<NSNumber *, SCWindow *> *byID = [NSMutableDictionary dictionary];
    for (SCWindow *scWindow in content.windows) {
        if (scWindow.owningApplication.processID == pid && scWindow.isOnScreen) {
            byID[@(scWindow.windowID)] = scWindow;
        }
    }
    SCWindow *main = byID[@(window.windowNumber)];
    if (!main) {
        completion(VibeErrorJSON(@"the window server lists no window %ld on screen for this app. %@",
                                 (long)window.windowNumber, VibeCaptureFallback));
        return;
    }
    NSMutableSet<NSNumber *> *popoverIDs = [NSMutableSet set];
    for (NSPopover *popover in VibeDebugShownPopovers()) {
        [popoverIDs addObject:@(popover.contentViewController.view.window.windowNumber)];
    }
    // The window, then what it owns, then the popovers and the open menus,
    // each once, with its kind.
    NSMutableArray<SCWindow *> *included = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *described = [NSMutableArray array];
    NSMutableArray<NSValue *> *menuFrames = [NSMutableArray array];
    NSMutableArray<NSValue *> *popoverFrames = [NSMutableArray array];
    void (^include)(SCWindow *, NSString *) = ^(SCWindow *scWindow, NSString *kind) {
        if (!scWindow || [included containsObject:scWindow]) {
            return;
        }
        [included addObject:scWindow];
        [described addObject:@{@"id": @(scWindow.windowID), @"kind": kind, @"title": scWindow.title ?: @""}];
        NSValue *frame = [NSValue valueWithRect:VibeDebugFlipScreenRect(scWindow.frame)];
        if ([kind isEqualToString:@"menu"]) {
            [menuFrames addObject:frame];
        }
        else if ([kind isEqualToString:@"popover"]) {
            [popoverFrames addObject:frame];
        }
    };
    include(main, @"window");
    NSMutableArray<NSWindow *> *owned = [NSMutableArray array];
    NSMutableArray<NSString *> *kinds = [NSMutableArray array];
    VibeCollectOwnedWindows(window, nil, owned, kinds);
    [owned enumerateObjectsUsingBlock:^(NSWindow *child, NSUInteger i, BOOL *stop) {
        NSNumber *number = @(child.windowNumber);
        include(byID[number], [popoverIDs containsObject:number] ? @"popover" : kinds[i]);
    }];
    for (NSNumber *number in popoverIDs) {
        include(byID[number], @"popover");
    }
    // A menu's window is the app's own, at the pop-up menu's level, and only
    // the window server lists it. The menu bar itself is the system's. A menu
    // that stopped tracking fades out a moment longer, and is left out.
    BOOL tracking = VibeDebugTrackingMenus().count > 0;
    for (SCWindow *scWindow in tracking ? byID.allValues : @[]) {
        if (scWindow.windowLayer >= kCGPopUpMenuWindowLevel && scWindow.windowLayer < kCGOverlayWindowLevel) {
            include(scWindow, @"menu");
        }
    }
    NSArray<NSValue *> *extras = request.focus == VibeDebugCaptureFocusMenu ? menuFrames
            : request.focus == VibeDebugCaptureFocusPopover ? popoverFrames
            : [menuFrames arrayByAddingObjectsFromArray:popoverFrames];
    // The window's own frame: the window server's can lie a point inside it.
    NSRect region = VibeDebugCaptureRegion(window.frame, extras, request.focus, request.crop);
    // The display that holds the region's middle, and what it holds of it.
    CGRect quartzRegion = VibeDebugFlipScreenRect(region);
    CGPoint middle = CGPointMake(CGRectGetMidX(quartzRegion), CGRectGetMidY(quartzRegion));
    SCDisplay *display = nil;
    for (SCDisplay *candidate in content.displays) {
        if (CGRectContainsPoint(candidate.frame, middle)) {
            display = candidate;
        }
    }
    CGRect source = display ? CGRectIntersection(quartzRegion, display.frame) : CGRectNull;
    if (CGRectIsEmpty(source)) {
        NSString *message = extras.count > 0 || request.focus == VibeDebugCaptureFocusWindow
                ? @"the crop lies outside the captured region, or the region off its display"
                : request.focus == VibeDebugCaptureFocusMenu
                ? @"no menu of this app is open; open one with a click first (answer_menu lists them)"
                : @"no popover of this app shows (answer_popover lists them)";
        completion(VibeErrorJSON(@"%@", message));
        return;
    }
    region = VibeDebugFlipScreenRect(source);
    // Only the app's own windows draw, over a clear background: no desktop,
    // no Dock, no menu bar, and no other app's window, wherever it sits.
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display includingWindows:included];
    CGFloat scale = filter.pointPixelScale;
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.sourceRect = CGRectOffset(source, -CGRectGetMinX(display.frame), -CGRectGetMinY(display.frame));
    config.width = (size_t)llround(CGRectGetWidth(source) * scale);
    config.height = (size_t)llround(CGRectGetHeight(source) * scale);
    config.showsCursor = NO;
    config.captureResolution = SCCaptureResolutionBest;
    config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    config.colorSpaceName = kCGColorSpaceSRGB;
    NSRect frame = window.frame;
    NSDictionary *reply = @{
        @"ok": @YES,
        @"path": path,
        @"scale": @(scale),
        @"method": @"ScreenCaptureKit",
        @"windowKey": @(window.isKeyWindow),
        @"appActive": @(NSApp.isActive),
        @"occluded": @((BOOL)!(window.occlusionState & NSWindowOcclusionStateVisible)),
        @"dark": @(window.effectiveAppearance.isDark),
        @"region": VibeRectJSON(NSMakeRect(NSMinX(region) - NSMinX(frame), NSMaxY(frame) - NSMaxY(region),
                                           NSWidth(region), NSHeight(region))),
        @"windows": described,
    };
    [SCScreenshotManager captureImageWithFilter:filter configuration:config
                              completionHandler:^(CGImageRef image, NSError *error) {
        // Encoded here, on ScreenCaptureKit's queue. Only the reply goes to
        // main.
        NSString *json = nil;
        if (!image) {
            json = VibeErrorJSON(@"ScreenCaptureKit couldn't capture the window: %@ (%@ %ld). %@",
                                 error.localizedDescription, error.domain, (long)error.code, VibeCaptureFallback);
        }
        else if (!VibeDebugWritePNG(image, scale, path)) {
            json = VibeErrorJSON(@"the capture's PNG couldn't be written to %@", path);
        }
        else {
            NSMutableDictionary *answer = [reply mutableCopy];
            answer[@"width"] = @(CGImageGetWidth(image));
            answer[@"height"] = @(CGImageGetHeight(image));
            json = VibeJSONString(answer);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(json);
        });
    }];
}

#endif
