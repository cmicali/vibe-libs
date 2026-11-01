//
//  AudioPlayerFileGainTests.m
//
//  The whole player on the frame-driven pump, playing each file at the gain
//  its request carries. Every sample of every fixture names its file and its
//  frame, and every gain is a power of two, so a captured sample divided by
//  its gain names exactly where it came from.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioPlayer+Debug.h"
#import "AudioPlayerInternal.h"
#import "AudioReferenceFixtures.h"
#import "AudioVoiceBusInternal.h"
#import "VibeTestTrack.h"

static const double kGainRate = 48000;
static const NSUInteger kGainFrames = 48000; // each of the four files, 1 s: the ring holds more
static const NSUInteger kGainDeclickFrames = 480; // a play's 10 ms fade in, at 48 kHz

// A sample's code: its file in the bits above 17, its frame below. Exact in
// float32, and negated on the right channel.
static float VibeGainSample(uint32_t file, uint32_t frame) {
    return (float)((file << 17) | frame) / (float)(1 << 20);
}

// The code a captured stereo frame names at `gain`, or 0 for one that names
// none: silence, a faded sample, another gain, or two channels that disagree.
static uint32_t VibeGainCode(const float *frame, float gain) {
    double scaled = (double)frame[0] / gain * (1 << 20);
    uint32_t code = (uint32_t)scaled;
    return gain > 0 && scaled > 0 && (double)code == scaled && frame[1] == -frame[0] ? code : 0;
}

static uint32_t VibeGainCodeOf(uint32_t file, uint32_t frame) {
    return (file << 17) | frame;
}

@interface AudioPlayerFileGainTests : XCTestCase <AudioPlayerDelegate>
@end

@implementation AudioPlayerFileGainTests {
    NSURL *_temporary;
    AudioPlayer *_player;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableData *_capture;
    NSError *_error;
    NSURL *_files[5];
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    _events = [NSMutableArray array];
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    for (uint32_t file = 1; file <= 4; file++) {
        _files[file] = [self writeFile:file frames:kGainFrames];
    }
}

- (void)tearDown {
    [_player debugShutdown];
    _player = nil;
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}

- (NSURL *)writeFile:(uint32_t)file frames:(NSUInteger)frames {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kGainRate channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)frames];
    buffer.frameLength = (AVAudioFrameCount)frames;
    for (uint32_t frame = 0; frame < frames; frame++) {
        buffer.floatChannelData[0][frame] = VibeGainSample(file, frame);
        buffer.floatChannelData[1][frame] = -VibeGainSample(file, frame);
    }
    NSURL *url = [_temporary URLByAppendingPathComponent:[NSString stringWithFormat:@"%u-%lu.wav", file, (unsigned long)frames]];
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@", error);
    return url;
}

#pragma mark - Driving the player

- (void)settleUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
    }
    XCTAssertTrue(condition(), @"timed out; events %@; error %@", _events, _error);
}

- (NSUInteger)count:(NSString *)event {
    NSUInteger count = 0;
    for (NSDictionary *entry in _events) {
        count += [entry[@"event"] isEqual:event];
    }
    return count;
}

- (VibeVoiceSnapshot)voiceSnapshot {
    __block VibeVoiceSnapshot snapshot = {0};
    [_player runSyncOnQueue:^{
        AudioVoiceBus *bus = [self->_player valueForKey:@"voiceBus"];
        snapshot = [bus snapshotOfVoice:[[self->_player valueForKey:@"voice"] unsignedLongLongValue]];
    }];
    return snapshot;
}

- (id)onQueue:(NSString *)key {
    __block id value = nil;
    [_player runSyncOnQueue:^{
        value = [self->_player valueForKey:key];
    }];
    return value;
}

- (void)makePlayer {
    [_player debugShutdown];
    [_events removeAllObjects];
    _capture = [NSMutableData data];
    _error = nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kGainRate channels:2];
    _player = [[AudioPlayer alloc] initForManualRendering:format enableFX:NO automatic:NO delegate:self];
    [self settleUntil:^BOOL { return [self count:@"init"] == 1; }];
}

- (VibeTestTrack *)play:(NSURL *)url fileGain:(float)fileGain {
    VibeTestTrack *track = [VibeTestTrack withURL:url];
    NSUInteger started = [self count:@"start"];
    [_player requestPlay:track atPosition:0 startPaused:NO fileGain:fileGain];
    [self settleUntil:^BOOL { return [self count:@"start"] == started + 1 || self->_error; }];
    XCTAssertNil(_error);
    return track;
}

