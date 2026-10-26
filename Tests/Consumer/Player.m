//
//  Player.m
//
//  Plays a queue of the consumer's rows through a player on the manual render
//  pump, as an app drives one: two rows of one WAV of a ramp, then a CUE
//  window of another ramp. The app's delegate prefetches what the queue says
//  follows each track's end. The first track's end advances to the second
//  row, and the window's end finishes the queue. Every frame comes back
//  exactly, and the window plays only its own.
//

#import <Foundation/Foundation.h>

#import "AudioPlayer+Debug.h"
#import "ConsumerTrack.h"
#import "VibePlaylist.h"

FOUNDATION_EXTERN BOOL ConsumerPlaysAQueue(void);
// main.m's WAV writer.
FOUNDATION_EXTERN NSURL *ConsumerRampWAV(uint32_t rate, int16_t count, int16_t first);

// The app's side of the player, on main. It keeps the queue in step with what
// sounds, and parks the queue's successor at each start and each advance.
@interface ConsumerListener : NSObject <AudioPlayerDelegate>
@property (nonatomic, strong) VibePlaylist<ConsumerTrack *> *queue;
@property (nonatomic) BOOL initialized;
@property (nonatomic) NSMutableArray<ConsumerTrack *> *started;
@property (nonatomic) NSMutableArray<NSArray<ConsumerTrack *> *> *advanced;
@property (nonatomic) NSMutableArray<ConsumerTrack *> *finished;
@property (nonatomic, strong) NSError *error;
@end

