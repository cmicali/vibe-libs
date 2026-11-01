//
//  AudioWaveformScanTests.mm
//  vibe-libs
//
//  The scan requests, through the real cache over a store of the test's own:
//  a scan files its entry and delivers its results, scans run one at a time
//  in order, none starts while an open the user waits on is active, and a
//  running one pauses within one block on a throttled source and resumes
//  where it stopped. A load of the scan's window is never decoded twice. The
//  foreground is a coordinator of the test's own, raised by a playback
//  request, or a play's download through the fake cloud. The pause tests log
//  their latency, and one test logs the lane's throughput.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileFixtures.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWaveform.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioWaveformLoaderInternal.h"
#import "VibeFakeCloud.h"
#import "VibeReadAheadScript.h"
#import "VibeTestTrack.h"
#import "WaveformLoadingTestSupport.h"

#include <time.h>

static const NSUInteger kBlock = kVibeWaveformReadBlockFrames;

static uint64_t ScanNow(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// A 16-bit stereo WAV of the LCG's noise.
static NSURL *WriteNoiseWAV(NSURL *url, double seconds) {
    uint32_t frames = (uint32_t)(44100.0 * seconds);
    NSMutableData *samples = [NSMutableData dataWithLength:(NSUInteger)frames * 4];
    int16_t *out = (int16_t *)samples.mutableBytes;
    uint32_t state = (uint32_t)url.lastPathComponent.hash;
    for (NSUInteger i = 0; i < (NSUInteger)frames * 2; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = (int16_t)(state >> 16);
    }
    return VibeWriteWAV(url, samples, 44100, 2, 16, frames * 4);
}

// Whether two summaries hold the same bins.
static BOOL SameBins(CodableAudioWaveform *a, CodableAudioWaveform *b) {
    if (!a || !b || a.waveform->binCount() != b.waveform->binCount()) {
        return NO;
    }
    double binFrames = a.waveform->binFrames();
    for (NSUInteger i = 0; i < a.waveform->binCount(); i++) {
        wavecore::Column x = a.waveform->column(i * binFrames, (i + 1) * binFrames);
        wavecore::Column y = b.waveform->column(i * binFrames, (i + 1) * binFrames);
        if (x.lo != y.lo || x.hi != y.hi) {
            return NO;
        }
    }
    return YES;
}

// The throttled file every test shares: 8 s, alone in its directory, so only
// it reads ahead.
static NSURL *sThrottledDirectory;
static NSURL *sThrottled;
static const double kThrottledSeconds = 8;

@interface AudioWaveformScanTests : XCTestCase
@end

@implementation AudioWaveformScanTests {
    NSURL *_directory;
    ObserverCacheRecorder *_recorder;
    WaveformRecordingObserver *_observer;
    WaveformForeground *_foreground;
    AudioWaveformCache *_cache;
    VibeReadAheadScript *_readAhead;
}

+ (void)setUp {
    [super setUp];
    sThrottledDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:sThrottledDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    sThrottled = WriteNoiseWAV([sThrottledDirectory URLByAppendingPathComponent:@"throttled.wav"], kThrottledSeconds);
}

+ (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:sThrottledDirectory error:nil];
    [super tearDown];
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    _recorder = [ObserverCacheRecorder new];
    _observer = [[WaveformRecordingObserver alloc] initWithIdentifier:@"test.scan.frames"];
    _foreground = [WaveformForeground new];
    _cache = [[AudioWaveformCache alloc] initWithRootPath:[_directory URLByAppendingPathComponent:@"cache"].path];
    _cache.delegate = _recorder;
    _cache.materializationCoordinator = _foreground.coordinator;
    AudioWaveformObserver *observer = _observer.observer;
    _cache.analysisProvider = ^VibeWaveformAnalysis {
        return (VibeWaveformAnalysis){.observers = @[observer]};
    };
}

