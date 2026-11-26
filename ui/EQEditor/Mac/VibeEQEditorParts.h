//
//  VibeEQEditorParts.h
//  vibe-libs
//
//  The editor's inner views, which VibeEQEditorView composes and the tests
//  reach. Not for an app.
//

#import <AppKit/AppKit.h>

#import "VibeEQEditorView.h"

NS_ASSUME_NONNULL_BEGIN

// What a face tells the editor. A face never keeps the settings, only the
// bands it was last given.
@protocol VibeEQFaceOwner <NSObject>
- (void)face:(NSView *)face didChangeBands:(NSArray<VibeEQBand *> *)bands;
- (void)faceDidEndEditing:(NSView *)face;
- (void)face:(NSView *)face didSelectBandAtIndex:(NSUInteger)index;
@end

// A VoiceOver slider that isn't a view: a graphic slider or a node. Its
// frame is asked of its parent view as VoiceOver reads it.
@interface VibeEQAccessibilitySlider : NSAccessibilityElement
@property (nonatomic, copy) NSString *(^valueBlock)(void);
@property (nonatomic, copy) NSRect (^frameBlock)(void);  // in the parent view
@property (nonatomic, copy) void (^stepBlock)(BOOL up);
@property (nonatomic, copy, nullable) void (^focusBlock)(void);
@end

// The faces' tabs, drawn: NSSegmentedControl's calls that the editor uses.
// A click or an arrow key under full keyboard access selects an enabled tab
// and sends the action.
@interface VibeEQFaceTabs : NSControl
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic) NSInteger selectedSegment;
- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment;
- (BOOL)isEnabledForSegment:(NSInteger)segment;
- (void)setToolTip:(nullable NSString *)toolTip forSegment:(NSInteger)segment;
- (nullable NSString *)toolTipForSegment:(NSInteger)segment;
- (NSRect)rectOfSegment:(NSInteger)segment;
// NO when the tab is the current one, disabled, or past the last.
- (BOOL)chooseSegment:(NSInteger)segment;
@end

// The graphic face: ten sliders at the graphic frequencies, ±12 dB.
@interface VibeEQGraphicView : NSView
@property (nonatomic, weak, nullable) id<VibeEQFaceOwner> owner;
// The bands it was given. Empty or the graphic layout; anything else draws
// flat sliders.
@property (nonatomic, copy) NSArray<VibeEQBand *> *bands;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy) NSLocale *locale;
@property (nonatomic, copy) VibeEQEditorStrings *strings;
// The slider the keys move.
@property (nonatomic) NSUInteger focusedSlider;
// The slider whose value shows above its knob: the one dragged.
@property (nonatomic, readonly) NSUInteger draggedSlider;
- (double)gainAtSlider:(NSUInteger)index;
// The plot the sliders run in, and one slider's knob center.
- (NSRect)plotRect;
- (NSPoint)knobCenterForSlider:(NSUInteger)index;
- (NSArray<VibeEQAccessibilitySlider *> *)sliderElements;
@end

// The parametric face's graph: the grid, the curve, and a node per band.
@interface VibeEQCurveView : NSView
@property (nonatomic, weak, nullable) id<VibeEQFaceOwner> owner;
@property (nonatomic, copy) NSArray<VibeEQBand *> *bands;
// NSNotFound for none.
@property (nonatomic) NSUInteger selectedIndex;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy) NSLocale *locale;
@property (nonatomic, copy) VibeEQEditorStrings *strings;
// The dB axis's half-height, 12 or 24. Held while a drag goes on.
@property (nonatomic, readonly) double rangeDB;
- (NSRect)plotRect;
- (NSPoint)nodeCenterForBandAtIndex:(NSUInteger)index;
- (NSUInteger)nodeIndexAtPoint:(NSPoint)point;
- (NSArray<VibeEQAccessibilitySlider *> *)nodeElements;
@end

// The parametric face's list: a row per band, and add and remove.
@interface VibeEQBandListView : NSView
@property (nonatomic, weak, nullable) id<VibeEQFaceOwner> owner;
@property (nonatomic, copy) NSArray<VibeEQBand *> *bands;
@property (nonatomic) NSUInteger selectedIndex;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy) NSLocale *locale;
@property (nonatomic, copy) VibeEQEditorStrings *strings;
@property (nonatomic, readonly) NSTableView *tableView;
@property (nonatomic, readonly) NSButton *addButton;
@property (nonatomic, readonly) NSButton *removeButton;
// Shows the bands given while it was hidden.
- (void)reloadIfNeeded;
@end

// The spoken value of a node: "1,000 Hz, +3.0 dB, Q 1.4". A pass filter has
// no gain, so it reads "1,000 Hz, Q 0.71".
NSString *VibeEQNodeAccessibilityValue(VibeEQBand *band, NSLocale *locale);

// The band types whose gain counts: a peak and the shelves.
BOOL VibeEQBandHasGain(VibeEQBandType type);

// The axes' labels.
NSFont *VibeEQLabelFont(void);
// A grid line: the label color at an alpha, since a system separator color
// given an alpha of its own turns brighter in dark mode, not fainter.
NSColor *VibeEQGridColor(CGFloat alpha);
// The face's grid alphas: a minor line, a major one, and 0 dB.
static const CGFloat kVibeEQMinorGridAlpha = 0.05;
static const CGFloat kVibeEQMajorGridAlpha = 0.12;
static const CGFloat kVibeEQZeroLineAlpha = 0.3;

@interface VibeEQEditorView (Parts)
@property (nonatomic, readonly) VibeEQFaceTabs *faceControl;
@property (nonatomic, readonly) VibeEQGraphicView *graphicView;
@property (nonatomic, readonly) VibeEQCurveView *curveView;
@property (nonatomic, readonly) VibeEQBandListView *bandList;
@end

NS_ASSUME_NONNULL_END
