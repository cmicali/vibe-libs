//
//  DebugScreenshot.m
//  vibe-libs
//

#import "DebugScreenshot.h"

#if DEBUG

#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>
#import "VibeMacros.h"

// A glass view's hosting layer renders as opaque white in renderInContext:,
// because its real content is composited by the window server, and it paints
// over everything below it in the tree. It must therefore be hidden for the
// render, not merely underpainted. A hidden view renders nothing, so it is
// skipped.
static void VibeCollectGlassViews(NSView *view, NSMutableArray<NSView *> *out) {
    if (view.isHidden || view.layer.isHidden) {
        return;
    }
    if (@available(macOS 26.0, *)) {
        if ([view isKindOfClass:[NSGlassEffectView class]]) {
            if (view.layer) {
                [out addObject:view];
            }
            return;
        }
    }
    for (NSView *subview in view.subviews) {
        VibeCollectGlassViews(subview, out);
    }
}

// A backdrop layer, such as a scroll view's edge effect, renders as opaque
// white too. Only its class's name tells it apart.
static void VibeCollectBackdropLayers(CALayer *layer, NSMutableArray<CALayer *> *out) {
    if (!layer.isHidden && [NSStringFromClass(layer.class) isEqualToString:@"CABackdropLayer"]) {
        [out addObject:layer];
        return;
    }
    for (CALayer *sublayer in layer.sublayers) {
        VibeCollectBackdropLayers(sublayer, out);
    }
}

// X5: a clip view under a toolbar or a header has content insets. On screen,
// what scrolls up into an inset is covered by the toolbar's and the header's
// backgrounds, which the render hides. So the render clips each such view to
// the rect inside its insets, by a frame and bounds that keep its content in
// place, uncommitted, and gives back what it changed.
static void VibeClipToContentInsets(NSView *view, NSMutableArray<dispatch_block_t> *restores) {
    if (view.isHidden || !view.layer) {
        return;
    }
    if ([view isKindOfClass:NSClipView.class]) {
        NSClipView *clip = (NSClipView *)view;
        NSEdgeInsets insets = clip.contentInsets;
        if (insets.top > 0 || insets.bottom > 0 || insets.left > 0 || insets.right > 0) {
            NSRect inside = clip.bounds;
            inside.origin.x += insets.left;
            inside.size.width -= insets.left + insets.right;
            inside.origin.y += clip.isFlipped ? insets.top : insets.bottom;
            inside.size.height -= insets.top + insets.bottom;
            if (inside.size.width > 0 && inside.size.height > 0 && clip.superview) {
                CALayer *layer = clip.layer;
                CGRect bounds = layer.bounds;
                CGPoint position = layer.position;
                BOOL masks = layer.masksToBounds;
                // A view's layer frame is its frame in its superview.
                layer.frame = [clip convertRect:inside toView:clip.superview];
                layer.bounds = CGRectMake(NSMinX(inside), NSMinY(inside), NSWidth(inside), NSHeight(inside));
                layer.masksToBounds = YES;
                [restores addObject:^{
                    layer.bounds = bounds;
                    layer.position = position;
                    layer.masksToBounds = masks;
                }];
            }
        }
    }
    for (NSView *subview in view.subviews) {
        VibeClipToContentInsets(subview, restores);
    }
}