- (void)tearDown {
    [_foreground settle];
    if (VibeFakeCloud.isInstalled) {
        [VibeFakeCloud uninstall];
    }
    if (_readAhead) {
        [_readAhead releaseEverything];
        XCTAssertTrue(WaveformSpinUntil(^BOOL { return VibeReadAheadScript.threadsGone; }));
        [VibeReadAheadScript removeHook];
    }
    _cache = nil;
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    [super tearDown];
}

- (VibeTestTrack *)trackNamed:(NSString *)name seconds:(double)seconds {
    NSURL *url = WriteNoiseWAV([_directory URLByAppendingPathComponent:name], seconds);
    XCTAssertNotNil(url);
    return [VibeTestTrack withURL:url];
}

// The shared file, each read-ahead block of it, one decode block, taking
// `throttle` to arrive, as a slow share's do.
- (VibeTestTrack *)throttledTrack:(useconds_t)throttle {
    _readAhead = [[VibeReadAheadScript alloc] initForPathsContaining:sThrottledDirectory.path];
    _readAhead.throttle = throttle;
    return [VibeTestTrack withURL:sThrottled];
}

- (CodableAudioWaveform *)filedWaveform:(id<VibePlayableItem>)track {
    __block BOOL answered = NO;
    __block CodableAudioWaveform *found = nil;
    _cache.delegate = nil;
    [_cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
        found = waveform;
        answered = YES;
    }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return answered; }));
    _cache.delegate = _recorder;
    return found;
}

#pragma mark - The request

// A scan files the entry and delivers its results with its own item, never a
// waveform. A second scan of it is a hit, and decodes nothing.
- (void)testAScanFilesItsEntryAndDeliversItsResults {
    VibeTestTrack *track = [self trackNamed:@"one.wav" seconds:3];
    NSMutableArray<NSNumber *> *answers = [NSMutableArray array];
    [_cache scanWaveformForTrack:track completion:^(BOOL filed) {
        XCTAssertTrue(NSThread.isMainThread);
        [answers addObject:@(filed)];
    }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return answers.count == 1; }));
    XCTAssertEqualObjects(answers, @[@YES]);
    XCTAssertEqualObjects(_recorder.resultTracks, @[track], @"the results come first, with the scan's own item");
    XCTAssertEqual(_recorder.completedTracks.count, 0u, @"a scan delivers no waveform");
    XCTAssertEqual(_observer.sinks.firstObject.finishes, 1u);
    XCTAssertTrue(WaveformEventuallyCached(_cache, track));

    [_cache scanWaveformForTrack:track completion:^(BOOL filed) {
        [answers addObject:@(filed)];
    }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return answers.count == 2; }));
    XCTAssertEqualObjects(answers, (@[@YES, @YES]));
    XCTAssertEqual(_observer.sinks.count, 1u, @"a hit decodes nothing");
    XCTAssertEqual(_recorder.resultTracks.count, 2u, @"a hit delivers its results too");

    NSURL *missing = [_directory URLByAppendingPathComponent:@"missing.wav"];
    [_cache scanWaveformForTrack:[VibeTestTrack withURL:missing] completion:^(BOOL filed) {
        [answers addObject:@(filed)];
    }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return answers.count == 3; }));
    XCTAssertEqualObjects(answers, (@[@YES, @YES, @NO]));
    XCTAssertEqual(_recorder.failures, 0u, @"a scan's failure is its completion's, not the delegate's");
}

