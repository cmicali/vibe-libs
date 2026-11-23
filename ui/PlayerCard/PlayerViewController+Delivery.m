//
//  PlayerViewController+Delivery.m
//  vibe-libs
//
//  The coordinator matches waveform deliveries by sourceKey. Scrub events
//  apply only to the bound view. Pager holds release by the view that took them.
//

#import "PlayerViewController+Delivery.h"
#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Pager.h"

#import "AudioWaveformCache.h"
#import "PlaceholderFiles.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"
#import "WaveformZoomMath.h"

@implementation PlayerViewController (Delivery)

#pragma mark - PageWaveformCoordinatorDelegate

// The coordinator records completeness before it forwards, held or not.
// Under the slider nothing draws: the coordinator keeps the snapshot, and a
// switch back hydrates from it (reloadSettings).
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index {
    if ([self usesStandardScrubber]) {
        return;
    }
    BOOL complete = [pipeline isCompleteAtIndex:index];
    // Eased only where someone can see it: every eased frame is a full raster.
    [[self cellAtIndex:index].waveformView showWaveform:waveform animated:_sceneActive && self.isPresented];
    // Only a complete one: a widget bake is two renders and two file writes.
    if (complete) {
        [_playback noteCompleteWaveform:waveform forTrack:[_playback.playlist trackAtIndex:index]];
    }
}

// A placeholder's refused open is not a failure to draw: its download will
// land and the open asks again. Only the current page's: a neighbor has no
// open coming to take the indicator down.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
      didFailWaveformForIndex:(NSUInteger)index {
    if ([self usesStandardScrubber]) {
        return;
    }
    id<VibePlayerCardItem> track = [_playlist trackAtIndex:index];
    if (track && index == _playback.currentIndex && [PlaceholderFiles isRemotePlaceholderFile:track.url]) {
        return;
    }
    [[self cellAtIndex:index].waveformView hideLoadingIndicator];
}

// The model's to read. The page hears a tempo back as the metadata event.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
            didLoadAnalysis:(NSDictionary<NSString *, id> *)results
                   forTrack:(id<VibePlayableItem>)track {
    [_playback noteWaveformAnalysis:results forTrack:track];
}

#pragma mark - Scrubs, from either scrubber

// A scrubber on the bound page. Any other is a neighbor's preview.
- (BOOL)isBoundScrubber:(UIView *)view {
    return view && (view == _boundPage.waveformView || view == _boundPage.standardScrubber);
}

- (void)scrubber:(UIView *)view seekToProgress:(CGFloat)progress {
    if ([self isBoundScrubber:view]) {
        [_playback seekToProgress:progress];
    }
}

// The labels show where the scrub will land, not what is still playing. The
// duration falls back to the track's own: a parked track has none on the
// player.
- (void)scrubber:(UIView *)view didScrubToProgress:(CGFloat)progress {
    if (![self isBoundScrubber:view]) {
        return;
    }
    NSTimeInterval duration = VibePlayerScreenDuration(_playback.duration, _playback.currentTrack.duration);
    if (duration <= 0) {
        return;
    }
    NSTimeInterval position = MAX(0.0, MIN(1.0, progress)) * duration;
    NSInteger second = (NSInteger)position;
    if (second == _scrubLabelSecond) {
        return;
    }
    _scrubLabelSecond = second;
    _elapsedLabel.text = [VibePlayerCardInstalledHost() playerCardDuration:position];
    _remainingTimeControl.text = VibeRightTimeText(position, duration);
}

// Holds the pager still for a scrub (the protocol says why).
// TRAP: the release is matched against the view that took the lock, not the
// bound page. A track ending mid-drag rebinds the chrome while the finger is
// down on the outgoing page; filtering on the binding drops the lift and the
// pager stays unswipeable.
- (void)scrubber:(UIView *)view didChangeScrubbing:(BOOL)scrubbing {
    // Either way the labels' second guard is stale.
    _scrubLabelSecond = NSIntegerMin;
    [self setPagerHeld:scrubbing byView:view];
}