// Parked and queued on the current voice, at its gain.
- (VibeTestTrack *)queue:(NSURL *)url fileGain:(float)fileGain {
    return [self queueTrack:[VibeTestTrack withURL:url] fileGain:fileGain];
}

- (VibeTestTrack *)queueTrack:(VibeTestTrack *)track fileGain:(float)fileGain {
    [_player requestPrefetchTrack:track fileGain:fileGain];
    [self settleUntil:^BOOL { return [self onQueue:@"successorTrack"] == track; }];
    return track;
}

- (void)render:(NSUInteger)frames block:(NSUInteger)block {
    while (frames) {
        AVAudioFrameCount count = (AVAudioFrameCount)MIN(frames, block);
        NSError *error = nil;
        AVAudioPCMBuffer *buffer = [_player debugRenderFrames:count error:&error];
        XCTAssertNotNil(buffer, @"%@", error);
        VibeAppendPCM(_capture, buffer);
        frames -= count;
    }
}

- (void)render:(NSUInteger)frames {
    [self render:frames block:256];
}

// Renders until the current voice has consumed exactly `frames`.
- (void)renderVoiceTo:(uint64_t)frames {
    for (uint64_t consumed = [self voiceSnapshot].consumed; consumed < frames; consumed = [self voiceSnapshot].consumed) {
        [self render:(NSUInteger)MIN(frames - consumed, (uint64_t)256)];
    }
    XCTAssertEqual([self voiceSnapshot].consumed, frames);
}

- (NSUInteger)capturedFrames {
    return _capture.length / sizeof(float) / 2;
}

- (const float *)frame:(NSUInteger)index {
    return (const float *)_capture.bytes + index * 2;
}

// The capture index of `file`'s `frame` at `gain`, NSNotFound when it never
// played so.
- (NSUInteger)indexOfFile:(uint32_t)file frame:(uint32_t)frame gain:(float)gain {
    for (NSUInteger i = 0; i < self.capturedFrames; i++) {
        if (VibeGainCode([self frame:i], gain) == VibeGainCodeOf(file, frame)) {
            return i;
        }
    }
    return NSNotFound;
}

// Every frame from capture index `start` is `file`'s at `gain`, from `first`,
// for `count` frames; NO, with a failure, at the first that is not.
- (BOOL)assertFile:(uint32_t)file gain:(float)gain from:(uint32_t)first count:(NSUInteger)count
           atIndex:(NSUInteger)start in:(NSString *)when {
    XCTAssertLessThanOrEqual(start + count, self.capturedFrames, @"%@", when);
    for (NSUInteger i = 0; i < count; i++) {
        const float *frame = [self frame:start + i];
        float expected = gain * VibeGainSample(file, first + (uint32_t)i);
        if (frame[0] != expected || frame[1] != -expected) {
            XCTFail(@"%@: capture frame %lu is %.9g, not file %u's frame %u at gain %g (%.9g)", when,
                    (unsigned long)(start + i), frame[0], file, first + (uint32_t)i, gain, expected);
            return NO;
        }
    }
    return YES;
}

#pragma mark - The boundary frame

// The plan's proof: across a gapless splice, the frame before the boundary
// is the ending file's last at its gain, and the boundary frame is the next
// file's first at its own, wherever the boundary falls in a render: on a
// slice's edge (64 divides 48000), and inside one. currentFileGain follows.
- (void)testTheGainChangesOnTheBoundaryFrame {
    for (NSNumber *block in @[@64, @256, @509, @4096]) {
        NSString *when = [NSString stringWithFormat:@"%@-frame slices", block];
        [self makePlayer];
        [self play:_files[1] fileGain:0.5f];
        XCTAssertEqual(_player.currentFileGain, 0.5f, @"%@", when);
        VibeTestTrack *second = [self queue:_files[2] fileGain:0.25f];
        XCTAssertEqual(_player.currentFileGain, 0.5f, @"%@: the park's gain is not the current one", when);
        [self render:kGainFrames + 8192 block:block.unsignedIntegerValue];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, second, @"%@", when);
        XCTAssertEqual(_player.currentFileGain, 0.25f, @"%@", when);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", when);
        NSUInteger boundary = [self indexOfFile:2 frame:0 gain:0.25f];
        XCTAssertEqual(boundary, kGainFrames, @"%@: the splice is not gapless", when);
        XCTAssertEqual([self frame:boundary - 1][0], 0.5f * VibeGainSample(1, kGainFrames - 1), @"%@", when);
        XCTAssertEqual([self frame:boundary][0], 0.25f * VibeGainSample(2, 0), @"%@", when);
        [self assertFile:1 gain:0.5f from:kGainDeclickFrames count:kGainFrames - kGainDeclickFrames
                 atIndex:kGainDeclickFrames in:when];
        [self assertFile:2 gain:0.25f from:0 count:8192 atIndex:boundary in:when];
        XCTAssertEqualObjects(_player.debugRenderCounts[@"fileGain"], @0.25f, @"%@", when);
    }
}