// Scans run one at a time, in the order asked. The lane's throughput is
// logged beside the same files' bare decodes.
- (void)testScansRunOneAtATimeInOrder {
    const NSUInteger count = 8;
    NSMutableArray<VibeTestTrack *> *tracks = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [tracks addObject:[self trackNamed:[NSString stringWithFormat:@"%lu.wav", (unsigned long)i] seconds:3 + i * 0.1]];
    }
    NSMutableArray<VibeTestTrack *> *finished = [NSMutableArray array];
    uint64_t start = ScanNow();
    for (VibeTestTrack *track in tracks) {
        [_cache scanWaveformForTrack:track completion:^(BOOL filed) {
            XCTAssertTrue(filed);
            [finished addObject:track];
        }];
    }
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return finished.count == count; }));
    double elapsed = (double)(ScanNow() - start) / 1e9;
    XCTAssertEqualObjects(finished, tracks, @"in the order asked");
    XCTAssertEqual(_observer.mostLive, 1u, @"one decode at a time");
    NSArray<WaveformRecordingSink *> *sinks = _observer.sinks;
    XCTAssertEqual(sinks.count, count);
    for (NSUInteger i = 0; i < count && i < sinks.count; i++) {
        XCTAssertEqual(sinks[i].window.length, (NSUInteger)(44100.0 * (3 + i * 0.1)), @"decode %lu", (unsigned long)i);
    }
    uint64_t bareStart = ScanNow();
    for (VibeTestTrack *track in tracks) {
        AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
        loader.analysis = (VibeWaveformAnalysis){.observers = @[_observer.observer]};
        XCTAssertNotNil([loader load:track.url.path]);
    }
    double bare = (double)(ScanNow() - bareStart) / 1e9;
    NSLog(@"Scan throughput: %lu files in %.1f ms, %.2f ms a file; bare decodes %.1f ms",
          (unsigned long)count, elapsed * 1000, elapsed * 1000 / count, bare * 1000);
}

// A cancelled scan answers nothing. A waiting one never decodes, and a
// running one stops and files nothing. The next scan runs.
- (void)testCancellingAScanDropsItsCompletionAndFilesNothing {
    VibeTestTrack *slow = [self throttledTrack:20000];
    VibeTestTrack *waiting = [self trackNamed:@"waiting.wav" seconds:2];
    VibeTestTrack *next = [self trackNamed:@"next.wav" seconds:2];
    __block NSUInteger answers = 0;
    __block BOOL nextFiled = NO;
    VibeWaveformScanToken *running = [_cache scanWaveformForTrack:slow completion:^(BOOL filed) { answers++; }];
    VibeWaveformScanToken *queued = [_cache scanWaveformForTrack:waiting completion:^(BOOL filed) { answers++; }];
    [_cache scanWaveformForTrack:next completion:^(BOOL filed) { nextFiled = filed; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_observer.sinks.firstObject.frames > 0; }));
    [queued cancel];
    [running cancel];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return nextFiled; }));
    XCTAssertEqual(answers, 0u, @"the cancelled scans finished before the next one did, unanswered");
    XCTAssertEqual(_observer.sinks.count, 2u, @"the waiting scan never decoded");
    XCTAssertEqual(_observer.sinks.firstObject.finishes, 0u);
    XCTAssertNil([self filedWaveform:slow]);
    XCTAssertNil([self filedWaveform:waiting]);
    XCTAssertEqual(_cache.debugWaitingScans, 0u);
}

#pragma mark - Pausing for the foreground

// No scan starts while an open the user waits on is active. The first
// starts once it settles.
- (void)testNoScanStartsWhileTheForegroundIsActive {
    VibeTestTrack *track = [self trackNamed:@"held.wav" seconds:2];
    [_foreground rise];
    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_cache.debugWaitingScans == 1; }), @"it waits its turn");
    XCTAssertEqual(_observer.sinks.count, 0u, @"nothing started");
    [_foreground settle];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return filed; }));
    XCTAssertEqual(_observer.sinks.count, 1u);
}

