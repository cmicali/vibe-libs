//
//  AudioPlayerRenderRequestTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import <objc/runtime.h>

// Request identifiers: every callback names the play it answers. The delegate
// implements the identifier forms, so the player sends only those.
@interface AudioPlayerRenderRequestTests : AudioPlayerRenderTests {
    NSMutableArray<NSError *> *_errors;
    NSMutableDictionary<NSNumber *, VibeTestTrack *> *_prefetches; // by the identifier each returned
}
@end
@implementation AudioPlayerRenderRequestTests

- (void)setUp {
    [super setUp];
    _errors = [NSMutableArray array];
    _prefetches = [NSMutableDictionary dictionary];
}

- (void)recordEvent:(NSString *)event track:(VibeTestTrack *)track request:(uint64_t)request {
    [_events addObject:@{@"event": event, @"item": track ?: NSNull.null, @"request": @(request)}];
}

- (NSArray<NSDictionary *> *)eventsNamed:(NSString *)name {
    return [_events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"event == %@", name]];
}

- (NSArray<NSDictionary *> *)eventsForRequest:(uint64_t)request {
    return [_events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"request == %llu OR finished == %llu OR started == %llu",
                                                 request, request, request]];
}

- (void)prefetchNextOf:(AudioPlayer *)player {
    if (_chain && _nextPrefetch < _chain.count) {
        VibeTestTrack *track = _chain[_nextPrefetch];
        _prefetches[@([player requestPrefetchTrack:track])] = track;
    }
}

- (void)audioPlayer:(AudioPlayer *)p didBeginLoading:(VibeTestTrack *)t requestIdentifier:(uint64_t)request
openRequestIdentifier:(uint64_t)open {
    XCTAssertNotEqual(open, 0u);
    [self recordEvent:@"loading" track:t request:request];
}
- (void)audioPlayer:(AudioPlayer *)p didStartPlaying:(VibeTestTrack *)t requestIdentifier:(uint64_t)request {
    [self recordEvent:@"start" track:t request:request];
    [self prefetchNextOf:p];
}
- (void)audioPlayer:(AudioPlayer *)p didFinishPlaying:(VibeTestTrack *)t requestIdentifier:(uint64_t)request {
    [self recordEvent:@"finish" track:t request:request];
}
- (void)audioPlayer:(AudioPlayer *)p didAutoAdvanceFromTrack:(VibeTestTrack *)a finishedRequestIdentifier:(uint64_t)finished
            toTrack:(VibeTestTrack *)b startedRequestIdentifier:(uint64_t)started {
    [_events addObject:@{@"event": @"advance", @"from": a, @"to": b, @"finished": @(finished), @"started": @(started)}];
    _nextPrefetch++;
    [self prefetchNextOf:p];
}
- (void)audioPlayer:(AudioPlayer *)p error:(NSError *)error {
    [_errors addObject:error];
    NSNumber *request = error.userInfo[kVibeAudioErrorRequestIdentifierKey];
    [self recordEvent:@"error" track:error.userInfo[kVibeAudioErrorTrackKey] request:request.unsignedLongLongValue];
    _playError = error;
}
// The plain forms must never arrive while the identifier forms exist.
- (void)audioPlayer:(AudioPlayer *)p didStartPlaying:(VibeTestTrack *)t { XCTFail(@"plain didStartPlaying:"); }
- (void)audioPlayer:(AudioPlayer *)p didFinishPlaying:(VibeTestTrack *)t { XCTFail(@"plain didFinishPlaying:"); }
- (void)audioPlayer:(AudioPlayer *)p didAutoAdvanceFromTrack:(VibeTestTrack *)a toTrack:(VibeTestTrack *)b {
    XCTFail(@"plain didAutoAdvanceFromTrack:");
}
- (void)audioPlayer:(AudioPlayer *)p didBeginLoading:(VibeTestTrack *)t openRequestIdentifier:(uint64_t)i {
    XCTFail(@"plain didBeginLoading:");
}

