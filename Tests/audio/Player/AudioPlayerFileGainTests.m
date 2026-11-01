//
//  AudioPlayerFileGainTests.m
//
//  The whole player on the frame-driven pump, playing each item at its file
//  gain. The gains are powers of two, so a captured sample divided by its
//  gain still names its file and frame, exactly.
//

#import "AudioPlayerCodedTestCase.h"
#import "VibeFuzzRandom.h"
#import <objc/runtime.h>

@interface AudioPlayerFileGainTests : AudioPlayerCodedTestCase
@end

@implementation AudioPlayerFileGainTests

#pragma mark - The boundary frame

// The plan's proof: across a gapless splice, the frame before the boundary
// is the ending file's last at its gain, and the boundary frame is the next
// file's first at its own, wherever the boundary falls in a render: on a
// slice's edge (64 divides 48000), and inside one. currentFileGain follows.
- (void)testTheGainChangesOnTheBoundaryFrame {
    for (NSNumber *block in @[@64, @256, @509, @4096]) {
        NSString *when = [NSString stringWithFormat:@"%@-frame slices", block];
        [self makePlayer];
        [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:0.5f]];
        XCTAssertEqual(_player.currentFileGain, 0.5f, @"%@", when);
        VibeTestTrack *second = [VibeTestTrack withURL:_files[2] fileGain:0.25f];
        [self queueTrack:second];
        XCTAssertEqual(_player.currentFileGain, 0.5f, @"%@: the park's gain is not the current one", when);
        [self render:kCodedFrames + 8192 block:block.unsignedIntegerValue];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, second, @"%@", when);
        XCTAssertEqual(_player.currentFileGain, 0.25f, @"%@", when);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", when);
        NSUInteger boundary = [self indexOfFile:2 frame:0 gain:0.25f];
        XCTAssertEqual(boundary, kCodedFrames, @"%@: the splice is not gapless", when);
        XCTAssertEqual([self frame:boundary - 1][0], 0.5f * VibeCodedSample(1, kCodedFrames - 1), @"%@", when);
        XCTAssertEqual([self frame:boundary][0], 0.25f * VibeCodedSample(2, 0), @"%@", when);
        [self assertFile:1 gain:0.5f from:kCodedDeclickFrames count:kCodedFrames - kCodedDeclickFrames
                 atIndex:kCodedDeclickFrames in:when];
        [self assertFile:2 gain:0.25f from:0 count:8192 atIndex:boundary in:when];
        XCTAssertEqualObjects(_player.debugRenderCounts[@"fileGain"], @0.25f, @"%@", when);
    }
}

#pragma mark - A successor's first bytes late

// A successor whose first frames are late leaves the render resting on the
// boundary. The advance still names it at once, as it always has, so a
// buffering notice names the right track. The next successor, named on that
// advance, waits until the render has crossed the boundary. When the frames
// come, the second file plays from its first frame at its gain, and the
// third follows at its own.
- (void)testALateSuccessorIsNamedOnTheBoundaryAndPlaysAtItsGain {
    [self makePlayer];
    [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:0.5f]];
    VibeTestTrack *second = [VibeTestTrack withURL:_files[2] fileGain:0.25f];
    [self queueTrack:second];
    __block _Atomic(BOOL) late = YES;
    AudioVoiceBus *bus = [self onQueue:@"voiceBus"];
    Method decode = class_getInstanceMethod(AudioVoiceBus.class, @selector(decodeChunkForSlot:));
    __block _Atomic(IMP) original;
    IMP held = imp_implementationWithBlock(^BOOL(id receiver, NSUInteger slot) {
        VibeVoiceSlot *s = &bus.mix->slots[slot];
        uint64_t boundary = atomic_load(&s->boundary);
        if (receiver == bus && atomic_load(&late) && boundary != UINT64_MAX && atomic_load(&s->written) >= boundary) {
            return NO; // the successor's first bytes have not arrived
        }
        return ((BOOL (*)(id, SEL, NSUInteger))atomic_load(&original))(receiver, @selector(decodeChunkForSlot:), slot);
    });
    atomic_store(&original, method_getImplementation(decode));
    method_setImplementation(decode, held);
    @try {
        [self render:kCodedFrames + 4096];
        VibeVoiceSnapshot resting = [self voiceSnapshot];
        XCTAssertEqual(resting.consumed, kCodedFrames, @"the render did not rest on the boundary");
        XCTAssertGreaterThan(resting.underrunFrames, 0u);
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, second, @"the advance waited for the late frames");
        XCTAssertEqual(_player.currentFileGain, 0.25f);
        VibeTestTrack *third = [VibeTestTrack withURL:_files[3] fileGain:2];
        [_player prefetchTrack:third];
        [self settleUntil:^BOOL { return [self onQueue:@"prefetchedFile"] != nil; }];
        [self render:1024];
        XCTAssertEqual([self voiceSnapshot].successorGain, 0.25f, @"the next successor took the boundary's gain");
        atomic_store(&late, NO);
        [self render:2 * kCodedFrames];
    } @finally {
        method_setImplementation(decode, atomic_load(&original));
        imp_removeBlock(held);
    }
    [self assertFile:1 gain:0.5f from:kCodedDeclickFrames count:kCodedFrames - kCodedDeclickFrames
             atIndex:kCodedDeclickFrames in:@"first"];
    NSUInteger second0 = [self indexOfFile:2 frame:0 gain:0.25f];
    XCTAssertNotEqual(second0, NSNotFound, @"the second file never played at its gain");
    [self assertFile:2 gain:0.25f from:0 count:kCodedFrames atIndex:second0 in:@"second"];
    [self assertFile:3 gain:2 from:0 count:4096 atIndex:second0 + kCodedFrames in:@"third"];
    [self settleUntil:^BOOL { return [self count:@"advance"] == 2; }];
    XCTAssertEqual(_player.currentFileGain, 2.0f);
}