// The plan's proof. A running scan on a throttled source pauses within one
// block of the foreground rising, and files nothing while it waits. Once the
// open settles, it reads on from where it stopped, and its entry is the
// whole file's.
- (void)testAThrottledScanPausesWithinOneBlockAndResumesWhereItStopped {
    VibeTestTrack *track = [self throttledTrack:20000];
    CodableAudioWaveform *reference = [[[AudioWaveformLoader alloc] init] load:sThrottled.path];
    __block uint64_t rose = 0;
    __block NSUInteger framesAtRise = 0;
    WaveformForeground *foreground = _foreground;
    // Raised from inside the decode, after its third block, so the rise
    // lands with a read in flight.
    [_observer triggerNextDecodeAfter:3 * kBlock block:^(NSUInteger frames) {
        framesAtRise = frames;
        rose = ScanNow();
        [foreground rise];
    }];
    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_cache.debugScanPauses == 1; }));
    uint64_t paused = ScanNow();
    WaveformRecordingSink *sink = _observer.sinks.firstObject;
    NSUInteger framesAtPause = sink.frames;
    XCTAssertLessThanOrEqual(framesAtPause, framesAtRise + kBlock, @"it paused within one block");
    XCTAssertFalse(filed);
    XCTAssertNil([self filedWaveform:track], @"nothing is filed while it waits");
    NSLog(@"Scan pause on a throttled source: %.1f ms from the rise to the decode parked, %lu frames past the rise",
          (double)(paused - rose) / 1e6, (unsigned long)(framesAtPause - framesAtRise));

    [_foreground settle];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return filed; }));
    XCTAssertEqual(_observer.sinks.count, 1u, @"the same decode resumed");
    XCTAssertEqual(sink.finishes, 1u);
    XCTAssertEqual(sink.frames, (NSUInteger)(44100 * kThrottledSeconds), @"every frame once");
    XCTAssertTrue(SameBins([self filedWaveform:track], reference), @"read on from where it stopped");
    XCTAssertEqual(_cache.debugScanPauses, 1u);
}

// A scan parked on a read that waits for its bytes stops at once: the pause
// ends the wait, and the read is made again from its start on resume.
- (void)testAScanParkedOnAStalledReadPausesAtOnce {
    VibeTestTrack *track = [self throttledTrack:0];
    CodableAudioWaveform *reference = [[[AudioWaveformLoader alloc] init] load:sThrottled.path];
    // The header puts the third decode block's end in read-ahead block 3.
    [_readAhead stallFrom:3 * kReadAheadBlock];
    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_observer.sinks.firstObject.frames == 2 * kBlock; }));
    XCTAssertEqual(dispatch_semaphore_wait(_readAhead.stalled,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    uint64_t rose = ScanNow();
    [_foreground rise];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_cache.debugScanPauses == 1; }));
    uint64_t paused = ScanNow();
    XCTAssertEqual(_observer.sinks.firstObject.frames, 2 * kBlock, @"no block arrived past the stall");
    XCTAssertNil([self filedWaveform:track]);
    NSLog(@"Scan pause on a stalled read: %.1f ms from the rise to the decode parked", (double)(paused - rose) / 1e6);

    [_readAhead releaseStalls];
    [_foreground settle];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return filed; }));
    XCTAssertEqual(_observer.sinks.count, 1u);
    XCTAssertEqual(_observer.sinks.firstObject.frames, (NSUInteger)(44100 * kThrottledSeconds));
    XCTAssertTrue(SameBins([self filedWaveform:track], reference));
}

// The track on screen is never touched by a scan's pause: its load
// completes, and only the scan waits.
- (void)testAPauseNeverTouchesTheTrackOnScreen {
    VibeTestTrack *scanned = [self throttledTrack:20000];
    VibeTestTrack *playing = [self trackNamed:@"playing.wav" seconds:8];
    __block BOOL scanFiled = NO, playingFiled = NO;
    [_cache scanWaveformForTrack:scanned completion:^(BOOL done) { scanFiled = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_observer.sinks.firstObject.frames > 0; }));
    [_foreground rise];
    [_cache loadWaveformForTrack:playing filed:^(BOOL done) { playingFiled = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return playingFiled; }));
    XCTAssertEqualObjects(_recorder.completedTracks, @[playing], @"the track on screen got its waveform");
    XCTAssertEqual(_recorder.failures, 0u);
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_cache.debugScanPauses == 1; }));
    XCTAssertFalse(scanFiled);
    [_foreground settle];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return scanFiled; }));
}