@implementation ConsumerListener
- (instancetype)init {
    if ((self = [super init])) {
        _started = [NSMutableArray array];
        _advanced = [NSMutableArray array];
        _finished = [NSMutableArray array];
    }
    return self;
}
- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {
    self.initialized = YES;
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(id<VibePlayableItem>)track
    openRequestIdentifier:(uint64_t)openRequestIdentifier {
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeLoadingPaused:(BOOL)paused
           forTrack:(id<VibePlayableItem>)track {
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(id<VibePlayableItem>)track {
    [self.started addObject:(ConsumerTrack *)track];
    [audioPlayer prefetchTrack:self.queue.trackEndSuccessor];
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(id<VibePlayableItem>)track {
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(id<VibePlayableItem>)track {
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(id<VibePlayableItem>)track {
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(id<VibePlayableItem>)track {
    [self.finished addObject:(ConsumerTrack *)track];
    if ([self.queue advanceAtTrackEnd]) {
        [audioPlayer play:self.queue.currentTrack];
    }
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer didAutoAdvanceFromTrack:(id<VibePlayableItem>)finishedTrack
            toTrack:(id<VibePlayableItem>)startedTrack {
    [self.advanced addObject:@[(ConsumerTrack *)finishedTrack, (ConsumerTrack *)startedTrack]];
    [self.queue advanceFromTrack:(ConsumerTrack *)finishedTrack toTrack:(ConsumerTrack *)startedTrack];
    [audioPlayer prefetchTrack:self.queue.trackEndSuccessor];
}
- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    self.error = error;
}
@end

static BOOL Settles(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    return done();
}

// The render drain queues its delegate calls before it returns, so a marker
// behind them on main waits for every one.
static BOOL LandsMain(void) {
    __block BOOL landed = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        landed = YES;
    });
    return Settles(^BOOL { return landed; });
}

// A ramp at the pump's rate, the same file twice, then frames 640 to 1919 of
// a second ramp, CD frames 1 to 3. Frame-driven, with Declick off, so every
// edge is a cut. After each block the app's delegate has run, and the
// queue's successor is armed on the voice before the next block renders.
// Each row is a fresh object, and every callback hands back the one queued.
BOOL ConsumerPlaysAQueue(void) {
    enum { kRampFrames = 1000, kMixFrames = 2400, kWindowStart = 640, kWindowEnd = 1920,
           kBlock = 512, kBlocks = 10 };
    NSURL *ramp = ConsumerRampWAV(48000, kRampFrames, 1);
    NSURL *mix = ConsumerRampWAV(48000, kMixFrames, 10001);
    ConsumerTrack *first = [ConsumerTrack withURL:ramp];
    ConsumerTrack *again = [ConsumerTrack withURL:ramp];
    ConsumerTrack *window = [[ConsumerTrack alloc] initWithURL:mix cueStart:1 cueEnd:3];
    ConsumerListener *listener = [ConsumerListener new];
    listener.queue = [[VibePlaylist<ConsumerTrack *> alloc] initWithURLKey:^NSURL *(ConsumerTrack *row) {
        return row.url;
    } sourceKey:^NSString *(ConsumerTrack *row) {
        return row.sourceKey;
    }];
    [listener.queue replaceAllWithTracks:@[first, again, window] startingAtIndex:0];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AudioPlayer *player = [[AudioPlayer alloc] initForManualRendering:format enableFX:NO automatic:NO
                                                             delegate:listener];
    BOOL initialized = Settles(^BOOL { return listener.initialized; });
    player.declick = NO;
    [player play:listener.queue.currentTrack];
    BOOL started = initialized && Settles(^BOOL {
        return (listener.started.count && player.gaplessArmed) || listener.error;
    }) && !listener.error;
    static float left[kBlock * kBlocks], right[kBlock * kBlocks];
    AVAudioFrameCount rendered = 0;
    NSError *renderError = nil;
    for (int block = 0; started && block < kBlocks; block++) {
        AVAudioPCMBuffer *buffer = [player debugRenderFrames:kBlock error:&renderError];
        if (buffer.frameLength != kBlock) {
            break;
        }
        memcpy(left + rendered, buffer.floatChannelData[0], kBlock * sizeof(float));
        memcpy(right + rendered, buffer.floatChannelData[1], kBlock * sizeof(float));
        rendered += kBlock;
        LandsMain();
        Settles(^BOOL {
            return !listener.queue.trackEndSuccessor || player.gaplessArmed || listener.error;
        });
    }
    [player debugShutdown];
    [NSFileManager.defaultManager removeItemAtURL:ramp error:NULL];
    [NSFileManager.defaultManager removeItemAtURL:mix error:NULL];

    AVAudioFrameCount start = 0;
    while (start < rendered && left[start] == 0 && right[start] == 0) {
        start++;
    }
    const AVAudioFrameCount heard = 2 * kRampFrames + (kWindowEnd - kWindowStart);
    BOOL exact = rendered == kBlock * kBlocks && start + heard < rendered;
    for (AVAudioFrameCount i = 0; exact && i < rendered; i++) {
        AVAudioFrameCount at = i - start;
        int want = i < start || at >= heard ? 0
                : at < 2 * kRampFrames ? (int)(at % kRampFrames) + 1
                : 10001 + kWindowStart + (int)(at - 2 * kRampFrames);
        exact = left[i] == want / 32768.0f && right[i] == -want / 32768.0f;
    }
    BOOL followed = listener.started.count == 1 && listener.started[0] == first && listener.advanced.count == 2
            && listener.advanced[0][0] == first && listener.advanced[0][1] == again
            && listener.advanced[1][0] == again && listener.advanced[1][1] == window
            && listener.finished.count == 1 && listener.finished[0] == window
            && listener.queue.currentTrack == window;
    if (!started || !exact || !followed) {
        fprintf(stderr, "consumer: the player started %d (%s), rendered %u frames from %u, exact %d (%s), "
                "advanced %lu times and finished %lu\n", started, listener.error.localizedDescription.UTF8String,
                rendered, start, exact, renderError.localizedDescription.UTF8String,
                (unsigned long)listener.advanced.count, (unsigned long)listener.finished.count);
        return NO;
    }
    return YES;
}
