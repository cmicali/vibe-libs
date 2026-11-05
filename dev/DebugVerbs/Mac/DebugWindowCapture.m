//
//  DebugWindowCapture.m
//  vibe-libs
//

#import "DebugWindowCapture.h"

#if DEBUG

#import <ScreenCaptureKit/ScreenCaptureKit.h>

#import "DebugModalUI.h"
#import "DebugScreenshot.h"
#import "DebugSyntheticInput.h"
#import "DebugWireFormat.h"

@implementation VibeDebugCaptureRequest
@end

// A menu's or a popover's frame with this much room around it, so its shadow
// and its edge show.
static const CGFloat VibeCaptureMargin = 12;

static NSString *VibeCaptureFallback(void) {
    return @"dump_screenshot renders in-process with none of that, for layout and text only";
}

VibeDebugCaptureRequest *VibeDebugParseCaptureRequest(NSArray<NSString *> *tokens, NSString **errorJSON) {
    NSString *usage = @"usage: capture_window [key] [menu|popover] [crop <x> <y> <w> <h>] [-]";
    VibeDebugCaptureRequest *request = [VibeDebugCaptureRequest new];
    request.crop = NSZeroRect;
    for (NSUInteger i = 1; i < tokens.count; i++) {
        NSString *token = tokens[i];
        if ([token isEqualToString:@"key"]) {
            request.key = YES;
        }
        else if (([token isEqualToString:@"menu"] || [token isEqualToString:@"popover"])
                 && request.focus == VibeDebugCaptureFocusWindow) {
            request.focus = [token isEqualToString:@"menu"] ? VibeDebugCaptureFocusMenu : VibeDebugCaptureFocusPopover;
        }
        else if ([token isEqualToString:@"crop"]) {
            double x = 0, y = 0, w = 0, h = 0;
            if (i + 4 >= tokens.count || !VibeParseDouble(tokens[i + 1], &x) || !VibeParseDouble(tokens[i + 2], &y)
                    || !VibeParseDouble(tokens[i + 3], &w) || !VibeParseDouble(tokens[i + 4], &h) || w <= 0 || h <= 0) {
                *errorJSON = VibeErrorJSON(@"crop takes <x> <y> <w> <h>, in points from the region's top left, "
                                           @"with a width and a height above 0");
                return nil;
            }
            request.crop = NSMakeRect(x, y, w, h);
            i += 4;
        }
        // The client's own: - writes the PNG to stdout.
        else if (![token isEqualToString:@"-"]) {
            *errorJSON = VibeErrorJSON(@"%@", usage);
            return nil;
        }
    }
    return request;
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

static BOOL VibeScreenIsLocked(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[@"CGSSessionScreenIsLocked"] boolValue];
}

NSString *VibeDebugCaptureBlocker(NSWindow *window) {
    if (VibeScreenIsLocked()) {
        return [NSString stringWithFormat:@"the screen is locked, so the window server draws no window to capture; "
                @"wait for the user to unlock it. %@", VibeCaptureFallback()];
    }
    CGDirectDisplayID display = (CGDirectDisplayID)[window.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    if (CGDisplayIsAsleep(display ?: CGMainDisplayID())) {
        return [NSString stringWithFormat:@"the display is asleep, so the window server draws no window to capture. %@",
                VibeCaptureFallback()];
    }
    if (!window.isVisible || window.isMiniaturized) {
        return [NSString stringWithFormat:@"the window isn't on screen (%@), so there is nothing to capture. %@",
                window.isMiniaturized ? @"it is minimized" : @"it is hidden", VibeCaptureFallback()];
    }
    return nil;
}

// The window's sheets and child windows, a popover's among them, nested.
static void VibeCollectOwnedWindows(NSWindow *window, NSMutableArray<NSWindow *> *out) {
    NSMutableArray<NSWindow *> *owned = [NSMutableArray arrayWithArray:window.sheets];
    if (window.attachedSheet && ![owned containsObject:window.attachedSheet]) {
        [owned addObject:window.attachedSheet];
    }
    [owned addObjectsFromArray:window.childWindows ?: @[]];
    for (NSWindow *child in owned) {
        if (child.isVisible && ![out containsObject:child]) {
            [out addObject:child];
            VibeCollectOwnedWindows(child, out);
        }
    }
}

// A Cocoa screen rect, whose origin is the primary screen's bottom left, as
// Quartz's, whose origin is its top left.
static CGRect VibeQuartzRect(NSRect rect) {
    CGFloat primaryHeight = NSMaxY(NSScreen.screens.firstObject.frame);
    return CGRectMake(NSMinX(rect), primaryHeight - NSMaxY(rect), NSWidth(rect), NSHeight(rect));
}

static NSRect VibeCocoaRect(CGRect rect) {
    CGFloat primaryHeight = NSMaxY(NSScreen.screens.firstObject.frame);
    return NSMakeRect(CGRectGetMinX(rect), primaryHeight - CGRectGetMaxY(rect), CGRectGetWidth(rect),
                      CGRectGetHeight(rect));
}

static NSString *VibeCaptureErrorJSON(NSError *error) API_AVAILABLE(macos(12.3)) {
    if ([error.domain isEqualToString:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined) {
        return VibeErrorJSON(@"capture_window needs Screen Recording permission for this app, which macOS keeps "
                             @"per code identity: grant it once in System Settings > Privacy & Security > "
                             @"Screen & System Audio Recording. %@", VibeCaptureFallback());
    }
    return VibeErrorJSON(@"ScreenCaptureKit couldn't capture the window: %@ (%@ %ld). %@",
                         error.localizedDescription, error.domain, (long)error.code, VibeCaptureFallback());
}

static NSDictionary *VibeRectJSON(NSRect rect) {
    return @{@"x": @(NSMinX(rect)), @"y": @(NSMinY(rect)), @"width": @(NSWidth(rect)), @"height": @(NSHeight(rect))};
}

static void VibeCapture(NSWindow *window, VibeDebugCaptureRequest *request, NSString *path,
                        SCShareableContent *content, void (^completion)(NSString *)) API_AVAILABLE(macos(14.4));

void VibeDebugCaptureWindow(NSWindow *window, VibeDebugCaptureRequest *request, NSString *path,
                            void (^completion)(NSString *replyJSON)) {
    NSString *blocker = VibeDebugCaptureBlocker(window);
    if (blocker) {
        completion(VibeErrorJSON(@"%@", blocker));
        return;
    }
    if (@available(macOS 14.4, *)) {
        if (request.key) {
            NSString *error = VibeDebugActivateWindow(window);
            if (error) {
                completion(error);
                return;
            }
            // The window redraws as key on its next pass.
            [window displayIfNeeded];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        }
        // The current process's own windows, which it may capture with no
        // permission from the user. A getShareableContent… call would list
        // every app's, and needs Screen Recording.
        [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content,
                                                                                     NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!content) {
                    completion(VibeCaptureErrorJSON(error));
                    return;
                }
                VibeCapture(window, request, path, content, completion);
            });
        }];
    }
    else {
        completion(VibeErrorJSON(@"capture_window needs macOS 14.4, for ScreenCaptureKit's own-process capture. %@",
                                 VibeCaptureFallback()));
    }
}