// Unset, the coordinator is the shared one. A play's download through the
// fake cloud on another pauses the scan, and its settling resumes it.
- (void)testAPlaysDownloadPausesTheScanAndItsSettlingResumesIt {
    AudioFileMaterializationCoordinator *coordinator = [[AudioFileMaterializationCoordinator alloc] init];
    _cache.materializationCoordinator = nil;
    XCTAssertEqual(_cache.materializationCoordinator, AudioFileMaterializationCoordinator.sharedCoordinator);
    _cache.materializationCoordinator = coordinator;
    VibeTestTrack *track = [self throttledTrack:20000];
    NSURL *played = WriteNoiseWAV([_directory URLByAppendingPathComponent:@"played.wav"], 1);
    [VibeFakeCloud installWithTransferSeconds:0.5 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    XCTAssertFalse(coordinator.isForegroundTransferActive);

    __block BOOL filed = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { filed = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_observer.sinks.firstObject.frames > 0; }));
    __block BOOL downloaded = NO;
    __block VibeAudioFileMaterializationResult outcome = VibeAudioFileMaterializationResultFailed;
    AudioFileMaterializationRequestToken *play = [coordinator materializeURL:played
            role:VibeAudioFileMaterializationRolePlayback completionQueue:dispatch_get_main_queue()
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        outcome = result;
        downloaded = YES;
    }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_cache.debugScanPauses == 1; }), @"the play's download paused it");
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return downloaded; }));
    XCTAssertEqual(outcome, VibeAudioFileMaterializationResultReady);
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return filed; }), @"the settled download resumed it");
    XCTAssertEqual(_observer.sinks.count, 1u);
    XCTAssertTrue(WaveformEventuallyCached(_cache, track));
    (void)play;
}

#pragma mark - One decode of a window

// A scan of a window a load decodes waits on that load, then hits its entry.
- (void)testAScanOfAWindowALoadDecodesWaitsOnIt {
    VibeTestTrack *track = [self throttledTrack:20000];
    __block BOOL loaded = NO, scanned = NO;
    [_cache loadWaveformForTrack:track filed:^(BOOL done) { loaded = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_observer.sinks.firstObject.frames > 0; }));
    [_cache scanWaveformForTrack:[VibeTestTrack withURL:sThrottled] completion:^(BOOL done) { scanned = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return scanned; }));
    XCTAssertTrue(loaded, @"the load filed first");
    XCTAssertEqual(_observer.sinks.count, 1u, @"one decode");
}

// A load of the window a scan decodes turns the scan back. Its retry waits on
// the load, and hits the load's entry.
- (void)testALoadOfTheScansWindowTurnsItBack {
    VibeTestTrack *track = [self throttledTrack:20000];
    __block BOOL loaded = NO, scanned = NO;
    [_cache scanWaveformForTrack:track completion:^(BOOL done) { scanned = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return self->_observer.sinks.firstObject.frames > 0; }));
    [_cache loadWaveformForTrack:[VibeTestTrack withURL:sThrottled] filed:^(BOOL done) { loaded = done; }];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return scanned; }));
    XCTAssertTrue(loaded);
    NSArray<WaveformRecordingSink *> *sinks = _observer.sinks;
    XCTAssertEqual(sinks.count, 2u, @"the scan's decode, then the load's, and no third");
    XCTAssertEqual(sinks.firstObject.finishes, 0u, @"the scan's turned back");
    XCTAssertEqual(sinks.lastObject.finishes, 1u);
    XCTAssertEqualObjects(_recorder.completedTracks.lastObject.url, sThrottled);
}

@end