#pragma mark - A re-parked successor

// The same track parked again at another gain moves the queued successor's
// gain in place, so its first frame sounds at the new gain, with no frame
// dropped or re-voiced.
- (void)testAReprefetchAtAnotherGainMovesTheSuccessorsGain {
    for (NSNumber *milliseconds in @[@500, @12, @1]) {
        NSString *when = [NSString stringWithFormat:@"%@ ms before", milliseconds];
        [self makePlayer];
        [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:0.5f]];
        [self queueTrack:[VibeTestTrack withURL:_files[2] fileGain:0.25f]];
        [self renderVoiceTo:kCodedFrames - (uint64_t)llround(milliseconds.doubleValue * kCodedRate / 1000)];
        VibeTestTrack *again = [VibeTestTrack withURL:_files[2] fileGain:2];
        [self queueTrack:again];
        [self render:(NSUInteger)(milliseconds.doubleValue * kCodedRate / 1000) + 8192];
        [self assertFile:1 gain:0.5f from:kCodedDeclickFrames count:kCodedFrames - kCodedDeclickFrames
                 atIndex:kCodedDeclickFrames in:when];
        [self assertFile:2 gain:2 from:0 count:8192 atIndex:kCodedFrames in:when];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, again, @"%@", when);
        XCTAssertEqual(_player.currentFileGain, 2.0f, @"%@", when);
    }
}

// Once the render has passed into the successor, a gain asked for it later is
// too late: it keeps the gain it sounds at, and currentFileGain says so.
- (void)testAReprefetchPastTheBoundaryKeepsTheGainItSoundsAt {
    [self makePlayer];
    [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:0.5f]];
    [self queueTrack:[VibeTestTrack withURL:_files[2] fileGain:0.25f]];
    [self renderVoiceTo:kCodedFrames - 64];
    // The output unit's callback, on this thread: no drain runs after it.
    [_player debugRenderOnCallerThread:64 + 192];
    VibeTestTrack *again = [VibeTestTrack withURL:_files[2] fileGain:2];
    [_player prefetchTrack:again];
    [_player runSyncOnQueue:^{}];
    [self render:8192];
    [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
    XCTAssertEqualObjects(_player.currentTrack, again);
    XCTAssertEqual(_player.currentFileGain, 0.25f);
    // The capture misses what the callback rendered.
    [self assertFile:2 gain:0.25f from:192 count:8192 atIndex:kCodedFrames - 64 in:@"past"];
}

#pragma mark - A crossfade, a seek, a pause, the volume