// The splice is one voice, so each file's gain rides the bus, not the voice:
// three files in a row, each at its own, back to unity.
- (void)testEachSpliceOfAChainTakesItsOwnGain {
    [self makePlayer];
    [self play:_files[1] fileGain:2];
    VibeTestTrack *second = [self queue:_files[2] fileGain:0.125f];
    [self render:kGainFrames + 4096];
    [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
    XCTAssertEqual(_player.currentFileGain, 0.125f);
    VibeTestTrack *third = [self queue:_files[3] fileGain:1];
    XCTAssertNotEqualObjects(second, third);
    [self render:kGainFrames + 4096];
    [self settleUntil:^BOOL { return [self count:@"advance"] == 2; }];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
    [self assertFile:1 gain:2 from:kGainDeclickFrames count:kGainFrames - kGainDeclickFrames
             atIndex:kGainDeclickFrames in:@"first"];
    [self assertFile:2 gain:0.125f from:0 count:kGainFrames atIndex:kGainFrames in:@"second"];
    [self assertFile:3 gain:1 from:0 count:8192 atIndex:2 * kGainFrames in:@"third"];
}

#pragma mark - A re-parked successor

// Re-parked in the last moments, after the decoder has read into the old
// successor: the old one's gain never sounds, and the new one plays at its own
// from the boundary frame.
- (void)testATakenBackSuccessorNeverSoundsAtItsGain {
    for (NSNumber *milliseconds in @[@100, @12, @1]) {
        NSString *when = [NSString stringWithFormat:@"%@ ms before", milliseconds];
        [self makePlayer];
        [self play:_files[1] fileGain:0.5f];
        [self queue:_files[2] fileGain:4];
        [self renderVoiceTo:kGainFrames - (uint64_t)llround(milliseconds.doubleValue * kGainRate / 1000)];
        XCTAssertGreaterThan([self voiceSnapshot].written, kGainFrames + 4096, @"%@: the decoder is not in the old one", when);
        VibeTestTrack *next = [self queue:_files[3] fileGain:0.25f];
        [self render:(NSUInteger)(milliseconds.doubleValue * kGainRate / 1000) + 8192];
        [self assertFile:1 gain:0.5f from:kGainDeclickFrames count:kGainFrames - kGainDeclickFrames
                 atIndex:kGainDeclickFrames in:when];
        [self assertFile:3 gain:0.25f from:0 count:8192 atIndex:kGainFrames in:when];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, next, @"%@", when);
        XCTAssertEqual(_player.currentFileGain, 0.25f, @"%@", when);
    }
}

// The same track parked again at another gain is queued again at it, so its
// first frame sounds at the new gain.
- (void)testAReprefetchAtAnotherGainRequeuesTheSuccessor {
    for (NSNumber *milliseconds in @[@500, @12, @1]) {
        NSString *when = [NSString stringWithFormat:@"%@ ms before", milliseconds];
        [self makePlayer];
        [self play:_files[1] fileGain:0.5f];
        [self queue:_files[2] fileGain:0.25f];
        [self renderVoiceTo:kGainFrames - (uint64_t)llround(milliseconds.doubleValue * kGainRate / 1000)];
        VibeTestTrack *again = [VibeTestTrack withURL:_files[2]];
        [_player requestPrefetchTrack:again fileGain:2];
        [self settleUntil:^BOOL {
            return [self onQueue:@"successorTrack"] == again && [[self onQueue:@"successorFileGain"] floatValue] == 2;
        }];
        [self render:(NSUInteger)(milliseconds.doubleValue * kGainRate / 1000) + 8192];
        [self assertFile:2 gain:2 from:0 count:8192 atIndex:kGainFrames in:when];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, again, @"%@", when);
        XCTAssertEqual(_player.currentFileGain, 2.0f, @"%@", when);
    }
}

