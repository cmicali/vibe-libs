//
//  PlayerViewControllerInternal.h
//  vibe-libs
//
//  The private surface shared by PlayerViewController.m and its categories;
//  no other file imports it. The debug surface is
//  Debug/iOS/Seams/PlayerViewController+Debug.h. This header is the cost of the
//  split: a category that pushes more state in here than it takes out of
//  PlayerViewController.m is not worth making.
//

#import "PlayerViewController.h"
#import "FXPadView.h"
#import "OutputRouteView.h"
#import "VibePlayerCardHost.h"
#import "VibePlayerCardPlayback.h"

@class AudioWaveformCache;
@class PageWaveformCoordinator;
@class TrackPageActionBarView;
@class TrackPageCell;
@class TrackPageTimeControl;
@class VibeTrackPageSlider;
@class WaveformScrubberView;

NS_ASSUME_NONNULL_BEGIN

// Every render path of the right time label goes through this.
NSString *VibeRightTimeText(NSTimeInterval position, NSTimeInterval duration);

// Every other conformance is declared on the category that implements it.
@interface PlayerViewController () <FXPadViewDelegate, OutputRouteViewDelegate,
        UIGestureRecognizerDelegate, VibePlayerCardObserver> {
    id<VibePlayerCardPlayback> _playback;
    // _playback's, held apart so the debug seam's transition check can swap it.
    id<VibePlayerCardQueue> _playlist;

    UICollectionView        *_pagesView;
    UICollectionViewFlowLayout *_pagesLayout;
    // Mid-resize the offset is not page-aligned, so commits hold.
    BOOL                    _windowResizeInFlight;
    // Dragging or decelerating; takes the frame-budget hold (+Pager).
    BOOL                    _pagerScrolling;
    // A visible programmatic page animation; minimized moves snap and never
    // set it.
    BOOL                    _pagerProgrammaticScrolling;
    // So a bounded release cannot lift a later take of the hold.
    uint64_t                _pagerProgrammaticScrollGeneration;
    CGSize                  _lastLayoutSize;

    // BINDINGS to the current page's views, rebound when its cell appears or
    // is recreated, so the live paths keep one stable name.
    TrackPageCell           *_boundPage;
    WaveformScrubberView    *_waveformView;
    // The bound page's slider, which stands in for the waveform when the
    // host asks (VibePlayerCardScrubberStandard).
    VibeTrackPageSlider     *_standardScrubber;
    UILabel                 *_elapsedLabel;
    TrackPageTimeControl    *_remainingTimeControl;
    UIView                  *_transportView;
    OutputRouteView         *_routeView;
    TrackPageActionBarView  *_actionBar;
    FXPadView               *_fxPadView;
    // The views holding the pager still — a scrubber mid-scrub or mid-pinch,
    // an FX pad under a finger — NOT always the bound page's: a track ending
    // mid-drag rebinds the chrome while the finger is down. A set, held
    // weakly: a scrub and a pad hold overlap, and the pager is free only
    // when the last of them lifts.
    NSHashTable<UIView *>   *_pagerHoldViews;

    // The pager's own, not the model's: nothing else draws a waveform.
    AudioWaveformCache      *_waveformCache;
    PageWaveformCoordinator *_waveformCoordinator;

    // Pages whose full-size art is held, the only record of what there is to
    // release: art outlives the window that asked for it. Owned by +Pager.
    NSMutableIndexSet       *_artHeldPages;

    // Here because the debug state dump reports it.
    BOOL                    _sceneActive;

    // The system route picker is up, which holds the playhead display link.
    // TRAP: AVKit does NOT reliably send the end edge (on the simulator,
    // never); stuck, the waveform freezes under correct labels for the life of
    // the process. A generation-stamped deadline releases it, and the
    // scene-active edge settles it sooner.
    BOOL                    _routePickerPresenting;
    uint64_t                _routePickerHoldGeneration;

    // The second last rendered for a scrub, so a drag does not format at
    // display rate. NSIntegerMin: not scrubbing.
    NSInteger               _scrubLabelSecond;
    // A slider's drag moved it, so its lift seeks. A tap on the thumb does not.
    BOOL                    _standardScrubMoved;
    // What reloadSettings last saw, so a switch back to the waveform asks
    // for one.
    BOOL                    _usedStandardScrubber;

    // Shared by every page. The user's REQUEST, which is what persists; each
    // view applies its own floor (WaveformScrubberView.visibleFraction).
    CGFloat                 _waveformZoom;
}

#pragma mark - The refresh funnel

- (void)updatePlaybackUI;
// The playhead on the bound page: the waveform's, and the slider's while it
// is not under a finger.
- (void)showProgress:(CGFloat)progress;
// A scrub of either kind is under a finger, and owns the time labels.
- (BOOL)isScrubbing;
// The host asks for the slider (VibePlayerCardScrubberStandard). No
// waveform is requested meanwhile.
- (BOOL)usesStandardScrubber;
- (void)updatePlayButton;
// Only the empty state hides the transport, action bar and route control.
- (CGFloat)chromeAlpha;
- (void)updateScrollLinkState;
- (void)updateOutputRoute;
// Refreshes the current page and rebinds the chrome to it.
- (void)renderHeaderForTrack:(nullable id<VibePlayerCardItem>)track;

#pragma mark - Resting time rendering

// Neighbor pages, a pending start and a parked track: 0:00, and the duration
// once metadata knows it.
+ (void)renderRestingTimesForTrack:(nullable id<VibePlayerCardItem>)track
                           elapsed:(UILabel *)elapsed
                         remaining:(TrackPageTimeControl *)remaining;
- (void)renderRestingTimesForTrack:(nullable id<VibePlayerCardItem>)track;

#pragma mark - Transport

- (void)playPauseTapped;
- (void)previousTapped;
- (void)nextTapped;
- (void)shuffleTapped;
- (void)repeatTapped;
- (void)queueTapped;

// One setting for every page, so every visible page repaints.
- (void)remainingTimeTapped;

- (void)repaintTimesOnVisiblePages;

@end

NS_ASSUME_NONNULL_END
