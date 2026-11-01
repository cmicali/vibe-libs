//
//  AudioWaveformCacheInternal.h
//  vibe-libs
//
//  The state, the scans' line, the entry key, and the lookup-or-decode path
//  every load takes: the delegate's, the scans', and the debug seam's
//  (AudioWaveformCache+Debug.mm).
//

#import "AudioWaveformCache.h"

#include <atomic>

@class AudioWorkScheduler;
@class AudioWaveformLoader;
@class CodableAudioWaveform;
@class PINCache;
@class VibeWaveformLoadClaim;
@class VibeWaveformScanToken;

NS_ASSUME_NONNULL_BEGIN

// The key a track's entry is filed under: its file's disk key, with the
// window appended for a cue row. nil when the file cannot be statted. It
// stats the file, so it is called off main and off the loader queue.
static inline NSString *_Nullable VibeWaveformEntryKey(id<VibePlayableItem> track) {
    return VibeKeyByAppendingCueWindow(track.cacheKey, track.cueStart, track.cueEnd);
}

// A scan request is its own token. Its state is confined to the cache's scan
// queue, but for the completion, which is main's.
@interface VibeWaveformScanToken ()
@property (nonatomic, weak) AudioWaveformCache *cache;
@property (nonatomic, strong) id<VibePlayableItem> track;
// The claim key a load of the same window files under.
@property (nonatomic, copy) NSString *key;
@property (nonatomic) VibeWaveformAnalysis analysis;
@property (nonatomic, copy, nullable) void (^completion)(BOOL filed);
@property (atomic) BOOL cancelled;
// The decode running for it, or nil while it waits.
@property (nonatomic, strong, nullable) AudioWaveformLoader *loader;
@end

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
    // The scans. All but the count are confined to _scanQueue.
    dispatch_queue_t                _scanQueue;
    // The scan's stat and lookup, then its decode. The cache's line, not this
    // scheduler, bounds the lane: it admits one scan at a time.
    AudioWorkScheduler              *_scanScheduler;
    // The line, oldest first. The head runs while _runningScan is set, and
    // leaves it once it completes or is cancelled. A cancelled scan further
    // back is skipped when it reaches the head.
    NSMutableArray<VibeWaveformScanToken *> *_waitingScans;
    VibeWaveformScanToken           *_runningScan;
    // The coordinator's foreground, as its last edge said.
    BOOL                            _scanForeground;
    BOOL                            _scanObserving;
    // How often a scan's decode has been told to pause, and how often it has
    // parked for the foreground. Any thread.
    std::atomic<NSUInteger>         _scanPausesAsked;
    std::atomic<NSUInteger>         _scanPauses;
}

// Every load's path: the stat on `lookups`, then load: below, its decode on
// `decodes`. failed runs once when the file cannot be statted or a lane
// refuses the work, and then neither completion nor settled runs.
- (AudioWorkToken *)lookUpOrDecode:(id<VibePlayableItem>)track
                            loader:(AudioWaveformLoader *)loader
                             claim:(nullable VibeWaveformLoadClaim *)claim
                           lookups:(AudioWorkScheduler *)lookups
                           decodes:(AudioWorkScheduler *)decodes
                        completion:(void (^)(CodableAudioWaveform *_Nullable waveform, BOOL wasCached))completion
                           settled:(void (^)(BOOL filed))settled
                            failed:(dispatch_block_t)failed;

// The lookup-or-decode core, its decode on `scheduler`.
// AudioWaveformCache.mm states its contract.
- (void)load:(id<VibePlayableItem>)track
    cacheKey:(NSString *)cacheKey
  withLoader:(AudioWaveformLoader *)loader
       claim:(nullable VibeWaveformLoadClaim *)claim
   scheduler:(AudioWorkScheduler *)scheduler
  completion:(void (^)(CodableAudioWaveform *_Nullable waveform, BOOL wasCached))completion
     settled:(void (^)(BOOL filed))settled;

@end

NS_ASSUME_NONNULL_END
