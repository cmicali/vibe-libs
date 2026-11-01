//
//  AudioWaveformScanTests.mm
//  vibe-libs
//
//  The scan requests, through the real cache over a store of the test's own:
//  a scan files its entry and delivers its results, scans run one at a time
//  in order, none is admitted while an open the user waits on is active, and
//  a running one yields within one block on a throttled source, files
//  nothing, and decodes again once the open settles. A play's download
//  through the fake cloud is the foreground the shared coordinator reports.
//  The yield tests log their latency, and one test logs the lane's
//  throughput.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileFixtures.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWaveform.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioWaveformObserver.h"
#import "VibeFakeCloud.h"
#import "VibeReadAheadScript.h"
#import "VibeTestTrack.h"

#include <atomic>
#include <memory>
#include <cmath>
#include <time.h>

// The decode's read, in frames: 256 KB of 16-bit stereo, one read-ahead block.
static const NSUInteger kScanBlockFrames = 65536;

static uint64_t ScanNow(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// One decode's record: the frames it was fed, when it was made, and whether
// it finished.
@interface ScanSink : NSObject <AudioWaveformSink>
@property (atomic) NSRange window;
@property (atomic) NSUInteger frames;
@property (atomic) BOOL finished;
// Run on the processing queue once the sink has been fed this many frames.
@property (atomic) NSUInteger triggerFrames;
@property (atomic, copy, nullable) void (^trigger)(NSUInteger frames);
@end

@implementation ScanSink
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    self.frames += frameCount;
    void (^trigger)(NSUInteger) = self.trigger;
    if (trigger && self.frames >= self.triggerFrames) {
        self.trigger = nil;
        trigger(self.frames);
    }
}
- (id)waveformResult {
    self.finished = YES;
    return @(self.frames);
}
@end

// Makes a sink per decode, and counts how many decodes are live at once.
@interface ScanObserver : NSObject
@property (nonatomic, readonly) AudioWaveformObserver *observer;
@property (atomic) NSUInteger mostLive;
// Handed to the next sink made.
@property (atomic) NSUInteger nextTriggerFrames;
@property (atomic, copy, nullable) void (^nextTrigger)(NSUInteger frames);
- (NSArray<ScanSink *> *)sinks;
@end

@implementation ScanObserver {
    NSMutableArray<ScanSink *> *_sinks;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sinks = [NSMutableArray array];
        __weak ScanObserver *weakSelf = self;
        _observer = [[AudioWaveformObserver alloc] initWithIdentifier:@"test.scan.frames"
                sinkFactory:^id<AudioWaveformSink>(double sampleRate, NSRange window) {
            ScanObserver *strongSelf = weakSelf;
            ScanSink *sink = [ScanSink new];
            sink.window = window;
            @synchronized (strongSelf) {
                sink.triggerFrames = strongSelf.nextTriggerFrames;
                sink.trigger = strongSelf.nextTrigger;
                strongSelf.nextTrigger = nil;
                NSUInteger live = 1;
                for (ScanSink *other in strongSelf->_sinks) {
                    live += !other.finished && other.frames < other.window.length;
                }
                strongSelf.mostLive = MAX(strongSelf.mostLive, live);
                [strongSelf->_sinks addObject:sink];
            }
            return sink;
        }];
    }
    return self;
}

- (NSArray<ScanSink *> *)sinks {
    @synchronized (self) {
        return [_sinks copy];
    }
}

@end

@interface ScanRecorder : NSObject <AudioWaveformCacheDelegate>
@property (nonatomic) NSUInteger waveforms;
@property (nonatomic) NSUInteger failures;
@property (nonatomic, readonly) NSMutableArray<id<VibePlayableItem>> *resultTracks;
@end

