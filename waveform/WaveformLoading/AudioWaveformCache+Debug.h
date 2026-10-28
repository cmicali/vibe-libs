//
//  AudioWaveformCache+Debug.h
//  vibe-libs
//
//  Declaration-only, which keeps the shipping headers free of #if DEBUG.
//  Implemented in AudioWaveformCache+Debug.mm, in Debug builds only.
//

#import "AudioWaveformCache.h"

@interface AudioWaveformCache (Debug)

// Decodes and persists a track's waveform and its observers' results through
// the normal lookup-or-decode path, without cancelling or delivering to the
// current load. A fresh decode waits for the disk write attempt. Main-thread
// completion: ok is NO on failure, wasCached means no decode ran, and results
// are the entry's, by observer identifier.
- (void)cacheWaveformForTrack:(id<VibePlayableItem>)track
                   completion:(void (^)(BOOL ok, BOOL wasCached,
                                        NSDictionary<NSString *, id> *results))completion;

// A track's waveform data, decoded through the same path when it is not
// cached, read as `columns` equal columns across the window, 8,192 for 0.
// Each column gives its peak min and max, its loudest window, and each
// band's loudest window, with the summary's bins, frames, and rate. The
// entry's results are under "results". Main-thread completion, nil on
// failure.
- (void)dumpWaveformForTrack:(id<VibePlayableItem>)track
                     columns:(NSUInteger)columns
                  completion:(void (^)(NSDictionary *dump))completion;

// Removes one track's entry, which for a cue row is its window's alone. The
// key derives from the file's current size and mtime, so the file must still
// exist unchanged. Main-thread completion.
- (void)clearCachedWaveformForTrack:(id<VibePlayableItem>)track
                         completion:(void (^)(BOOL wasPresent))completion;

// Paces every decode that starts after it is set so the whole pass takes about
// this long, its reads held back as a long file's or a slow disk's are; 0, the
// default, is full speed. The deliveries are the loader's own, so the views'
// progressive fill-in can be watched on any file. A cached waveform never
// decodes: clear its entry first. Any thread.
@property (class, nonatomic) NSTimeInterval debugDecodeSeconds;

@end
