//
//  VibeEQEditorView.h
//  vibe-libs
//
//  The editor of an EQ's bands, in two faces: a graphic face of ten sliders
//  and a parametric face that draws the curve, with a node and a row for
//  each band. It edits only the bands. The host owns the rest of the
//  settings, the presets, and the window. Main thread only.
//

#import <AppKit/AppKit.h>

#import "VibeListeningSettings.h"

NS_ASSUME_NONNULL_BEGIN

@class VibeEQEditorView;

typedef NS_ENUM(NSInteger, VibeEQEditorFace) {
    VibeEQEditorFaceGraphic,
    VibeEQEditorFaceParametric,
};

@protocol VibeEQEditorViewDelegate <NSObject>

// Every change, live while a drag goes on. The settings are the host's last
// ones with new bands.
- (void)eqEditorView:(VibeEQEditorView *)view didChangeSettings:(VibeListeningSettings *)settings;
// One edit is over: a drag or a scroll let go, a key step, a slider reset, a
// field committed, or a band added or removed. The host records its undo
// and saves here.
- (void)eqEditorViewDidEndEditing:(VibeEQEditorView *)view;

@optional
// A host that presents the selected band can update its controls here.
- (void)eqEditorViewDidSelectBand:(VibeEQEditorView *)view;
// The user switched faces, so the host can keep the choice.
- (void)eqEditorViewDidChangeFace:(VibeEQEditorView *)view;

@end

// The editor's words. The defaults are English. An app sets its own,
// localized, before the view shows.
@interface VibeEQEditorStrings : NSObject <NSCopying>

@property (nonatomic, copy) NSString *graphicFace;
@property (nonatomic, copy) NSString *parametricFace;
// The graphic tab's tooltip while the bands don't fit it.
@property (nonatomic, copy) NSString *graphicUnavailable;
// Peak, Low Shelf, High Shelf, Low-Pass, High-Pass, by VibeEQBandType.
@property (nonatomic, copy) NSArray<NSString *> *bandTypes;
@property (nonatomic, copy) NSString *onColumn;
@property (nonatomic, copy) NSString *typeColumn;
@property (nonatomic, copy) NSString *frequencyColumn;
@property (nonatomic, copy) NSString *gainColumn;
@property (nonatomic, copy) NSString *qColumn;
@property (nonatomic, copy) NSString *addBand;
@property (nonatomic, copy) NSString *removeBand;
// A node's and a row's name, with the band's number: "Band %ld".
@property (nonatomic, copy) NSString *bandFormat;
@property (nonatomic, copy) NSString *curveAccessibilityLabel;
@property (nonatomic, copy) NSString *slidersAccessibilityLabel;

@end

@interface VibeEQEditorView : NSView

@property (nonatomic, weak, nullable) id<VibeEQEditorViewDelegate> delegate;

// Neutral by default. Setting it calls no delegate method.
@property (nonatomic, copy, null_resettable) VibeListeningSettings *settings;

// The face showing. The graphic face shows only while the bands fit it:
// none, or exactly the graphic layout. A face set while they don't fit shows
// once the host sets bands that do. Setting it calls no delegate method.
@property (nonatomic) VibeEQEditorFace face;
// The bands fit the graphic face.
@property (nonatomic, readonly) BOOL graphicFaceAvailable;

// Fill the editor with the current face. The host supplies the face picker and band controls.
@property (nonatomic) BOOL compactPresentation;
// NSNotFound clears the selection.
@property (nonatomic) NSUInteger selectedBandIndex;

// NO dims the view and ignores every input. YES by default.
@property (nonatomic, getter=isEnabled) BOOL enabled;

// The English defaults. nil sets them back.
@property (nonatomic, copy, null_resettable) VibeEQEditorStrings *strings;
// The numbers' digits and separators. The current locale by default.
@property (nonatomic, copy, null_resettable) NSLocale *locale;

@end

NS_ASSUME_NONNULL_END