// Each file keeps its own gain through a crossfade, a skip's and a track
// end's. One file sounds on the left and the other on the right, so the fades
// separate, and each channel is the unity run's at its file's gain, within a
// rounding of the faded frames.
- (void)testACrossfadeKeepsEachFilesGain {
    NSURL *left = [self writeSide:0 file:1], *right = [self writeSide:1 file:2];
    for (NSString *edge in @[@"skip", @"track end"]) {
        NSData *runs[2];
        for (int run = 0; run < 2; run++) {
            float leftGain = run ? 0.5f : 1, rightGain = run ? 4 : 1;
            [self makePlayer];
            _player.crossfadeMilliseconds = 300;
            [self playTrack:[VibeTestTrack withURL:left fileGain:leftGain]];
            if ([edge isEqual:@"skip"]) {
                [self render:20000];
                [_player play:[VibeTestTrack withURL:right fileGain:rightGain]];
                [self settleUntil:^BOOL { return [self count:@"start"] == 2; }];
            }
            else {
                [_player prefetchTrack:[VibeTestTrack withURL:right fileGain:rightGain]];
                [self settleUntil:^BOOL { return [self onQueue:@"prefetchedFile"] != nil; }];
                XCTAssertNil([self onQueue:@"successorTrack"], @"a long crossfade arms no splice");
            }
            [self render:kCodedFrames + 24000];
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
            float l = unity[i * 2] * 0.5f, r = unity[i * 2 + 1] * 4;
            if (fabsf(gained[i * 2] - l) > fabsf(l) * 2 * FLT_EPSILON || fabsf(gained[i * 2 + 1] - r) > fabsf(r) * 2 * FLT_EPSILON) {
                XCTFail(@"%@: frame %lu is (%.9g, %.9g), not (%.9g, %.9g)", edge, (unsigned long)i, gained[i * 2],
                        gained[i * 2 + 1], l, r);
                break;
            }
        }
        XCTAssertGreaterThan(both, 10000u, @"%@: the files never crossfaded", edge);
    }
}

// A file on one channel, silence on the other, coded as the others are.
- (NSURL *)writeSide:(int)channel file:(uint32_t)file {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kCodedRate channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)kCodedFrames];
    buffer.frameLength = (AVAudioFrameCount)kCodedFrames;
    for (uint32_t frame = 0; frame < kCodedFrames; frame++) {
        buffer.floatChannelData[channel][frame] = VibeCodedSample(file, frame);
        buffer.floatChannelData[1 - channel][frame] = 0;
    }
    NSURL *url = [_temporary URLByAppendingPathComponent:[NSString stringWithFormat:@"side-%d.wav", channel]];
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@", error);
    return url;
}

// A seek, a pause and a resume are new ramps or a new voice over the same
// file, which keeps its item's gain.
- (void)testASeekAPauseAndAResumeKeepTheGain {
    [self makePlayer];
    [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:0.25f]];
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
    uint32_t code = VibeCodedCode([self frame:resumed + 4096], 0.25f);
    XCTAssertNotEqual(code, 0u, @"the resume lost the gain");
    [self assertFile:1 gain:0.25f from:VibeCodedFrame(code) count:2048 atIndex:resumed + 4096 in:@"after the resume"];
    XCTAssertEqual(_player.currentFileGain, 0.25f);
}

// The volume is the render's last stage and the file gain its first, so both
// apply, each unchanged: 0.5 on the fader is its cube, 0.125.
- (void)testTheVolumeStillAppliesAfterTheFileGain {
    [self makePlayer];
    _player.volume = 0.5f;
    [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:2]];
    [self render:8192];
    [self assertFile:1 gain:0.25f from:4096 count:4096 atIndex:4096 in:@"volume"];
    XCTAssertEqual(_player.volume, 0.5f);
}

// What an item carries is held to what the player applies, and read back so.
- (void)testAGainOutOfRangeIsHeldToWhatIsApplied {
    [self makePlayer];
    [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:-1]];
    XCTAssertEqual(_player.currentFileGain, 0.0f);
    [self playTrack:[VibeTestTrack withURL:_files[2] fileGain:NAN]];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
    [self playTrack:[VibeTestTrack withURL:_files[3] fileGain:1e6f]];
    XCTAssertEqual(_player.currentFileGain, kVibeFileGainMaximum);
    [_player stop];
    [self settleUntil:^BOOL { return self->_player.isStopped; }];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
}

#pragma mark - The soak