// Once the render has passed into the successor, a gain asked for it later is
// too late: it keeps the gain it sounds at, and currentFileGain says so.
- (void)testAReprefetchPastTheBoundaryKeepsTheGainItSoundsAt {
    [self makePlayer];
    [self play:_files[1] fileGain:0.5f];
    [self queue:_files[2] fileGain:0.25f];
    [self renderVoiceTo:kGainFrames - 64];
    // The output unit's callback, on this thread: no drain runs after it.
    [_player debugRenderOnCallerThread:64 + 192];
    VibeTestTrack *again = [VibeTestTrack withURL:_files[2]];
    [_player requestPrefetchTrack:again fileGain:2];
    [_player runSyncOnQueue:^{}];
    [self render:8192];
    [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
    XCTAssertEqualObjects(_player.currentTrack, again);
    XCTAssertEqual(_player.currentFileGain, 0.25f);
    // The capture misses what the callback rendered.
    [self assertFile:2 gain:0.25f from:192 count:8192 atIndex:kGainFrames - 64 in:@"past"];
}

#pragma mark - A crossfade, a seek, a pause, the volume

// Each file keeps its own gain through a crossfade, a skip's and a track
// end's. One file sounds on the left and the other on the right, so the fades
// separate, and each channel is the unity run's at its file's gain, exactly.
- (void)testACrossfadeKeepsEachFilesGain {
    NSURL *left = [self writeSide:0 file:1], *right = [self writeSide:1 file:2];
    for (NSString *edge in @[@"skip", @"track end"]) {
        NSData *runs[2];
        for (int run = 0; run < 2; run++) {
            float leftGain = run ? 0.5f : 1, rightGain = run ? 4 : 1;
            [self makePlayer];
            _player.crossfadeMilliseconds = 300;
            [self play:left fileGain:leftGain];
            if ([edge isEqual:@"skip"]) {
                [self render:20000];
                [_player requestPlay:[VibeTestTrack withURL:right] fileGain:rightGain];
                [self settleUntil:^BOOL { return [self count:@"start"] == 2; }];
            }
            else {
                [_player requestPrefetchTrack:[VibeTestTrack withURL:right] fileGain:rightGain];
                [self settleUntil:^BOOL { return [self onQueue:@"prefetchedFile"] != nil; }];
                XCTAssertNil([self onQueue:@"successorTrack"], @"a long crossfade arms no splice");
            }
            [self render:kGainFrames + 24000];
            NSString *advanced = [edge isEqual:@"skip"] ? @"start" : @"advance";
            [self settleUntil:^BOOL { return [self count:advanced] >= 1; }];
            XCTAssertEqual(_player.currentFileGain, rightGain, @"%@", edge);
            runs[run] = _capture;
        }
        XCTAssertEqual(runs[0].length, runs[1].length, @"%@", edge);
        const float *unity = runs[0].bytes, *gained = runs[1].bytes;
        NSUInteger both = 0;
        for (NSUInteger i = 0; i < runs[0].length / sizeof(float) / 2; i++) {
            both += unity[i * 2] != 0 && unity[i * 2 + 1] != 0;
            if (gained[i * 2] != unity[i * 2] * 0.5f || gained[i * 2 + 1] != unity[i * 2 + 1] * 4) {
                XCTFail(@"%@: frame %lu is (%g, %g), not (%g, %g)", edge, (unsigned long)i, gained[i * 2],
                        gained[i * 2 + 1], unity[i * 2] * 0.5f, unity[i * 2 + 1] * 4);
                break;
            }
        }
        XCTAssertGreaterThan(both, 10000u, @"%@: the files never crossfaded", edge);
    }
}

// A file on one channel, silence on the other, coded as the others are.
- (NSURL *)writeSide:(int)channel file:(uint32_t)file {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kGainRate channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)kGainFrames];
    buffer.frameLength = (AVAudioFrameCount)kGainFrames;
    for (uint32_t frame = 0; frame < kGainFrames; frame++) {
        buffer.floatChannelData[channel][frame] = VibeGainSample(file, frame);
        buffer.floatChannelData[1 - channel][frame] = 0;
    }
    NSURL *url = [_temporary URLByAppendingPathComponent:[NSString stringWithFormat:@"side-%d.wav", channel]];
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@", error);
    return url;
}

