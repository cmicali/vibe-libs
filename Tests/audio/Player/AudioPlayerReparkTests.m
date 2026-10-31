//
//  AudioPlayerReparkTests.m
//
//  The whole player on the frame-driven pump, re-parking a gapless successor
//  in a track's last moments, after the decoder has run into the old one.
//  Every sample of every fixture names its file and its frame, so the
//  capture shows exactly what followed the boundary.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioPlayer+Debug.h"
#import "AudioPlayerInternal.h"
#import "AudioReferenceFixtures.h"
#import "AudioVoiceBusInternal.h"
#import "VibeTestTrack.h"

static const double kReparkRate = 48000;
static const NSUInteger kReparkFrames = 48000; // each file, 1 s: the ring holds more
static const uint32_t kReparkBlock = 256;

// A sample's code: its file in the bits above 17, its frame below. Exact in
// float32, and negated on the right channel.
static float VibeReparkSample(uint32_t file, uint32_t frame) {
    return (float)((file << 17) | frame) / (float)(1 << 20);
}

// The file and frame a captured stereo frame names, or 0 for one that names
// none: silence, a faded sample, or two channels that disagree.
static uint32_t VibeReparkCode(const float *frame) {
    double scaled = (double)frame[0] * (1 << 20);
    uint32_t code = (uint32_t)scaled;
    return scaled > 0 && (double)code == scaled && frame[1] == -frame[0] ? code : 0;
}

static uint32_t VibeReparkFile(uint32_t code) {
    return code >> 17;
}

static uint32_t VibeReparkFrame(uint32_t code) {
    return code & ((1 << 17) - 1);
}

@interface AudioPlayerReparkTests : XCTestCase <AudioPlayerDelegate>
@end

@implementation AudioPlayerReparkTests {
    NSURL *_temporary;
    AudioPlayer *_player;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableData *_capture;
    NSError *_error;
    NSURL *_files[4]; // 1 ends, 2 is the old successor, 3 the new one
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    _events = [NSMutableArray array];
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kReparkRate channels:2];
    for (uint32_t file = 1; file <= 3; file++) {
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:kReparkFrames];
        buffer.frameLength = kReparkFrames;
        for (uint32_t frame = 0; frame < kReparkFrames; frame++) {
            buffer.floatChannelData[0][frame] = VibeReparkSample(file, frame);
            buffer.floatChannelData[1][frame] = -VibeReparkSample(file, frame);
        }
        _files[file] = [_temporary URLByAppendingPathComponent:[NSString stringWithFormat:@"%u.wav", file]];
        NSError *error = nil;
        XCTAssertNotNil(VibeWriteFixture(_files[file], buffer, &error), @"%@", error);
    }
}

- (void)tearDown {
    [_player debugShutdown];
    _player = nil;
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
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

// The first file playing from its start, the second parked and queued on its
// voice, and the decoder already reading the second.
- (VibeTestTrack *)playFirstWithSuccessor:(VibeTestTrack *)successor {
    [_player debugShutdown];
    [_events removeAllObjects];
    _capture = [NSMutableData data];
    _error = nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kReparkRate channels:2];
    _player = [[AudioPlayer alloc] initForManualRendering:format enableFX:NO automatic:NO delegate:self];
    [self settleUntil:^BOOL { return [self count:@"init"] == 1; }];
    VibeTestTrack *first = [VibeTestTrack withURL:_files[1]];
    [_player play:first atPosition:0 startPaused:NO];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1 || self->_error; }];
    XCTAssertNil(_error);
    [_player prefetchTrack:successor];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    return first;
}

- (void)render:(NSUInteger)frames {
    while (frames) {
        AVAudioFrameCount count = (AVAudioFrameCount)MIN(frames, (NSUInteger)kReparkBlock);
        NSError *error = nil;
        AVAudioPCMBuffer *buffer = [_player debugRenderFrames:count error:&error];
        XCTAssertNotNil(buffer, @"%@", error);
        VibeAppendPCM(_capture, buffer);
        frames -= count;
    }
}

// Renders until the current voice has consumed exactly `frames`.
- (void)renderVoiceTo:(uint64_t)frames {
    for (uint64_t consumed = [self voiceSnapshot].consumed; consumed < frames; consumed = [self voiceSnapshot].consumed) {
        [self render:(NSUInteger)MIN(frames - consumed, (uint64_t)kReparkBlock)];
    }
    XCTAssertEqual([self voiceSnapshot].consumed, frames);
}

- (void)reparkAt:(NSString *)when to:(nullable VibeTestTrack *)track {
    VibeVoiceSnapshot snapshot = [self voiceSnapshot];
    XCTAssertEqual(snapshot.boundary, (uint64_t)kReparkFrames, @"%@", when);
    XCTAssertGreaterThan(snapshot.written, (uint64_t)kReparkFrames + kDecodeChunkFrames,
                         @"%@: the decoder has not run into the old successor", when);
    [_player prefetchTrack:track];
    [_player runSyncOnQueue:^{}];
    if (track) {
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    }
}