// Hundreds of gapless splices over files of many lengths, some shorter than
// the ring, so the decoder reaches a file's end before the render reaches its
// start, each at a gain of its own, in slices of every size, with re-parks in
// a file's last moments. Every frame after the first declick must be the
// file's at its gain, in order, with nothing between, and the pipeline must
// never refuse a render or leave a fade behind. VIBE_FUZZ_SEED replays a run.
- (void)testASoakOfSplicesKeepsEveryFileAtItsGain {
    const NSUInteger splices = 240;
    const NSUInteger lengths[] = {5000, 9000, 16000, 30000, 47000, 71000};
    NSArray<NSNumber *> *gains = @[@0.25f, @0.5f, @1.0f, @2.0f];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (uint32_t file = 0; file < 6; file++) {
        [urls addObject:[self writeFile:file + 1 frames:lengths[file]]];
    }
    uint64_t seed = VibeFuzzBaseSeed(0x5eed);
    __block VibeFuzzRandom random = {seed};
    NSMutableArray<VibeTestTrack *> *played = [NSMutableArray array];
    VibeTestTrack *(^entry)(void) = ^VibeTestTrack *{
        NSUInteger file = VibeFuzzBelow(&random, 6);
        return [VibeTestTrack withURL:urls[file] fileGain:gains[VibeFuzzBelow(&random, 4)].floatValue];
    };
    [self makePlayer];
    VibeTestTrack *first = entry();
    [self playTrack:first];
    [played addObject:first];
    VibeTestTrack *successor = entry();
    [self queueTrack:successor];
    NSUInteger reparks = 0;
    BOOL reparked = NO;
    while (played.count < splices) {
        [self render:1 + VibeFuzzBelow(&random, 1024) block:4096];
        if (_player.currentTrack == successor) {
            [played addObject:successor];
            XCTAssertEqual(_player.currentFileGain, successor.fileGain, @"seed %llu, splice %lu", seed,
                           (unsigned long)played.count);
            successor = entry();
            [self queueTrack:successor];
            reparked = NO;
            continue;
        }
        XCTAssertTrue(_player.currentTrack == played.lastObject, @"seed %llu, splice %lu", seed, (unsigned long)played.count);
        VibeVoiceSnapshot snapshot = [self voiceSnapshot];
        if (!reparked && snapshot.boundary != UINT64_MAX && snapshot.boundary >= snapshot.consumed
                && snapshot.boundary - snapshot.consumed < 2400 && VibeFuzzBelow(&random, 3) == 0) {
            successor = entry();
            [self queueTrack:successor];
            reparked = YES;
            reparks++;
        }
    }
    [_player prefetchTrack:nil];
    [_player runSyncOnQueue:^{}];
    for (NSUInteger rendered = 0; !_player.isStopped && rendered < 4 * kCodedRate; rendered += 1024) {
        [self render:1024];
    }
    XCTAssertTrue(_player.isStopped, @"seed %llu: the last file never ended", seed);
    XCTAssertGreaterThan(reparks, 20u, @"seed %llu: too few re-parks to soak the take-back", seed);
    NSUInteger index = kCodedDeclickFrames;
    for (NSUInteger i = 0; i < played.count; i++) {
        NSUInteger file = [urls indexOfObject:played[i].url];
        NSUInteger start = i == 0 ? kCodedDeclickFrames : 0;
        NSString *when = [NSString stringWithFormat:@"seed %llu, splice %lu, file %lu at %g", seed, (unsigned long)i,
                          (unsigned long)file + 1, played[i].fileGain];
        if (![self assertFile:(uint32_t)file + 1 gain:played[i].fileGain from:(uint32_t)start
                        count:lengths[file] - start atIndex:index in:when]) {
            return;
        }
        index += lengths[file] - start;
    }
    for (NSUInteger i = index; i < self.capturedFrames; i++) {
        XCTAssertEqual([self frame:i][0], 0.0f, @"seed %llu: sound after the last file at frame %lu", seed, (unsigned long)i);
    }
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertEqualObjects(counts[@"renderRefusals"], @0);
    XCTAssertEqualObjects(counts[@"retiredFades"], @0);
    XCTAssertEqualObjects(counts[@"renderLeaveWork"], @0);
    NSLog(@"file gain soak: seed %llu, %lu splices, %lu re-parks, %lu frames", seed, (unsigned long)played.count,
          (unsigned long)reparks, (unsigned long)self.capturedFrames);
}

@end