#pragma mark - WaveformScrubberViewDelegate

- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage {
    [self scrubber:view seekToProgress:percentage];
}

- (void)waveformScrubberView:(WaveformScrubberView *)view
          didScrubToProgress:(CGFloat)progress {
    [self scrubber:view didScrubToProgress:progress];
}

- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeScrubbing:(BOOL)scrubbing {
    [self scrubber:view didChangeScrubbing:scrubbing];
}

#pragma mark - The standard scrubber

// The waveform scrubber's rules, on a slider. Its own extras: a lift seeks
// only after a drag moved it, VoiceOver's adjust seeks at once, and the end
// repaints the labels. What a seek does to a parked or paused track is the
// model's (VibePlayerScrubActionFor).
- (void)standardScrubberDidBegin:(UISlider *)slider {
    _standardScrubMoved = NO;
    [self scrubber:slider didChangeScrubbing:YES];
}

- (void)standardScrubberDidMove:(UISlider *)slider {
    if (!slider.isTracking) {
        // VoiceOver's adjust, which has no drag to wait for.
        [self scrubber:slider seekToProgress:slider.value];
        return;
    }
    _standardScrubMoved = YES;
    [self scrubber:slider didScrubToProgress:slider.value];
}

- (void)standardScrubberDidEnd:(UISlider *)slider {
    // The seek first, so the readout the release repaints is its target.
    if (_standardScrubMoved) {
        [self scrubber:slider seekToProgress:slider.value];
    }
    [self standardScrubberDidCancel:slider];
}

// Also a recycled page's (VibeTrackPageSlider's cancelInteraction).
- (void)standardScrubberDidCancel:(UISlider *)slider {
    _standardScrubMoved = NO;
    [self scrubber:slider didChangeScrubbing:NO];
    if ([self isBoundScrubber:slider]) {
        [self updatePlaybackUI];
    }
}

- (void)setPagerHeld:(BOOL)held byView:(UIView *)view {
    if (held) {
        [_pagerHoldViews addObject:view];
    }
    else {
        [_pagerHoldViews removeObject:view];
    }
    // allObjects, not count, which still counts a holder that has died.
    _pagesView.scrollEnabled = _pagerHoldViews.allObjects.count == 0;
}

// Deep zoom's frames, for the page bound to playback only: the view refills
// as they land. A neighbor is refused, and asks again when it next draws as
// the current page.
- (void)waveformScrubberView:(WaveformScrubberView *)view
           needsDetailBlocks:(NSIndexSet *)blocks
                  ofWaveform:(CodableAudioWaveform *)waveform {
    NSUInteger index = _playlist.currentIndex;
    id<VibePlayerCardItem> track = [_playlist trackAtIndex:index];
    if (view != _waveformView || !track || [_waveformCoordinator snapshotAtIndex:index] != waveform) {
        [view detailDidLoadForWaveform:waveform];
        return;
    }
    __weak WaveformScrubberView *weakView = view;
    [_waveformCache loadDetailBlocks:blocks forTrack:track waveform:waveform completion:^{
        [weakView detailDidLoadForWaveform:waveform];
    }];
}

#pragma mark - Waveform zoom

// One zoom for the whole pager, so a swipe cannot change it.
- (void)waveformScrubberView:(WaveformScrubberView *)view
    didChangeVisibleFraction:(CGFloat)fraction {
    if (fraction == _waveformZoom) {
        return;
    }
    _waveformZoom = fraction;
    for (TrackPageCell *cell in _pagesView.visibleCells) {
        [self applyWaveformZoomToCell:cell];
    }
    // The REQUEST: what a view drew would let a rotation permanently shallow
    // the zoom.
    VibePlayerCardInstalledHost().playerCardWaveformZoom = fraction;
}

- (void)restoreWaveformZoom {
    _waveformZoom = VibeWaveformClampRequestedFraction(VibePlayerCardInstalledHost().playerCardWaveformZoom);
}

- (void)applyWaveformZoomToCell:(TrackPageCell *)cell {
    cell.waveformView.visibleFraction = _waveformZoom;
}

@end
