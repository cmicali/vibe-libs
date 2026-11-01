//
//  WaveformLoadingTestSupport.h
//  vibe-libs
//
//  What the waveform loading tests share: an observer whose sinks record
//  what each decode fed them, and can hold a decode on its first block or
//  run a block once it has been fed so many frames; a recorder of the
//  cache's deliveries; and run-loop waits.
//

#import <Foundation/Foundation.h>

#import "AudioFileMaterializationCoordinator.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformObserver.h"

NS_ASSUME_NONNULL_BEGIN

// Spins the run loop until the condition holds, up to the hang guard.
FOUNDATION_EXPORT BOOL WaveformSpinUntil(BOOL (^condition)(void));

// Spins the run loop for a window in which nothing more may arrive.
FOUNDATION_EXPORT void WaveformSpinFor(NSTimeInterval seconds);

// Whether the track's entry is on disk, read through the lane that never
// decodes. The cache's delegate hears none of the lookup's deliveries.
FOUNDATION_EXPORT BOOL WaveformEventuallyCached(AudioWaveformCache *cache, id<VibePlayableItem> track);

// One decode's record: its rate and window, the frames it was fed, their
// loudest sample, and how often it finished.
@interface WaveformRecordingSink : NSObject <AudioWaveformSink>
@property (atomic) double sampleRate;
@property (atomic) NSRange window;
@property (atomic) NSUInteger frames;
@property (atomic) float peak;
@property (atomic) NSUInteger finishes;
@property (atomic, nullable) dispatch_semaphore_t gate;
@property (atomic, nullable) dispatch_semaphore_t entered;
// Run once, on the decode's processing queue, when the sink has been fed at
// least triggerFrames.
@property (atomic) NSUInteger triggerFrames;
@property (atomic, copy, nullable) void (^trigger)(NSUInteger frames);
@end

// An observer whose result is the frames its decode was fed.
@interface WaveformRecordingObserver : NSObject
@property (nonatomic, readonly) AudioWaveformObserver *observer;
// The most decodes that were fed and unfinished at once.
@property (atomic, readonly) NSUInteger mostLive;
- (instancetype)initWithIdentifier:(NSString *)identifier;
// The next sink made blocks on its first block until the test releases it.
- (void)holdNextDecode;
- (BOOL)awaitHeld;
- (void)resume;
// The next sink made runs trigger once it has been fed `frames`.
- (void)triggerNextDecodeAfter:(NSUInteger)frames block:(void (^)(NSUInteger frames))trigger;
- (NSArray<WaveformRecordingSink *> *)sinks;
@end

// The cache's deliveries, on main, each with the track it carried.
@interface ObserverCacheRecorder : NSObject <AudioWaveformCacheDelegate>
@property (nonatomic) NSMutableArray<id<VibePlayableItem>> *completedTracks;
@property (nonatomic) NSMutableArray<id<VibePlayableItem>> *resultTracks;
@property (nonatomic) NSMutableArray<NSDictionary *> *results;
@property (nonatomic) NSUInteger failures;
@end

// A coordinator of the test's own, and an open the user waits on that holds
// its foreground: a playback request whose dataless probe waits until the
// test lets it answer that the file is local.
@interface WaveformForeground : NSObject
@property (nonatomic, readonly) AudioFileMaterializationCoordinator *coordinator;
// An open starts, and the foreground rises. Any thread.
- (void)rise;
// Every open settles, and the foreground falls with their claims. Any thread.
- (void)settle;
@end

NS_ASSUME_NONNULL_END