@implementation ScanRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _resultTracks = [NSMutableArray array];
    }
    return self;
}
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded forTrack:(id<VibePlayableItem>)track {
    if (percentLoaded >= 1) {
        _waveforms++;
    }
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(id<VibePlayableItem>)track {
    _failures++;
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache didLoadResults:(NSDictionary<NSString *, id> *)results
                  forTrack:(id<VibePlayableItem>)track {
    [_resultTracks addObject:track];
}
@end

@interface AudioWaveformScanTests : XCTestCase
@end

@implementation AudioWaveformScanTests {
    NSURL *_directory;
    ScanRecorder *_recorder;
    ScanObserver *_observer;
    AudioWaveformCache *_cache;
    // The foreground the cache reads, unless a test leaves the provider unset.
    std::atomic<bool> _foreground;
    VibeReadAheadScript *_readAhead;
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    _recorder = [ScanRecorder new];
    _observer = [ScanObserver new];
    _foreground = false;
    _cache = [[AudioWaveformCache alloc] initWithRootPath:[_directory URLByAppendingPathComponent:@"cache"].path];
    _cache.delegate = _recorder;
    AudioWaveformObserver *observer = _observer.observer;
    _cache.analysisProvider = ^VibeWaveformAnalysis {
        return (VibeWaveformAnalysis){.observers = @[observer]};
    };
    std::atomic<bool> *foreground = &_foreground;
    _cache.foregroundProvider = ^BOOL {
        return foreground->load();
    };
}

- (void)tearDown {
    // Nothing reads the flag once the cache is gone and its scans are drained.
    _foreground = false;
    if (VibeFakeCloud.isInstalled) {
        [VibeFakeCloud uninstall];
    }
    if (_readAhead) {
        [_readAhead releaseEverything];
        XCTAssertTrue([self spinUntil:^BOOL { return VibeReadAheadScript.threadsGone; }]);
        [VibeReadAheadScript removeHook];
    }
    _cache = nil;
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    [super tearDown];
}

- (BOOL)spinUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) {
            return NO;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    return YES;
}

- (void)spinFor:(NSTimeInterval)seconds {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// A 16-bit stereo WAV of nonperiodic noise.
- (NSURL *)writeWAVNamed:(NSString *)name seconds:(double)seconds {
    uint32_t frames = (uint32_t)(44100.0 * seconds);
    NSMutableData *samples = [NSMutableData dataWithLength:(NSUInteger)frames * 4];
    int16_t *out = (int16_t *)samples.mutableBytes;
    uint32_t state = (uint32_t)name.hash;
    for (NSUInteger i = 0; i < (NSUInteger)frames * 2; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = (int16_t)(sin((double)i * 0.00071) * 16000.0 + (double)(int16_t)(state >> 16) * 0.4);
    }
    NSURL *url = [_directory URLByAppendingPathComponent:name];
    XCTAssertNotNil(VibeWriteWAV(url, samples, 44100, 2, 16, frames * 4));
    return url;
}

// Whether a cache-only lookup finds the track's entry.
- (BOOL)isFiled:(id<VibePlayableItem>)track {
    __block BOOL answered = NO, found = NO;
    [_cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
        found = waveform != nil;
        answered = YES;
    }];
    XCTAssertTrue([self spinUntil:^BOOL { return answered; }]);
    return found;
}

// A file whose reads each wait `throttle` for their block, as a slow share's do.
- (NSURL *)throttledWAVNamed:(NSString *)name seconds:(double)seconds throttle:(useconds_t)throttle {
    NSURL *url = [self writeWAVNamed:name seconds:seconds];
    _readAhead = [[VibeReadAheadScript alloc] initForPathsContaining:_directory.path];
    _readAhead.throttle = throttle;
    return url;
}

#pragma mark - The request

// A scan files the entry and delivers its results with its own item, never a
// waveform. A second scan of it is a hit, and decodes nothing.
- (void)testAScanFilesItsEntryAndDeliversItsResults {
    VibeTestTrack *track = [VibeTestTrack withURL:[self writeWAVNamed:@"one.wav" seconds:3]];
    NSMutableArray<NSNumber *> *answers = [NSMutableArray array];
    [_cache scanWaveformForTrack:track completion:^(BOOL filed) {
        XCTAssertTrue(NSThread.isMainThread);
        [answers addObject:@(filed)];
    }];
    XCTAssertTrue([self spinUntil:^BOOL { return answers.count == 1; }]);
    XCTAssertEqualObjects(answers, @[@YES]);
    XCTAssertEqual(_recorder.resultTracks.count, 1u, @"the results come before the completion");
    XCTAssertEqual(_recorder.resultTracks.firstObject, track, @"with the scan's own item");
    XCTAssertEqual(_recorder.waveforms, 0u, @"a scan delivers no waveform");
    XCTAssertTrue(_observer.sinks.firstObject.finished);
    XCTAssertTrue([self isFiled:track]);

    NSUInteger delivered = _recorder.resultTracks.count;
    [_cache scanWaveformForTrack:track completion:^(BOOL filed) {
        [answers addObject:@(filed)];
    }];
    XCTAssertTrue([self spinUntil:^BOOL { return answers.count == 2; }]);
    XCTAssertEqualObjects(answers, (@[@YES, @YES]));
    XCTAssertEqual(_observer.sinks.count, 1u, @"a hit decodes nothing");
    XCTAssertEqual(_recorder.resultTracks.count, delivered + 1, @"a hit delivers its results too");

    NSURL *missing = [_directory URLByAppendingPathComponent:@"missing.wav"];
    [_cache scanWaveformForTrack:[VibeTestTrack withURL:missing] completion:^(BOOL filed) {
        [answers addObject:@(filed)];
    }];
    XCTAssertTrue([self spinUntil:^BOOL { return answers.count == 3; }]);
    XCTAssertEqualObjects(answers, (@[@YES, @YES, @NO]));
    XCTAssertEqual(_recorder.failures, 0u, @"a scan's failure is its completion's, not the delegate's");
}

// Scans run one at a time, in the order asked. The lane's throughput, with
// FileLoading's foreground read before each block, is logged for the record
// beside the same files' bare decodes.
- (void)testScansRunOneAtATimeInOrder {
    _cache.foregroundProvider = nil;
    const NSUInteger count = 8;
    const double seconds = 30;
    NSMutableArray<VibeTestTrack *> *tracks = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [tracks addObject:[VibeTestTrack withURL:[self writeWAVNamed:[NSString stringWithFormat:@"%lu.wav", (unsigned long)i]
                                                             seconds:seconds + i]]];
    }
    NSMutableArray<VibeTestTrack *> *finished = [NSMutableArray array];
    uint64_t start = ScanNow();
    for (VibeTestTrack *track in tracks) {
        [_cache scanWaveformForTrack:track completion:^(BOOL filed) {
            XCTAssertTrue(filed);
            [finished addObject:track];
        }];
    }
    XCTAssertTrue([self spinUntil:^BOOL { return finished.count == count; }]);
    double elapsed = (double)(ScanNow() - start) / 1e9;
    XCTAssertEqualObjects(finished, tracks, @"in the order asked");
    XCTAssertEqual(_observer.mostLive, 1u, @"one decode at a time");
    NSArray<ScanSink *> *sinks = _observer.sinks;
    XCTAssertEqual(sinks.count, count);
    for (NSUInteger i = 0; i < count && i < sinks.count; i++) {
        XCTAssertEqual(sinks[i].window.length, (NSUInteger)(44100.0 * (seconds + i)), @"decode %lu", (unsigned long)i);
    }
    double audio = count * seconds + (double)(count * (count - 1)) / 2;
    uint64_t bareStart = ScanNow();
    for (VibeTestTrack *track in tracks) {
        AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
        loader.analysis = (VibeWaveformAnalysis){.observers = @[_observer.observer]};
        XCTAssertNotNil([loader load:track.url.path]);
    }
    double bare = (double)(ScanNow() - bareStart) / 1e9;
    NSLog(@"Scan throughput: %lu files, %.0f s of audio in %.3f s, %.0fx real time, %.1f ms a file; bare decodes %.3f s",
          (unsigned long)count, audio, elapsed, audio / elapsed, elapsed * 1000 / count, bare);
}