static void VibeCapture(NSWindow *window, VibeDebugCaptureRequest *request, NSString *path,
                        SCShareableContent *content, void (^completion)(NSString *)) API_AVAILABLE(macos(14.4)) {
    pid_t pid = NSProcessInfo.processInfo.processIdentifier;
    NSMutableDictionary<NSNumber *, SCWindow *> *byID = [NSMutableDictionary dictionary];
    // The list names other processes' windows too, redacted. Only this
    // app's are ever taken in.
    for (SCWindow *scWindow in content.windows) {
        if (scWindow.owningApplication.processID == pid) {
            byID[@(scWindow.windowID)] = scWindow;
        }
    }
    SCWindow *main = byID[@(window.windowNumber)];
    if (!main || !main.isOnScreen) {
        completion(VibeErrorJSON(@"the window server lists no window %ld on screen for this app. %@",
                                 (long)window.windowNumber, VibeCaptureFallback()));
        return;
    }
    // The window, then what it owns, then the popovers and the open menus.
    NSMutableArray<SCWindow *> *included = [NSMutableArray arrayWithObject:main];
    NSMutableArray<NSDictionary *> *described = [NSMutableArray arrayWithObject:@{
        @"id": @(main.windowID), @"kind": @"window", @"title": main.title ?: @"",
    }];
    NSMutableArray<NSValue *> *popoverFrames = [NSMutableArray array];
    NSMutableArray<NSValue *> *menuFrames = [NSMutableArray array];
    void (^include)(SCWindow *, NSString *) = ^(SCWindow *scWindow, NSString *kind) {
        if (!scWindow || !scWindow.isOnScreen || [included containsObject:scWindow]) {
            return;
        }
        [included addObject:scWindow];
        [described addObject:@{@"id": @(scWindow.windowID), @"kind": kind, @"title": scWindow.title ?: @""}];
    };
    NSMutableArray<NSWindow *> *owned = [NSMutableArray array];
    VibeCollectOwnedWindows(window, owned);
    for (NSWindow *child in owned) {
        include(byID[@(child.windowNumber)], child.isSheet ? @"sheet" : @"child");
    }
    for (NSPopover *popover in VibeDebugShownPopovers()) {
        NSWindow *popoverWindow = popover.contentViewController.view.window;
        SCWindow *scWindow = byID[@(popoverWindow.windowNumber)];
        if (scWindow.isOnScreen) {
            // A popover's window may already be in as a child window.
            [included removeObject:scWindow];
            [described filterUsingPredicate:[NSPredicate predicateWithFormat:@"id != %@", @(scWindow.windowID)]];
            include(scWindow, @"popover");
            [popoverFrames addObject:[NSValue valueWithRect:VibeCocoaRect(scWindow.frame)]];
        }
    }
    // A menu's window is the app's own, at the pop-up menu's level, and only
    // the window server lists it. The menu bar itself is the system's.
    for (SCWindow *scWindow in byID.allValues) {
        if (scWindow.isOnScreen && scWindow.windowLayer >= kCGPopUpMenuWindowLevel
                && scWindow.windowLayer < kCGOverlayWindowLevel) {
            include(scWindow, @"menu");
            [menuFrames addObject:[NSValue valueWithRect:VibeCocoaRect(scWindow.frame)]];
        }
    }
    NSArray<NSValue *> *extras = request.focus == VibeDebugCaptureFocusMenu ? menuFrames
            : request.focus == VibeDebugCaptureFocusPopover ? popoverFrames
            : [menuFrames arrayByAddingObjectsFromArray:popoverFrames];
    if (request.focus == VibeDebugCaptureFocusMenu && menuFrames.count == 0) {
        completion(VibeErrorJSON(@"no menu of this app is open; open one with a click first (answer_menu lists them)"));
        return;
    }
    if (request.focus == VibeDebugCaptureFocusPopover && popoverFrames.count == 0) {
        completion(VibeErrorJSON(@"no popover of this app shows (answer_popover lists them)"));
        return;
    }
    NSRect region = VibeDebugCaptureRegion(VibeCocoaRect(main.frame), extras, request.focus, request.crop);
    if (NSIsEmptyRect(region)) {
        completion(VibeErrorJSON(@"the crop lies outside the captured region"));
        return;
    }
    CGRect quartzRegion = VibeQuartzRect(region);
    CGPoint middle = CGPointMake(CGRectGetMidX(quartzRegion), CGRectGetMidY(quartzRegion));
    SCDisplay *display = nil;
    for (SCDisplay *candidate in content.displays) {
        if (CGRectContainsPoint(candidate.frame, middle)) {
            display = candidate;
            break;
        }
    }
    display = display ?: content.displays.firstObject;
    if (!display) {
        completion(VibeErrorJSON(@"ScreenCaptureKit lists no display for this app. %@", VibeCaptureFallback()));
        return;
    }
    // Only the app's own windows draw, over a clear background: no desktop,
    // no Dock, no menu bar, and no other app's window, wherever it sits.
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display includingWindows:included];
    filter.includeMenuBar = NO;
    CGFloat scale = filter.pointPixelScale > 0 ? filter.pointPixelScale : window.backingScaleFactor;
    CGRect source = CGRectIntersection(CGRectOffset(quartzRegion, -CGRectGetMinX(display.frame),
                                                    -CGRectGetMinY(display.frame)),
                                       CGRectMake(0, 0, CGRectGetWidth(display.frame), CGRectGetHeight(display.frame)));
    if (CGRectIsEmpty(source)) {
        completion(VibeErrorJSON(@"the window lies off its display"));
        return;
    }
    // What the display holds of the region, which the reply names.
    region = VibeCocoaRect(CGRectOffset(source, CGRectGetMinX(display.frame), CGRectGetMinY(display.frame)));
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.sourceRect = source;
    config.width = (size_t)llround(CGRectGetWidth(source) * scale);
    config.height = (size_t)llround(CGRectGetHeight(source) * scale);
    config.showsCursor = NO;
    config.captureResolution = SCCaptureResolutionBest;
    config.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    config.colorSpaceName = kCGColorSpaceSRGB;
    BOOL windowKey = window.isKeyWindow;
    BOOL appActive = NSApp.isActive;
    BOOL occluded = !(window.occlusionState & NSWindowOcclusionStateVisible);
    NSAppearanceName appearance = [window.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    [SCScreenshotManager captureImageWithFilter:filter configuration:config
                              completionHandler:^(CGImageRef image, NSError *error) {
        CGImageRetain(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) {
                completion(VibeCaptureErrorJSON(error));
                return;
            }
            BOOL written = VibeDebugWritePNG(image, scale, path);
            size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
            CGImageRelease(image);
            if (!written) {
                completion(VibeErrorJSON(@"the capture's PNG couldn't be written to %@", path));
                return;
            }
            NSRect frame = window.frame;
            completion(VibeJSONString(@{
                @"ok": @YES,
                @"path": path,
                @"width": @(width),
                @"height": @(height),
                @"scale": @(scale),
                @"method": @"ScreenCaptureKit",
                @"windowKey": @(windowKey),
                @"appActive": @(appActive),
                @"occluded": @(occluded),
                @"dark": @([appearance isEqualToString:NSAppearanceNameDarkAqua]),
                // The region's top left from the window's, in points, so a
                // point in the image maps to the window.
                @"region": @{@"x": @(NSMinX(region) - NSMinX(frame)), @"y": @(NSMaxY(frame) - NSMaxY(region)),
                             @"width": @(NSWidth(region)), @"height": @(NSHeight(region))},
                @"screenRegion": VibeRectJSON(region),
                @"windows": described,
            }));
        });
    }];
}

#endif