// Two plays and a Pause before the queue takes any: the second play lands
// parked under its own identifier, and the first is never heard from. Then a
// Pause on a stopped player, with a play behind it, answers NotPlaying and
// names only the plays before it.
- (void)testAQuickPlayPlayPauseNamesOnlyTheNewestPlay {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    VibeTestTrack *first = [VibeTestTrack withURL:[self fixture:@"noise-48000-24-2.wav"]];
    VibeTestTrack *second = [VibeTestTrack withURL:[self fixture:@"noise-48000-16-2.wav"]];
    __block uint64_t a = 0, b = 0;
    [self withPlayerQueueHeld:^{
        a = [self->_player requestPlay:first];
        b = [self->_player requestPlay:second];
        [self->_player playPause];
    }];
    XCTAssertNotEqual(a, 0u);
    XCTAssertGreaterThan(b, a);
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    [self render:4800];
    NSDictionary *start = [self eventsNamed:@"start"].firstObject;
    XCTAssertEqualObjects(start[@"request"], @(b));
    XCTAssertEqual(start[@"item"], second);
    XCTAssertTrue(_player.isPaused, @"the Pause did not reach the play submitted before it");
    XCTAssertEqual([self eventsForRequest:a].count, 0u, @"the superseded play was answered: %@", _events);

    [_player stop];
    __block uint64_t c = 0;
    [self withPlayerQueueHeld:^{
        [self->_player playPause];
        c = [self->_player requestPlay:first];
    }];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2; }];
    XCTAssertEqual(_errors.count, 1u, @"%@", _errors);
    NSError *notPlaying = _errors.firstObject;
    XCTAssertEqual(notPlaying.code, VibeAudioErrorNotPlaying);
    XCTAssertEqual(VibeAudioErrorKindOf(notPlaying), VibeAudioErrorKindNotPlaying);
    XCTAssertEqualObjects(notPlaying.userInfo[kVibeAudioErrorPrecedingRequestIdentifierKey], @(b));
    XCTAssertNil(notPlaying.userInfo[kVibeAudioErrorRequestIdentifierKey]);
    XCTAssertNil(notPlaying.userInfo[kVibeAudioErrorTrackKey]);
    XCTAssertGreaterThan(c, b, @"the play behind the Pause is not one it settles");
    NSDictionary *restart = [self eventsNamed:@"start"].lastObject;
    XCTAssertEqualObjects(restart[@"request"], @(c));
    XCTAssertEqual(restart[@"item"], first);
    XCTAssertTrue(_player.isPlaying);
}

// A splice carries the finished play's identifier and the one its
// prefetch returned, and the spliced row then answers to that one.
- (void)testAGaplessSpliceNamesBothRequests {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSArray<VibeTestTrack *> *rows = @[VibeCueRow(url, 0, 30), VibeCueRow(url, 30, 75), VibeCueRow(url, 75, 0)];
    _chain = rows; _nextPrefetch = 1;
    uint64_t played = [_player requestPlay:rows[0]];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self renderSeconds:2.1];
    [self settleUntil:^BOOL { return [self count:@"advance"] >= 2 && [self count:@"finish"] >= 1; }];
    XCTAssertNil(_playError);
    NSArray<NSDictionary *> *starts = [self eventsNamed:@"start"], *advances = [self eventsNamed:@"advance"];
    XCTAssertEqual(starts.count, 1u);
    XCTAssertEqualObjects(starts.firstObject[@"request"], @(played));
    XCTAssertEqual(advances.count, 2u);
    uint64_t finished = played;
    for (NSUInteger i = 0; i < advances.count; i++) {
        NSDictionary *advance = advances[i];
        uint64_t started = [advance[@"started"] unsignedLongLongValue];
        XCTAssertEqualObjects(advance[@"finished"], @(finished), @"advance %lu", (unsigned long)i);
        XCTAssertEqual(_prefetches[@(started)], rows[i + 1], @"advance %lu started a request its prefetch did not return", (unsigned long)i);
        XCTAssertEqual(advance[@"from"], rows[i]);
        XCTAssertEqual(advance[@"to"], rows[i + 1]);
        XCTAssertGreaterThan(started, finished);
        finished = started;
    }
    NSDictionary *finish = [self eventsNamed:@"finish"].firstObject;
    XCTAssertEqualObjects(finish[@"request"], @(finished));
    XCTAssertEqual(finish[@"item"], rows.lastObject);
}

// An open a newer play supersedes ends with nothing: it was told it was
// loading, and nothing after.
- (void)testASupersededOpenGetsNoFurtherCallback {
    NSData *pcm = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    NSURL *hung = [self write:[pcm subdataWithRange:NSMakeRange(0, 16000 * 8)] rate:48000 channels:2
                         name:@"request-hung.wav"];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [AudioFileMaterializationCoordinator debugHangOpensForBasename:hung.lastPathComponent];
    @try {
        VibeTestTrack *slow = [VibeTestTrack withURL:hung];
        uint64_t superseded = [_player requestPlay:slow];
        [self settleUntil:^BOOL { return [self count:@"loading"] == 1; }];
        NSDictionary *loading = [self eventsNamed:@"loading"].firstObject;
        XCTAssertEqualObjects(loading[@"request"], @(superseded));
        XCTAssertEqual(loading[@"item"], slow);
        XCTAssertTrue(_player.isLoading);

        VibeTestTrack *next = [VibeTestTrack withURL:[self fixture:@"noise-48000-16-2.wav"]];
        uint64_t newer = [_player requestPlay:next];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
        [AudioFileMaterializationCoordinator debugReleaseHungOpens];
        [self settleUntil:^BOOL { return [AudioFileMaterializationCoordinator debugHungOpenCount] == 0; }];
        [self render:9600];
        [_player runSyncOnQueue:^{}];
        [self render:256];
        NSDictionary *start = [self eventsNamed:@"start"].firstObject;
        XCTAssertEqualObjects(start[@"request"], @(newer));
        XCTAssertEqual(start[@"item"], next);
        XCTAssertEqual([self eventsForRequest:superseded].count, 1u, @"only its loading: %@", _events);
        XCTAssertNil(_playError);
        XCTAssertTrue(_player.isPlaying);
    }
    @finally {
        [AudioFileMaterializationCoordinator debugHangOpensForBasename:nil];
    }
}

