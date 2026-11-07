//
//  VibeDropWellsView.h
//  vibe-libs
//
//  The wells a drag of files over a window shows: dashed rounded wells,
//  each an SF Symbol over a label, with the one under the pointer lit.
//  Presentation and hit-testing alone. The window stays the dragging
//  destination and forwards the drag's location here.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// One well: what it says, its symbol, and the app's name for its action.
// Immutable.
@interface VibeDropWell : NSObject

+ (instancetype)wellWithIdentifier:(NSString *)identifier title:(NSString *)title symbolName:(NSString *)symbolName;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *symbolName;

@end

// How the wells are drawn. Each color is read as it draws, so a dynamic
// color follows the appearance.
@interface VibeDropWellsStyle : NSObject <NSCopying>

// The system's colors: the label colors, and the focus ring's for the lit
// well. The font is the system's at 14 pt.
+ (instancetype)systemStyle;

@property (nonatomic) NSColor *strokeColor;
@property (nonatomic) NSColor *hoverStrokeColor;
// nil fills nothing.
@property (nonatomic, nullable) NSColor *hoverFillColor;
@property (nonatomic) NSColor *contentColor;
@property (nonatomic) NSColor *hoverContentColor;
@property (nonatomic) NSFont *font;

@end

@interface VibeDropWellsView : NSView

// Left to right, or top to bottom once stacked. Empty draws nothing.
@property (nonatomic, copy) NSArray<VibeDropWell *> *wells;
@property (nonatomic, copy) VibeDropWellsStyle *style;
// A blur over the views beneath while the wells show, so they read against
// rows. Off by default.
@property (nonatomic) BOOL showsBlur;
// Below this width a well no longer fits in a row, and the wells stack. 0,
// the default, never stacks.
@property (nonatomic) CGFloat minimumWellWidth;
// Entering and leaving the drag fade. On by default. A caller that fades
// its own layer around this view turns it off.
@property (nonatomic) BOOL fadesStateChanges;

// A drag is over the view, so the wells show.
@property (nonatomic, readonly, getter=isDragActive) BOOL dragActive;
// The lit well's identifier, or nil while the pointer is over none.
@property (nonatomic, readonly, nullable) NSString *hoveredIdentifier;
// The wells stack, top to bottom.
@property (nonatomic, readonly, getter=isStacked) BOOL stacked;

// Window coordinates. An update shows the wells and moves the light. It does
// nothing while the view is hidden, or too small to draw a well.
- (void)fileDragUpdatedAtWindowPoint:(NSPoint)point;
- (void)fileDragEnded;

// The well under the point, in window coordinates, or nil. Geometry only,
// so it stays valid after fileDragEnded: a drop is often delivered after
// the drag session ends.
- (nullable NSString *)wellIdentifierAtWindowPoint:(NSPoint)point;
// A well's rect in the view's coordinates. NSZeroRect past the last.
- (NSRect)rectOfWellAtIndex:(NSUInteger)index;
// The view is shown, and tall enough to draw a well.
@property (nonatomic, readonly, getter=isEffectivelyVisible) BOOL effectivelyVisible;

@end

NS_ASSUME_NONNULL_END
