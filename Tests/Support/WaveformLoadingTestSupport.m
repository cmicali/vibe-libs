//
//  WaveformLoadingTestSupport.m
//  vibe-libs
//

#import "WaveformLoadingTestSupport.h"
#import "AudioFileMaterializationCoordinatorInternal.h"

#include <math.h>

BOOL WaveformSpinUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow < 0) {
            return NO;
        }
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    return YES;
}

void WaveformSpinFor(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
    } while (until.timeIntervalSinceNow > 0);
}

BOOL WaveformEventuallyCached(AudioWaveformCache *cache, id<VibePlayableItem> track) {
    id<AudioWaveformCacheDelegate> delegate = cache.delegate;
    cache.delegate = nil;
    __block BOOL cached = NO;
    BOOL found = WaveformSpinUntil(^BOOL {
        __block BOOL answered = NO;
        [cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
            cached = waveform != nil;
            answered = YES;
        }];
        WaveformSpinUntil(^BOOL { return answered; });
        return cached;
    });
    cache.delegate = delegate;
    return found;
}

@implementation WaveformRecordingSink
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    if (self.gate && self.frames == 0) {
        dispatch_semaphore_signal(self.entered);
        dispatch_semaphore_wait(self.gate, DISPATCH_TIME_FOREVER);
    }
    float peak = self.peak;
    for (NSUInteger i = 0; i < frameCount; i++) {
        peak = MAX(peak, fabsf(samples[i]));
    }
    self.peak = peak;
    self.frames += frameCount;
    void (^trigger)(NSUInteger) = self.trigger;
    if (trigger && self.frames >= self.triggerFrames) {
        self.trigger = nil;
        trigger(self.frames);
    }
}
- (id)waveformResult {
    self.finishes++;
    return @(self.frames);
}
@end

@implementation WaveformRecordingObserver {
    NSMutableArray<WaveformRecordingSink *> *_sinks;
    // The next sink's gate, and every gate handed out and not yet opened.
    dispatch_semaphore_t _gate;
    dispatch_semaphore_t _entered;
    NSMutableArray<dispatch_semaphore_t> *_closed;
    NSUInteger _triggerFrames;
    void (^_trigger)(NSUInteger);
    NSUInteger _mostLive;
}

- (instancetype)initWithIdentifier:(NSString *)identifier {
    if ((self = [super init])) {
        _sinks = [NSMutableArray array];
        _closed = [NSMutableArray array];
        __weak WaveformRecordingObserver *weakSelf = self;
        _observer = [[AudioWaveformObserver alloc] initWithIdentifier:identifier
                sinkFactory:^id<AudioWaveformSink>(double sampleRate, NSRange window) {
            WaveformRecordingSink *sink = [WaveformRecordingSink new];
            sink.sampleRate = sampleRate;
            sink.window = window;
            WaveformRecordingObserver *strongSelf = weakSelf;
            @synchronized (strongSelf) {
                sink.gate = strongSelf->_gate;
                sink.entered = strongSelf->_entered;
                strongSelf->_gate = nil;
                sink.triggerFrames = strongSelf->_triggerFrames;
                sink.trigger = strongSelf->_trigger;
                strongSelf->_trigger = nil;
                NSUInteger live = 1;
                for (WaveformRecordingSink *other in strongSelf->_sinks) {
                    live += other.finishes == 0 && other.frames < other.window.length;
                }
                strongSelf->_mostLive = MAX(strongSelf->_mostLive, live);
                [strongSelf->_sinks addObject:sink];
            }
            return sink;
        }];
    }
    return self;
}

- (NSUInteger)mostLive {
    @synchronized (self) {
        return _mostLive;
    }
}

- (void)holdNextDecode {
    @synchronized (self) {
        _gate = dispatch_semaphore_create(0);
        _entered = dispatch_semaphore_create(0);
        [_closed addObject:_gate];
    }
}

- (BOOL)awaitHeld {
    return dispatch_semaphore_wait(_entered, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
}

- (void)resume {
    @synchronized (self) {
        for (dispatch_semaphore_t gate in _closed) {
            dispatch_semaphore_signal(gate);
        }
        [_closed removeAllObjects];
    }
}

- (void)triggerNextDecodeAfter:(NSUInteger)frames block:(void (^)(NSUInteger))trigger {
    @synchronized (self) {
        _triggerFrames = frames;
        _trigger = [trigger copy];
    }
}

- (NSArray<WaveformRecordingSink *> *)sinks {
    @synchronized (self) {
        return [_sinks copy];
    }
}

@end

@implementation ObserverCacheRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _completedTracks = [NSMutableArray array];
        _resultTracks = [NSMutableArray array];
        _results = [NSMutableArray array];
    }
    return self;
}
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded
             forTrack:(id<VibePlayableItem>)track {
    if (percentLoaded >= 1) {
        [_completedTracks addObject:track];
    }
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(id<VibePlayableItem>)track {
    _failures++;
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache
            didLoadResults:(NSDictionary<NSString *, id> *)results
                  forTrack:(id<VibePlayableItem>)track {
    [_resultTracks addObject:track];
    [_results addObject:results];
}
@end

@implementation WaveformForeground {
    // The gates the next probes wait on, and every gate not yet opened.
    NSMutableArray<dispatch_semaphore_t> *_next;
    NSMutableArray<dispatch_semaphore_t> *_closed;
    NSMutableArray<AudioFileMaterializationRequestToken *> *_opens;
    NSUInteger _count;
}

- (instancetype)init {
    if ((self = [super init])) {
        _next = [NSMutableArray array];
        _closed = [NSMutableArray array];
        _opens = [NSMutableArray array];
        NSMutableArray<dispatch_semaphore_t> *next = _next;
        _coordinator = [[AudioFileMaterializationCoordinator alloc]
                initWithConfiguration:[AudioLoadingConfiguration productionConfiguration]
                     operationFactory:^id<AudioFileMaterializationOperation>(NSURL *url, VibeAudioFileMaterializationRole role) {
            NSCAssert(NO, @"a local file starts no transfer");
            return (id<AudioFileMaterializationOperation>)[NSObject new];
        } datalessProbe:^BOOL(NSURL *url) {
            dispatch_semaphore_t gate;
            @synchronized (next) {
                gate = next.firstObject;
                [next removeObjectAtIndex:0];
            }
            dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
            return NO;
        } clock:^NSTimeInterval {
            return NSProcessInfo.processInfo.systemUptime;
        }];
    }
    return self;
}

- (void)rise {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    NSString *name;
    @synchronized (_next) {
        [_next addObject:gate];
        [_closed addObject:gate];
        name = [NSString stringWithFormat:@"play-%@-%lu.wav", NSUUID.UUID.UUIDString, (unsigned long)++_count];
    }
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    AudioFileMaterializationRequestToken *open = [_coordinator materializeURL:url
            role:VibeAudioFileMaterializationRolePlayback completionQueue:dispatch_get_main_queue()
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {}];
    @synchronized (_next) {
        [_opens addObject:open];
    }
}

- (void)settle {
    @synchronized (_next) {
        for (dispatch_semaphore_t gate in _closed) {
            dispatch_semaphore_signal(gate);
        }
        [_closed removeAllObjects];
        [_opens removeAllObjects];
    }
}

- (void)dealloc {
    [self settle];
}

@end