// A stall names its play, and the replay a Play makes of it is that same play
// to the app, though the player submits it afresh.
- (void)testAStalledPlaysReplayKeepsItsRequest {
    NSURL *source = [self fixture:@"noise-48000-24-2.wav"];
    [self streamingCopyOf:source prefix:44 + 28800 * 6 name:@"stalled.wav"];
    CloudFileAvailability *stream = _stream;
    VibeTestTrack *track = [VibeTestTrack withURL:_streamURL];
    __block uint64_t request = 0;
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        request = [self->_player requestPlay:track];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1 || self->_playError; }];
        [self shortenTheOpenDeadline];
    }];
    [self stallTheStream];
    NSError *stall = _playError;
    XCTAssertEqual(VibeAudioErrorKindOf(stall), VibeAudioErrorKindTrack);
    XCTAssertEqual(stall.userInfo[kVibeAudioErrorTrackKey], track);
    XCTAssertEqualObjects(stall.userInfo[kVibeAudioErrorRequestIdentifierKey], @(request));
    XCTAssertTrue([self renderUntil:^BOOL {
        return atomic_load(&self->_streamCancels) == 1 && stream.readerCount == 0;
    }]);

    _playError = nil;
    [_player playPause];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2 || self->_playError; }];
    XCTAssertNil(_playError);
    NSDictionary *replay = [self eventsNamed:@"start"].lastObject;
    XCTAssertEqualObjects(replay[@"request"], @(request), @"the replay answered to another request");
    XCTAssertEqual(replay[@"item"], track);
    XCTAssertTrue(_player.isPlaying);
}

// Two rows of one file share a URL. Their decode failures still name each
// row and its own play.
- (void)testTwoCueRowsOfOneFileFailAsTwoItems {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.declick = NO;
    __block _Atomic int64_t failFrom = INT64_MAX;
    Method method = class_getInstanceMethod(AudioFileHandle.class, @selector(readIntoBuffer:frameCount:error:));
    __block IMP original;
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioFileHandle *file, AVAudioPCMBuffer *buffer,
                                                        AVAudioFrameCount frames, NSError **error) {
        if ([file.url isEqual:url] && file.framePosition >= atomic_load(&failFrom)) {
            buffer.frameLength = 0;
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
            return NO;
        }
        return ((BOOL (*)(id, SEL, id, AVAudioFrameCount, NSError **))original)(file,
                @selector(readIntoBuffer:frameCount:error:), buffer, frames, error);
    });
    original = method_setImplementation(method, replacement);
    @try {
        NSArray<VibeTestTrack *> *rows = @[VibeCueRow(url, 0, 37), VibeCueRow(url, 37, 0)];
        NSMutableArray<NSNumber *> *requests = [NSMutableArray array];
        for (NSUInteger i = 0; i < rows.count; i++) {
            atomic_store(&failFrom, (int64_t)(rows[i].cueStart * 640 + 4096)); // CD frames at 48 kHz
            NSUInteger errors = _errors.count;
            [requests addObject:@([_player requestPlay:rows[i]])];
            [self settleUntil:^BOOL { return [self count:@"start"] == i + 1; }];
            [self render:20000];
            [self settleUntil:^BOOL { return self->_errors.count > errors; }];
            XCTAssertTrue(_player.isStopped);
        }
        XCTAssertEqual(_errors.count, 2u, @"%@", _errors);
        XCTAssertNotEqualObjects(requests[0], requests[1]);
        for (NSUInteger i = 0; i < rows.count; i++) {
            NSError *error = _errors[i];
            XCTAssertEqual(error.code, VibeAudioErrorEngineStartFailed);
            XCTAssertEqual(VibeAudioErrorKindOf(error), VibeAudioErrorKindTrack, @"a decode failure is the track's");
            XCTAssertEqualObjects(error.userInfo[kVibeAudioErrorTrackURLKey], url);
            XCTAssertEqual(error.userInfo[kVibeAudioErrorTrackKey], rows[i], @"row %lu", (unsigned long)i);
            XCTAssertEqualObjects(error.userInfo[kVibeAudioErrorRequestIdentifierKey], requests[i], @"row %lu", (unsigned long)i);
        }
        XCTAssertEqual([self count:@"finish"], 0u);
    }
    @finally { method_setImplementation(method, original); imp_removeBlock(replacement); }
}

@end