// A seek, a pause and a resume are new ramps or a new voice over the same
// file, which keeps its request's gain.
- (void)testASeekAPauseAndAResumeKeepTheGain {
    [self makePlayer];
    [self play:_files[1] fileGain:0.25f];
    [self render:8192];
    [_player seekToPosition:0.5];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    NSUInteger seeked = self.capturedFrames;
    [self render:8192];
    NSUInteger landed = [self indexOfFile:1 frame:24000 + 4096 gain:0.25f];
    XCTAssertNotEqual(landed, NSNotFound, @"the seek lost the gain");
    XCTAssertGreaterThan(landed, seeked);
    [self assertFile:1 gain:0.25f from:24000 + 4096 count:2048 atIndex:landed in:@"after the seek"];
    [_player pause];
    [self settleUntil:^BOOL { return [self count:@"pause"] == 1; }];
    [self render:2048];
    [_player resume];
    [self settleUntil:^BOOL { return [self count:@"resume"] == 1; }];
    NSUInteger resumed = self.capturedFrames;
    [self render:8192];
    uint32_t code = VibeGainCode([self frame:resumed + 4096], 0.25f);
    XCTAssertNotEqual(code, 0u, @"the resume lost the gain");
    [self assertFile:1 gain:0.25f from:code & ((1 << 17) - 1) count:2048 atIndex:resumed + 4096 in:@"after the resume"];
    XCTAssertEqual(_player.currentFileGain, 0.25f);
}

// The volume is the render's last stage and the file gain its first, so both
// apply, each unchanged: 0.5 on the fader is its cube, 0.125.
- (void)testTheVolumeStillAppliesAfterTheFileGain {
    [self makePlayer];
    _player.volume = 0.5f;
    [self play:_files[1] fileGain:2];
    [self render:8192];
    [self assertFile:1 gain:0.25f from:4096 count:4096 atIndex:4096 in:@"volume"];
    XCTAssertEqual(_player.volume, 0.5f);
}

// What a request carries is held to what the player applies, and read back so.
- (void)testAGainOutOfRangeIsHeldToWhatIsApplied {
    [self makePlayer];
    [self play:_files[1] fileGain:-1];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
    [self render:4096];
    [self assertFile:1 gain:1 from:kGainDeclickFrames count:2048 atIndex:kGainDeclickFrames in:@"negative"];
    [self play:_files[2] fileGain:1000];
    XCTAssertEqual(_player.currentFileGain, kVibeFileGainMaximum);
    [_player stop];
    [self settleUntil:^BOOL { return self->_player.isStopped && self->_player.currentTrack == nil; }];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
}

#pragma mark - The soak