BOOL VibeDumpWindowSnapshot(NSString *path) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window) {
        // Front to back, not creation order: with the app inactive both
        // keyWindow and mainWindow are nil, and NSApp.windows would hand back
        // the first window made even while another sits in front.
        for (NSWindow *candidate in NSApp.orderedWindows) {
            if (candidate.isVisible && candidate.contentView) {
                window = candidate;
                break;
            }
        }
    }
    NSView *view = window.contentView;
    if (!view || NSIsEmptyRect(view.bounds)) {
        LogError(@"Debug screenshot: no window content to render");
        return NO;
    }
    CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0;
    size_t pixelsWide = (size_t)llround(view.bounds.size.width * scale);
    size_t pixelsHigh = (size_t)llround(view.bounds.size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, space,
            (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        LogError(@"Debug screenshot: bitmap context creation failed");
        return NO;
    }
    CGContextScaleCTM(ctx, scale, scale);
    // With the glass and backdrop layers hidden below, their region renders
    // transparent, so paint an appearance-matched proxy background first.
    // Dark-mode content — white text and drawing at low alpha — then keeps the
    // window's real contrast polarity rather than flattening onto white.
    NSAppearanceName match = [window.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    BOOL isDark = [match isEqualToString:NSAppearanceNameDarkAqua];
    CGContextSetGrayFillColor(ctx, isDark ? 0.1 : 0.95, 1.0);
    CGContextFillRect(ctx, view.bounds);
    CALayer *layer = view.layer;
    if (layer) {
        // A layout or a scroll still pending lands first, as the window's next
        // frame would show it.
        [window displayIfNeeded];
        NSMutableArray<NSView *> *glassViews = [NSMutableArray array];
        VibeCollectGlassViews(view, glassViews);
        NSMutableArray<CALayer *> *backdrops = [NSMutableArray array];
        VibeCollectBackdropLayers(layer, backdrops);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        NSMutableArray<dispatch_block_t> *restores = [NSMutableArray array];
        VibeClipToContentInsets(view, restores);
        if (glassViews.count > 0 || backdrops.count > 0 || restores.count > 0) {
            // The changes must stay uncommitted, so that the on-screen window
            // never flickers. That forces a render of the model tree, since an
            // uncommitted change is invisible to a presentation copy. It costs
            // the mid-flight animation capture, but only a window with glass,
            // a backdrop, or an inset clip view pays for it.
            for (CALayer *backdrop in backdrops) {
                backdrop.hidden = YES;
            }
            for (NSView *glass in glassViews) {
                glass.layer.hidden = YES;
            }
            [layer renderInContext:ctx];
            // Each glass view's content, such as a sidebar's rows, then
            // renders on top, in its place.
            for (NSView *glass in glassViews) {
                glass.layer.hidden = NO;
                if (@available(macOS 26.0, *)) {
                    NSView *content = ((NSGlassEffectView *)glass).contentView;
                    if (content.layer && !content.isHidden) {
                        NSRect frame = [content convertRect:content.bounds toView:view];
                        CGContextSaveGState(ctx);
                        CGContextTranslateCTM(ctx, NSMinX(frame), NSMinY(frame));
                        [content.layer renderInContext:ctx];
                        CGContextRestoreGState(ctx);
                    }
                }
            }
            for (CALayer *backdrop in backdrops) {
                backdrop.hidden = NO;
            }
            for (dispatch_block_t restore in restores) {
                restore();
            }
        }
        else {
            // The presentation tree captures animations mid-flight.
            CALayer *presentation = layer.presentationLayer ?: layer;
            [presentation renderInContext:ctx];
        }
        [CATransaction commit];
    }
    else {
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        [view displayRectIgnoringOpacity:view.bounds inContext:gc];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) {
        LogError(@"Debug screenshot: image creation failed");
        return NO;
    }
    BOOL written = VibeDebugWritePNG(image, scale, path);
    CGImageRelease(image);
    if (written) {
        LogInfo(@"Debug screenshot written to %@", path);
    }
    else {
        LogError(@"Debug screenshot: PNG write to %@ failed", path);
    }
    return written;
}

BOOL VibeDebugWritePNG(CGImageRef image, CGFloat scale, NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dest) {
        return NO;
    }
    NSDictionary *properties = @{(__bridge NSString *)kCGImagePropertyDPIWidth: @(72.0 * scale),
                                 (__bridge NSString *)kCGImagePropertyDPIHeight: @(72.0 * scale)};
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)properties);
    BOOL written = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return written;
}

void VibeInstallDebugScreenshotHook(NSString *notificationName, NSString *path) {
    static int token;
    NSString *output = [path copy];
    notify_register_dispatch(notificationName.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        VibeDumpWindowSnapshot(output);
    });
}


#endif
