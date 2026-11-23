//
//  VibeWidgetPublishRules.h
//  vibe-libs
//
//  When the publisher writes a new snapshot, and the key that names a
//  track's files. Foundation only, so it builds and is tested on both
//  platforms. It sits apart from VibeWidgetState.h, so a widget extension that
//  reads the snapshot compiles no Now Playing code.
//

#import <Foundation/Foundation.h>

#import "NSURL+Hash.h"
#import "NowPlayingRules.h"
#import "VibePlayableItem.h"
#import "VibeWidgetState.h"

NS_ASSUME_NONNULL_BEGIN

// VibeWidgetState.trackKey for a track: its file's NSURL.pathKey, plus a cue
// row's window, so rows of one file render and seek apart. nil with no path.
// It names the image files and rides in every seek button, so it is part of
// the contract between the app and its extension: a change orphans a placed
// widget's files until the next publish.
static inline NSString *_Nullable VibeWidgetTrackKey(id<VibePlayableItem> _Nullable track) {
    return VibeKeyByAppendingCueWindow(track.url.pathKey, track.cueStart, track.cueEnd);
}

// A seek detector against the widget's own extrapolation. Looser than the
// lock screen's, since a widget entry spans seconds.
static const NSTimeInterval kVibeWidgetPositionTolerance = 2.0;

// Whether a tick publishes a new snapshot. last is the published snapshot,
// nil when nothing was published yet, and trackChanged says the track is not
// the one it describes. The widget extrapolates steady playback. So only a
// new track, a play or pause, a changed duration, title, or artist, or a jump
// past the tolerance publishes. Tags landing after the start change the title
// and artist, not the identity. While the open runs the playhead is pinned at 0, so the
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