// A cancelled scan answers nothing. A waiting one never decodes, and a
// running one stops and files nothing. The next scan runs.
- (void)testCancellingAScanDropsItsCompletionAndFilesNothing {
    VibeTestTrack *slow = [VibeTestTrack withURL:[self throttledWAVNamed:@"slow.wav" seconds:30 throttle:20000]];
    VibeTestTrack *waiting = [VibeTestTrack withURL:[self writeWAVNamed:@"waiting.wav" seconds:2]];
    VibeTestTrack *next = [VibeTestTrack withURL:[self writeWAVNamed:@"next.wav" seconds:2]];
    __block NSUInteger answers = 0;
    __block BOOL nextFiled = NO;
    VibeWaveformScanToken *running = [_cache scanWaveformForTrack:slow completion:^(BOOL filed) { answers++; }];
    VibeWaveformScanToken *queued = [_cache scanWaveformForTrack:waiting completion:^(BOOL filed) { answers++; }];
    [_cache scanWaveformForTrack:next completion:^(BOOL filed) { nextFiled = filed; }];
    XCTAssertTrue([self spinUntil:^BOOL { return self->_observer.sinks.firstObject.frames > 0; }]);
    [queued cancel];
    [running cancel];
    XCTAssertTrue([self spinUntil:^BOOL { return nextFiled; }]);
    [self spinFor:0.1];
    XCTAssertEqual(answers, 0u);
    XCTAssertEqual(_observer.sinks.count, 2u, @"the waiting scan never decoded");
    XCTAssertFalse(_observer.sinks.firstObject.finished);
    XCTAssertLessThan(_observer.sinks.firstObject.frames, _observer.sinks.firstObject.window.length);
    XCTAssertFalse([self isFiled:slow]);
    XCTAssertFalse([self isFiled:waiting]);
    XCTAssertEqual(_cache.debugScanYields, 0u, @"a cancel is no yield");
}

