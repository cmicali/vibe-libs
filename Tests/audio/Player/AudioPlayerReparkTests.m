//
//  AudioPlayerReparkTests.m
//
//  The whole player on the frame-driven pump, re-parking a gapless successor
//  in a track's last moments, after the decoder has run into the old one.
//  Every sample of every fixture names its file and its frame, so the
//  capture shows exactly what followed the boundary.
//

#import "AudioPlayerCodedTestCase.h"

@interface AudioPlayerReparkTests : AudioPlayerCodedTestCase
@end

@implementation AudioPlayerReparkTests

// The first file playing from its start, the second parked and queued on its
// voice, and the decoder already reading the second.
- (VibeTestTrack *)playFirstWithSuccessor:(VibeTestTrack *)successor {
    [self makePlayer];
    VibeTestTrack *first = [VibeTestTrack withURL:_files[1]];
    [self playTrack:first];
    [_player prefetchTrack:successor];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    return first;
}

- (void)reparkAt:(NSString *)when to:(nullable VibeTestTrack *)track {
    VibeVoiceSnapshot snapshot = [self voiceSnapshot];
    XCTAssertEqual(snapshot.boundary, (uint64_t)kCodedFrames, @"%@", when);
    XCTAssertGreaterThan(snapshot.written, (uint64_t)kCodedFrames + kDecodeChunkFrames,
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
    NSUInteger last = NSNotFound;
    for (NSUInteger i = 0; i < self.capturedFrames; i++) {
        uint32_t code = VibeCodedCode([self frame:i], 1);
        if (VibeCodedFile(code) == 1 && VibeCodedFrame(code) == kCodedFrames - 1) {
            last = i;
        }
    }
    XCTAssertNotEqual(last, NSNotFound, @"%@: the first file's last frame never played", when);
    [self assertFile:1 gain:1 from:(uint32_t)(kCodedFrames - 1 - 4096) count:4097 atIndex:last - 4096 in:when];
    return last;
}

// Every frame after `start` is `file`'s, from `first` on, with nothing between.
- (void)assertFile:(uint32_t)file from:(uint32_t)first followsFrame:(NSUInteger)start in:(NSString *)when {
    XCTAssertGreaterThan(self.capturedFrames, start + 4096, @"%@", when);
    [self assertFile:file gain:1 from:first count:self.capturedFrames - start - 1 atIndex:start + 1 in:when];
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
        [self renderVoiceTo:kCodedFrames - (uint64_t)llround(milliseconds.doubleValue * kCodedRate / 1000)];
        [self reparkAt:when to:next];
        [self render:(NSUInteger)(milliseconds.doubleValue * kCodedRate / 1000) + 8192];
        [self assertFile:3 from:0 followsFrame:[self assertTheFirstFileEndsIn:when] in:when];
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
        [self renderVoiceTo:kCodedFrames - (uint64_t)llround(milliseconds.doubleValue * kCodedRate / 1000)];
        [self reparkAt:when to:nil];
        [self render:(NSUInteger)(milliseconds.doubleValue * kCodedRate / 1000) + 8192];
        NSUInteger last = [self assertTheFirstFileEndsIn:when];
        for (NSUInteger i = last + 1; i < self.capturedFrames; i++) {
            XCTAssertTrue([self frame:i][0] == 0 && [self frame:i][1] == 0, @"%@: sound after the end at frame %lu",
                          when, (unsigned long)i);
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
        [self renderVoiceTo:kCodedFrames + (uint64_t)llround(milliseconds.doubleValue * kCodedRate / 1000)];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, old, @"%@", when);
        [_player prefetchTrack:next];
        [_player runSyncOnQueue:^{}];
        [self render:8192];
        [self assertFile:2 from:0 followsFrame:[self assertTheFirstFileEndsIn:when] in:when];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        XCTAssertEqualObjects(_player.currentTrack, old, @"%@", when);
        XCTAssertEqual([self count:@"advance"], 1u, @"%@", when);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", when);
    }
}

// The edit lands in the window between the render that crosses the boundary
// and the drain that reports it, as on hardware, where the IO thread renders
// while the player queue is busy. The old successor is already sounding, so
// the splice stands, as if the edit had come after the drain: it is promoted
// and plays on, and the new successor is queued to follow it.
- (void)testAReparkAfterTheRenderCrossedButBeforeTheDrainLeavesTheSpliceStanding {
    for (NSNumber *crossed in @[@1, @192, @480]) {
        NSString *when = [NSString stringWithFormat:@"%@ frames past, unreported", crossed];
        VibeTestTrack *old = [VibeTestTrack withURL:_files[2]], *next = [VibeTestTrack withURL:_files[3]];
        VibeTestTrack *first = [self playFirstWithSuccessor:old];
        [self renderVoiceTo:kCodedFrames - 64];
        NSUInteger before = self.capturedFrames;
        // The output unit's callback, on this thread: no drain runs after it.
        [_player debugRenderOnCallerThread:64 + crossed.unsignedIntegerValue];
        VibeVoiceSnapshot snapshot = [self voiceSnapshot];
        XCTAssertEqual(snapshot.consumed, kCodedFrames + crossed.unsignedLongLongValue, @"%@", when);
        XCTAssertEqualObjects(_player.currentTrack, first, @"%@: the boundary was reported", when);
        [_player prefetchTrack:next];
        [_player runSyncOnQueue:^{}];
        [self render:8192];
        // The capture misses what the callback rendered: the first file's
        // last 64 frames and the old successor's first `crossed`.
        [self assertFile:2 from:crossed.unsignedIntValue followsFrame:before - 1 in:when];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 1; }];
        XCTAssertEqualObjects(_player.currentTrack, old, @"%@", when);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", when);
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self render:kCodedFrames];
        [self settleUntil:^BOOL { return [self count:@"advance"] == 2; }];
        XCTAssertEqualObjects(_player.currentTrack, next, @"%@: the new successor did not follow", when);
    }
}

@end
