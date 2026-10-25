//
//  PlaybackDeliveryRules.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A delivery belongs to the play that submitted it. A newer submission, of
// the same item too, supersedes it.
static inline BOOL VibePlaybackDeliveryIsCurrent(
        uint64_t owningSubmittedPlayIdentifier,
        uint64_t newestSubmittedPlayIdentifier) {
    return owningSubmittedPlayIdentifier != 0
            && owningSubmittedPlayIdentifier == newestSubmittedPlayIdentifier;
}

// A media-services reset is not itself a play, so zero is a valid initial
// snapshot here. Its completion may re-park the playlist only if no play was
// submitted while the engine rebuild was in flight.
static inline BOOL VibePlaybackSubmissionStateIsUnchanged(
        uint64_t capturedNewestSubmittedPlayIdentifier,
        uint64_t newestSubmittedPlayIdentifier) {
    return capturedNewestSubmittedPlayIdentifier == newestSubmittedPlayIdentifier;
}

NS_ASSUME_NONNULL_END