// Hundreds of gapless splices over files of many lengths, some shorter than
// the ring, so the decoder reaches a file's end before the render reaches its
// start, each at a gain of its own, in slices of every size, with re-parks in
// a file's last moments. Every frame after the first declick must be the
// file's at its gain, in order, with nothing between, and the pipeline must
// never refuse a render or leave a fade behind.
- (void)testASoakOfSplicesKeepsEveryFileAtItsGain {
    const NSUInteger splices = 240;
    const NSUInteger lengths[] = {5000, 9000, 16000, 30000, 47000, 71000};
    NSArray<NSNumber *> *gains = @[@0.25f, @0.5f, @1.0f, @2.0f];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (uint32_t file = 0; file < 6; file++) {
        [urls addObject:[self writeFile:file + 1 frames:lengths[file]]];
    }
    __block uint64_t seed = 0x5eed;
    uint32_t (^next)(uint32_t) = ^uint32_t(uint32_t bound) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        return (uint32_t)(seed >> 33) % bound;
    };
    NSMutableArray<NSDictionary *> *played = [NSMutableArray array];
    NSDictionary *(^entry)(void) = ^NSDictionary *{
        uint32_t file = next(6);
        return @{@"file": @(file), @"gain": gains[next(4)], @"track": [VibeTestTrack withURL:urls[file]]};
    };
    [self makePlayer];
    NSDictionary *first = entry();
    VibeTestTrack *track = [self play:urls[[first[@"file"] intValue]] fileGain:[first[@"gain"] floatValue]];
    [played addObject:@{@"file": first[@"file"], @"gain": first[@"gain"], @"track": track}];
    NSDictionary *successor = entry();
    [self queueTrack:successor[@"track"] fileGain:[successor[@"gain"] floatValue]];
    NSUInteger reparks = 0;
    BOOL reparked = NO;
    while (played.count < splices) {
        [self render:1 + next(1024) block:4096];
        if (_player.currentTrack == successor[@"track"]) {
            [played addObject:successor];
            XCTAssertEqual(_player.currentFileGain, [successor[@"gain"] floatValue], @"splice %lu", (unsigned long)played.count);
            successor = entry();
            [self queueTrack:successor[@"track"] fileGain:[successor[@"gain"] floatValue]];
            reparked = NO;
            continue;
        }
        XCTAssertTrue(_player.currentTrack == played.lastObject[@"track"], @"splice %lu", (unsigned long)played.count);
        VibeVoiceSnapshot snapshot = [self voiceSnapshot];
        if (!reparked && snapshot.boundary != UINT64_MAX && snapshot.boundary >= snapshot.consumed
                && snapshot.boundary - snapshot.consumed < 2400 && next(3) == 0) {
            successor = entry();
            [self queueTrack:successor[@"track"] fileGain:[successor[@"gain"] floatValue]];
            reparked = YES;
            reparks++;
        }
    }
    [_player requestPrefetchTrack:nil];
    [_player runSyncOnQueue:^{}];
    for (NSUInteger rendered = 0; !_player.isStopped && rendered < 4 * kGainRate; rendered += 1024) {
        [self render:1024];
    }
    XCTAssertTrue(_player.isStopped, @"the last file never ended");
    XCTAssertGreaterThan(reparks, 20u, @"too few re-parks to soak the take-back");
    NSUInteger index = kGainDeclickFrames;
    for (NSUInteger i = 0; i < played.count; i++) {
        uint32_t file = [played[i][@"file"] unsignedIntValue];
        NSUInteger first = i == 0 ? kGainDeclickFrames : 0;
        NSString *when = [NSString stringWithFormat:@"splice %lu, file %u at %@", (unsigned long)i, file + 1, played[i][@"gain"]];
        if (![self assertFile:file + 1 gain:[played[i][@"gain"] floatValue] from:(uint32_t)first
                        count:lengths[file] - first atIndex:index in:when]) {
            return;
        }
        index += lengths[file] - first;
    }
    for (NSUInteger i = index; i < self.capturedFrames; i++) {
        XCTAssertEqual([self frame:i][0], 0.0f, @"sound after the last file at frame %lu", (unsigned long)i);
    }
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertEqualObjects(counts[@"renderRefusals"], @0);
    XCTAssertEqualObjects(counts[@"retiredFades"], @0);
    XCTAssertEqualObjects(counts[@"renderLeaveWork"], @0);
    NSLog(@"file gain soak: %lu splices, %lu re-parks, %lu frames", (unsigned long)played.count,
          (unsigned long)reparks, (unsigned long)self.capturedFrames);
}

#pragma mark - The delegate

- (void)record:(NSString *)event track:(id<VibePlayableItem>)track {
    [_events addObject:@{@"event": event, @"track": track.url.path ?: @""}];
}
- (void)audioPlayerDidInitialize:(AudioPlayer *)p { [self record:@"init" track:nil]; }
- (void)audioPlayer:(AudioPlayer *)p didStartPlaying:(id<VibePlayableItem>)t { [self record:@"start" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didFinishPlaying:(id<VibePlayableItem>)t { [self record:@"finish" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didAutoAdvanceFromTrack:(id<VibePlayableItem>)a toTrack:(id<VibePlayableItem>)b {
    [self record:@"advance" track:b];
}
- (void)audioPlayer:(AudioPlayer *)p didChangeLoadingPaused:(BOOL)paused forTrack:(id<VibePlayableItem>)t {}
- (void)audioPlayer:(AudioPlayer *)p didPausePlaying:(id<VibePlayableItem>)t { [self record:@"pause" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didResumePlaying:(id<VibePlayableItem>)t { [self record:@"resume" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didFinishSeeking:(id<VibePlayableItem>)t { [self record:@"seek" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p error:(NSError *)error { _error = error; [self record:@"error" track:nil]; }

@end
