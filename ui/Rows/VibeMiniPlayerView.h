//
//  VibeMiniPlayerView.h
//  vibe-libs
//
//  The strip in the tab bar's bottomAccessory. Tapping it anywhere but a
//  control, or swiping up, expands the card. It draws only what it is told,
//  and reads no model, setting or string.
//

#import <UIKit/UIKit.h>

@class VibeMiniPlayerView;
@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

@protocol VibeMiniPlayerViewDelegate <NSObject>
- (void)miniPlayerViewDidRequestExpand:(VibeMiniPlayerView *)view;
- (void)miniPlayerViewDidTapPlayPause:(VibeMiniPlayerView *)view;
- (void)miniPlayerViewDidTapNext:(VibeMiniPlayerView *)view;
@end

@interface VibeMiniPlayerView : UIView

@property (nonatomic, weak) id<VibeMiniPlayerViewDelegate> delegate;

// VoiceOver's names for the strip's controls. Expand names what a tap on the
// strip shows. The play button takes play or pause, whichever a tap will do.
- (void)setAccessibilityLabelsForExpand:(NSString *)expand
                                   play:(NSString *)play
                                  pause:(NSString *)pause
                                   next:(NSString *)next;

// The title, subtitle and thumbnail; the rest of the row is not drawn. The
// thumbnail is the small row art, never a full-size decode.
- (void)renderRow:(nullable VibeTrackRow *)row;
- (void)setPlaying:(BOOL)playing;

@end

NS_ASSUME_NONNULL_END