#pragma mark - Yielding to the foreground

// No scan is admitted while an open the user waits on is active. The
// first is admitted once it settles.
- (void)testNoScanIsAdmittedWhileTheForegroundIsActive {
    VibeTestTrack *track = [VibeTestTrack withURL:[self writeWAVNamed:@"held.wav" seconds:2]];
    _foreground = true;
    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    [self spinFor:0.5];
    XCTAssertEqual(_observer.sinks.count, 0u, @"nothing was admitted");
    XCTAssertFalse(filed);
    _foreground = false;
    XCTAssertTrue([self spinUntil:^BOOL { return filed; }]);
    XCTAssertEqual(_observer.sinks.count, 1u);
}

// The plan's proof. A running scan on a throttled source yields within one
// block of the foreground rising: its decode stops, its partial summary is
// dropped, and nothing is filed. Once the foreground settles it decodes again
// from its start, and files.
- (void)testAThrottledScanYieldsWithinOneBlockAndResumes {
    // Each read-ahead block, one decode block, takes 20 ms to arrive.
    VibeTestTrack *track = [VibeTestTrack withURL:[self throttledWAVNamed:@"throttled.wav" seconds:30 throttle:20000]];
    auto rose = std::make_shared<std::atomic<uint64_t>>(0);
    auto framesAtRise = std::make_shared<std::atomic<NSUInteger>>(0);
    std::atomic<bool> *foreground = &_foreground;
    // Rises from inside the decode, after its third block, so the rise lands
    // with a read in flight.
    _observer.nextTriggerFrames = 3 * kScanBlockFrames;
    _observer.nextTrigger = ^(NSUInteger frames) {
        framesAtRise->store(frames);
        rose->store(ScanNow());
        foreground->store(true);
    };
    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertTrue([self spinUntil:^BOOL { return self->_cache.debugScanYields == 1; }]);
    uint64_t yielded = ScanNow();
    ScanSink *first = _observer.sinks.firstObject;
    XCTAssertLessThanOrEqual(first.frames, framesAtRise->load() + kScanBlockFrames, @"it yielded within one block");
    XCTAssertFalse(first.finished, @"its partial summary was dropped");
    XCTAssertFalse(filed);
    XCTAssertFalse([self isFiled:track], @"nothing was filed");
    [self spinFor:0.3];
    XCTAssertEqual(_observer.sinks.count, 1u, @"no decode while the foreground is active");
    NSLog(@"Scan yield on a throttled source: %.1f ms from the rise to the decode stopped, %lu frames past the rise",
          (double)(yielded - rose->load()) / 1e6, (unsigned long)(first.frames - framesAtRise->load()));

    _foreground = false;
    XCTAssertTrue([self spinUntil:^BOOL { return filed; }]);
    XCTAssertEqual(_observer.sinks.count, 2u);
    XCTAssertTrue(_observer.sinks.lastObject.finished, @"it decoded again from its start");
    XCTAssertEqual(_observer.sinks.lastObject.frames, (NSUInteger)(44100 * 30));
    XCTAssertTrue([self isFiled:track]);
    XCTAssertEqual(_cache.debugScanYields, 1u);
}

