//
//  AudioPlayerCodedTestCase.m
//

#import "AudioPlayerCodedTestCase.h"

@implementation AudioPlayerCodedTestCase

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    _events = [NSMutableArray array];
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    for (uint32_t file = 1; file <= 4; file++) {
        _files[file] = [self writeFile:file frames:kCodedFrames];
    }
}

- (void)tearDown {
    [_player debugShutdown];
    _player = nil;
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}

- (NSURL *)writeFile:(uint32_t)file frames:(NSUInteger)frames {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kCodedRate channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)frames];
    buffer.frameLength = (AVAudioFrameCount)frames;
    for (uint32_t frame = 0; frame < frames; frame++) {
        buffer.floatChannelData[0][frame] = VibeCodedSample(file, frame);
        buffer.floatChannelData[1][frame] = -VibeCodedSample(file, frame);
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
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kCodedRate channels:2];
    _player = [[AudioPlayer alloc] initForManualRendering:format enableFX:NO automatic:NO delegate:self];
    [self settleUntil:^BOOL { return [self count:@"init"] == 1; }];
}

- (void)playTrack:(VibeTestTrack *)track {
    NSUInteger started = [self count:@"start"];
    [_player play:track atPosition:0 startPaused:NO];
    [self settleUntil:^BOOL { return [self count:@"start"] == started + 1 || self->_error; }];
    XCTAssertNil(_error);
}

- (void)queueTrack:(VibeTestTrack *)track {
    [_player prefetchTrack:track];
    [self settleUntil:^BOOL { return [self onQueue:@"successorTrack"] == track; }];
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

- (void)renderVoiceTo:(uint64_t)frames {
    for (uint64_t consumed = [self voiceSnapshot].consumed; consumed < frames; consumed = [self voiceSnapshot].consumed) {
        [self render:(NSUInteger)MIN(frames - consumed, (uint64_t)256)];
    }
    XCTAssertEqual([self voiceSnapshot].consumed, frames);
}

#pragma mark - Reading the capture

- (NSUInteger)capturedFrames {
    return _capture.length / sizeof(float) / 2;
}

- (const float *)frame:(NSUInteger)index {
    return (const float *)_capture.bytes + index * 2;
}

- (NSUInteger)indexOfFile:(uint32_t)file frame:(uint32_t)frame gain:(float)gain {
    for (NSUInteger i = 0; i < self.capturedFrames; i++) {
        if (VibeCodedCode([self frame:i], gain) == VibeCodedCodeOf(file, frame)) {
            return i;
        }
    }
    return NSNotFound;
}

- (BOOL)assertFile:(uint32_t)file gain:(float)gain from:(uint32_t)first count:(NSUInteger)count
           atIndex:(NSUInteger)start in:(NSString *)when {
    XCTAssertLessThanOrEqual(start + count, self.capturedFrames, @"%@", when);
    for (NSUInteger i = 0; i < count; i++) {
        const float *frame = [self frame:start + i];
        float expected = gain * VibeCodedSample(file, first + (uint32_t)i);
        if (frame[0] != expected || frame[1] != -expected) {
            XCTFail(@"%@: capture frame %lu is %.9g, not file %u's frame %u at gain %g (%.9g)", when,
                    (unsigned long)(start + i), frame[0], file, first + (uint32_t)i, gain, expected);
            return NO;
        }
    }
    return YES;
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
