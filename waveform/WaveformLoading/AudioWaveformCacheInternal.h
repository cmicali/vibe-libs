//
//  AudioWaveformCacheInternal.h
//  vibe-libs
//
//  The state, the entry key, and the lookup-or-decode path the debug seam's
//  per-file cache control shares with the delegate path
//  (AudioWaveformCache+Debug.mm).
//

#import "AudioWaveformCache.h"

@class AudioWorkScheduler;
@class AudioWaveformLoader;
@class CodableAudioWaveform;
@class PINCache;
@class VibeWaveformLoadClaim;

NS_ASSUME_NONNULL_BEGIN

// The key a track's entry is filed under: its file's disk key, with the
// window appended for a cue row. nil when the file cannot be statted. It
// stats the file, so it is called off main and off the loader queue.
static inline NSString *_Nullable VibeWaveformEntryKey(id<VibePlayableItem> track) {
    return VibeKeyByAppendingCueWindow(track.cacheKey, track.cueStart, track.cueEnd);
}

@interface AudioWaveformCache () {
    dispatch_queue_t                _loaderQueue;
    // Stat and open cannot be interrupted; fixed slots bound blocked workers.
    AudioWorkScheduler              *_lookupScheduler;
    AudioWorkScheduler              *_previewScheduler;
    // Deep zoom's reads, apart from the decodes, so a stuck one holds no
    // decode slot.
    AudioWorkScheduler              *_detailScheduler;
    AudioWorkScheduler              *_decodeScheduler;
    PINCache*                       _waveformCache;
}

// The lookup-or-decode path every load takes. AudioWaveformCache.mm states
// its contract.
- (void)load:(id<VibePlayableItem>)track
    cacheKey:(NSString *)cacheKey
  withLoader:(AudioWaveformLoader *)loader
       claim:(nullable VibeWaveformLoadClaim *)claim
  completion:(void (^)(CodableAudioWaveform *_Nullable waveform, BOOL wasCached))completion
     settled:(void (^)(BOOL filed))settled;

@end

NS_ASSUME_NONNULL_END