// Where the first file's last frame was rendered, after every frame of it
// before that, back to the capture's first exact one.
- (NSUInteger)assertTheFirstFileEndsIn:(NSString *)when {
    const float *p = _capture.bytes;
    NSUInteger frames = _capture.length / sizeof(float) / 2, last = NSNotFound;
    for (NSUInteger i = 0; i < frames; i++) {
        uint32_t code = VibeReparkCode(p + i * 2);
        if (VibeReparkFile(code) == 1 && VibeReparkFrame(code) == kReparkFrames - 1) {
            last = i;
        }
    }
    XCTAssertNotEqual(last, NSNotFound, @"%@: the first file's last frame never played", when);
    for (NSUInteger i = last - 4096; i <= last; i++) {
        uint32_t code = VibeReparkCode(p + i * 2);
        XCTAssertEqual(code, (1u << 17) | (uint32_t)(kReparkFrames - 1 - (last - i)), @"%@: frame %lu", when, (unsigned long)i);
    }
    return last;
}

// Every frame after `start` is `file`'s, from its first, with nothing between.
- (void)assertFile:(uint32_t)file followsFrame:(NSUInteger)start in:(NSString *)when {
    const float *p = _capture.bytes;
    NSUInteger frames = _capture.length / sizeof(float) / 2;
    XCTAssertGreaterThan(frames, start + 4096, @"%@", when);
    for (NSUInteger i = start + 1; i < frames; i++) {
        uint32_t code = VibeReparkCode(p + i * 2);
        if (code != ((file << 17) | (uint32_t)(i - start - 1))) {
            XCTFail(@"%@: frame %lu after the boundary is file %u's frame %u, not file %u's frame %lu", when,
                    (unsigned long)(i - start - 1), VibeReparkFile(code), VibeReparkFrame(code), file,
                    (unsigned long)(i - start - 1));
            return;
        }
    }
}

#pragma mark - Re-parking

// The edit lands before the render reaches the boundary, anywhere in the
// read-ahead window: the old successor's frames are dropped, and the first
// file's last frame is followed by the new successor's first.
- (void)testAReparkBeforeTheBoundaryContinuesIntoTheNewSuccessor {
    for (NSNumber *milliseconds in @[@900, @500, @250, @100, @50, @25, @12, @6, @1]) {
        NSString *when = [NSString stringWithFormat:@"%@ ms before", milliseconds];
        VibeTestTrack *old = [VibeTestTrack withURL:_files[2]], *next = [VibeTestTrack withURL:_files[3]];
        [self playFirstWithSuccessor:old];
        [self renderVoiceTo:kReparkFrames - (uint64_t)llround(milliseconds.doubleValue * kReparkRate / 1000)];
        [self reparkAt:when to:next];
        [self render:(NSUInteger)(milliseconds.doubleValue * kReparkRate / 1000) + 8192];
        [self assertFile:3 followsFrame:[self assertTheFirstFileEndsIn:when] in:when];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_events.lastObject[@"track"], next.url.path, @"%@", when);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", when);
        XCTAssertEqual([self count:@"start"], 1u, @"%@", when);
        XCTAssertEqualObjects(_player.currentTrack, next, @"%@", when);
    }
}

// Parked again with nothing, the first file plays to its last frame and
// finishes, and none of the old successor sounds.
- (void)testAReparkToNothingBeforeTheBoundaryEndsAtTheFile {
    for (NSNumber *milliseconds in @[@50, @12, @1]) {
        NSString *when = [NSString stringWithFormat:@"%@ ms before", milliseconds];
        VibeTestTrack *first = [self playFirstWithSuccessor:[VibeTestTrack withURL:_files[2]]];
        [self renderVoiceTo:kReparkFrames - (uint64_t)llround(milliseconds.doubleValue * kReparkRate / 1000)];
        [self reparkAt:when to:nil];
        [self render:(NSUInteger)(milliseconds.doubleValue * kReparkRate / 1000) + 8192];
        NSUInteger last = [self assertTheFirstFileEndsIn:when];
        const float *p = _capture.bytes;
        for (NSUInteger i = (last + 1) * 2; i < _capture.length / sizeof(float); i++) {
            XCTAssertEqual(p[i], 0.0f, @"%@: sound after the end at sample %lu", when, (unsigned long)i);
        }
        [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
        XCTAssertEqualObjects(_events.lastObject[@"track"], first.url.path, @"%@", when);
        XCTAssertEqual([self count:@"advance"], 0u, @"%@", when);
    }
}

// The edit lands once the render has crossed the boundary: today's behavior.
// The old successor was promoted and plays on, and the new one is parked to
// follow it.
- (void)testAReparkAfterTheBoundaryLeavesThePromotedSuccessorPlaying {
    for (NSNumber *milliseconds in @[@1, @12, @50]) {
        NSString *when = [NSString stringWithFormat:@"%@ ms after", milliseconds];
        VibeTestTrack *old = [VibeTestTrack withURL:_files[2]], *next = [VibeTestTrack withURL:_files[3]];
        [self playFirstWithSuccessor:old];
        [self renderVoiceTo:kReparkFrames + (uint64_t)llround(milliseconds.doubleValue * kReparkRate / 1000)];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, old, @"%@", when);
        [_player prefetchTrack:next];
        [_player runSyncOnQueue:^{}];
        [self render:8192];
        [self assertFile:2 followsFrame:[self assertTheFirstFileEndsIn:when] in:when];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        XCTAssertEqualObjects(_player.currentTrack, old, @"%@", when);
        XCTAssertEqual([self count:@"advance"], 1u, @"%@", when);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", when);
    }
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
