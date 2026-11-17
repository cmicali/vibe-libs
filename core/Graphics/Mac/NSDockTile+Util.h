//
//  NSDockTile+Util.h
//  vibe-libs
//
//  The Dock tile and the app icon behind it. The category is main thread
//  only.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// A picture on the system's icon grid, canvasSize points square: aspect-fit
// into the grid's content square, 824 of 1,024 points, clipped to its
// 185-point corner radius, with a rim light along the edge. The Dock draws a
// tile's content view edge to edge, so a picture with less margin reads
// larger than its neighbors. Drawn into a bitmap at once, so it runs on any
// thread, on an image no other thread draws. nil when there is no context.
FOUNDATION_EXPORT NSImage *_Nullable VibeMacStyleIconFromImage(NSImage *image, CGFloat canvasSize);

// The canvas the Dock tile's view draws at.
FOUNDATION_EXPORT const CGFloat kVibeDockIconCanvasSize;

@interface NSDockTile (Util)

// Shows whatever NSApp.applicationIconImage holds now, so a custom icon reads
// through.
+ (void)resetToAppIcon;

// Shaped composes onto the icon grid off-main; a later call or a reset wins
// over a slower composition. Unshaped installs the picture as it is, at
// once, so an app that composes its own passes NO.
+ (void)setDockIcon:(NSImage *)image shaped:(BOOL)shaped;

// The app icon everywhere the system draws one; nil restores the bundle's.
// Synchronous, so a caller can reset the tile right after.
+ (void)setAppIcon:(nullable NSImage *)image shaped:(BOOL)shaped;

@end

NS_ASSUME_NONNULL_END
