//
//  TrackPageViews.h
//  vibe-libs
//
//  The small views a TrackPageCell is built from.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kArtCornerRadius = 12;

// The time labels' font, color and placeholder text.
void VibeConfigureTimeLabel(UILabel *label);

// The route capsule, which rounds its own ends.
@interface TrackPageActionBarView : UIView
@end

// A control because a tap flips the time mode; a 44pt target whose label
// stays aligned with the elapsed time.
@interface TrackPageTimeControl : UIControl
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSTextAlignment textAlignment;
@end

// The art's card, which restates its own shadow path.
@interface TrackPageArtCardView : UIView
@end

// The standard scrubber, a slider that answers cancelInteraction as every
// view holding the pager does.
@interface VibeTrackPageSlider : UISlider
// Ends a drag and sends UIControlEventTouchCancel, which the controller
// releases the pager's hold on. TRAP: a slider's own cancelled tracking sends
// no event, so a page recycled mid-drag would leave the pager held.
- (void)cancelInteraction;
// The playback position. A write that moves the thumb by less than a device
// pixel is skipped, since the position moves a few pixels a second.
- (void)showPlayheadProgress:(CGFloat)progress;
@end

NS_ASSUME_NONNULL_END