// A scan parked on a read that waits for its bytes asks nothing, so the
// lane's watch cancels it, and the cancel ends the wait at once.
- (void)testAScanParkedOnAStalledReadYieldsAtOnce {
    VibeTestTrack *track = [VibeTestTrack withURL:[self throttledWAVNamed:@"stalled.wav" seconds:30 throttle:0]];
    [_readAhead stallFrom:4 * kReadAheadBlock];
    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertEqual(dispatch_semaphore_wait(_readAhead.stalled,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    // Past the reads already through, so the decode itself is parked.
    [self spinFor:0.2];
    NSUInteger before = _observer.sinks.firstObject.frames;
    uint64_t rose = ScanNow();
    _foreground = true;
    XCTAssertTrue([self spinUntil:^BOOL { return self->_cache.debugScanYields == 1; }]);
    uint64_t yielded = ScanNow();
    XCTAssertEqual(_observer.sinks.firstObject.frames, before, @"no block arrived past the stall");
    XCTAssertFalse([self isFiled:track]);
    NSLog(@"Scan yield on a stalled read: %.1f ms from the rise to the decode stopped", (double)(yielded - rose) / 1e6);

    [_readAhead releaseStalls];
    _foreground = false;
    XCTAssertTrue([self spinUntil:^BOOL { return filed; }]);
    XCTAssertTrue([self isFiled:track]);
}

// The track on screen is never cancelled by a scan's yield: its load
// completes, and only the scan turns back.
- (void)testAYieldNeverCancelsTheTrackOnScreen {
    VibeTestTrack *scanned = [VibeTestTrack withURL:[self throttledWAVNamed:@"scanned.wav" seconds:30 throttle:20000]];
    VibeTestTrack *playing = [VibeTestTrack withURL:[self writeWAVNamed:@"playing.wav" seconds:30]];
    __block BOOL scanFiled = NO, playingFiled = NO;
    [_cache scanWaveformForTrack:scanned completion:^(BOOL done) { scanFiled = done; }];
    XCTAssertTrue([self spinUntil:^BOOL { return self->_observer.sinks.firstObject.frames > 0; }]);
    _foreground = true;
    [_cache loadWaveformForTrack:playing filed:^(BOOL done) { playingFiled = done; }];
    XCTAssertTrue([self spinUntil:^BOOL { return playingFiled; }]);
    XCTAssertEqual(_recorder.waveforms, 1u, @"the track on screen got its waveform");
    XCTAssertEqual(_recorder.failures, 0u);
    XCTAssertTrue([self spinUntil:^BOOL { return self->_cache.debugScanYields == 1; }]);
    XCTAssertFalse(scanFiled);
    _foreground = false;
    XCTAssertTrue([self spinUntil:^BOOL { return scanFiled; }]);
}

// Unset, the provider is FileLoading's foreground state. A play's download
// through the fake cloud turns the scan back, and its settling resumes it.
- (void)testAPlaysDownloadTurnsTheScanBackAndItsSettlingResumesIt {
    _cache.foregroundProvider = nil;
    VibeTestTrack *track = [VibeTestTrack withURL:[self throttledWAVNamed:@"library.wav" seconds:30 throttle:20000]];
    NSURL *played = [[_directory URLByAppendingPathComponent:@"cloud" isDirectory:YES] URLByAppendingPathComponent:@"played.wav"];
    [NSFileManager.defaultManager createDirectoryAtURL:played.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:nil];
    [self writeWAVNamed:@"cloud/played.wav" seconds:1];
    [VibeFakeCloud installWithTransferSeconds:0.5 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
    XCTAssertFalse(coordinator.isForegroundTransferActive);

    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertTrue([self spinUntil:^BOOL { return self->_observer.sinks.firstObject.frames > 0; }]);
    __block BOOL downloaded = NO;
    __block VibeAudioFileMaterializationResult outcome = VibeAudioFileMaterializationResultFailed;
    AudioFileMaterializationRequestToken *play = [coordinator materializeURL:played
            role:VibeAudioFileMaterializationRolePlayback completionQueue:dispatch_get_main_queue()
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        outcome = result;
        downloaded = YES;
    }];
    XCTAssertTrue([self spinUntil:^BOOL { return self->_cache.debugScanYields == 1; }], @"the play's download turned it back");
    XCTAssertTrue(coordinator.isForegroundTransferActive);
    XCTAssertEqual(_observer.sinks.count, 1u);
    XCTAssertTrue([self spinUntil:^BOOL { return downloaded; }]);
    XCTAssertEqual(outcome, VibeAudioFileMaterializationResultReady);
    XCTAssertTrue([self spinUntil:^BOOL { return filed; }], @"the settled download resumed it");
    XCTAssertEqual(_observer.sinks.count, 2u);
    XCTAssertTrue([self isFiled:track]);
    (void)play;
}

@end
