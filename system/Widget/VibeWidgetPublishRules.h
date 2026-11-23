//
//  VibeWidgetPublishRules.h
//  vibe-libs
//
//  When the publisher writes a new snapshot. Foundation only, so it builds
//  and is tested on both platforms. It sits apart from VibeWidgetState.h, so
//  a widget extension that reads the snapshot compiles no Now Playing code.
//

#import <Foundation/Foundation.h>

#import "NowPlayingRules.h"
#import "VibeWidgetState.h"

NS_ASSUME_NONNULL_BEGIN

// A seek detector against the widget's own extrapolation. Looser than the
// lock screen's, since a widget entry spans seconds.
static const NSTimeInterval kVibeWidgetPositionTolerance = 2.0;

// Whether a tick publishes a new snapshot. last is the published snapshot,
// nil when nothing was published yet, and trackChanged says the track is not
// the one it describes. The widget extrapolates steady playback. So only a
// new track, a play or pause, a changed duration or line, or a jump past the
// tolerance publishes. Tags landing after the start change the lines, not
// the identity. While the open runs the playhead is pinned at 0, so the
// position alone publishes nothing.
static inline BOOL VibeWidgetNeedsPublish(VibeWidgetState *_Nullable last,
                                          BOOL trackChanged,
                                          BOOL hasTrack,
                                          NSString *_Nullable title,
                                          NSString *_Nullable artist,
                                          BOOL playing,
                                          NSTimeInterval duration,
                                          NSTimeInterval position,
                                          BOOL startPending,
                                          CFAbsoluteTime now) {
    if (!last || trackChanged) {
        return YES;
    }
    if (last.hasTrack != hasTrack || last.playing != playing) {
        return YES;
    }
    if (fabs(last.duration - duration) > 0.5) {
        return YES;
    }
    if (!VibeNowPlayingStringsEqual(last.title, title) || !VibeNowPlayingStringsEqual(last.artist, artist)) {
        return YES;
    }
    if (startPending) {
        return NO;
    }
    return VibeNowPlayingPositionIsDirty(last.position, last.positionDate.timeIntervalSinceReferenceDate, 1.0,
                                         last.playing, position, now, kVibeWidgetPositionTolerance);
}

NS_ASSUME_NONNULL_END
