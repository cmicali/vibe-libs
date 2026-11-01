//
//  AudioVoiceBusFileGainTests.m
//  vibe-libs
//
//  The voice bus's gain per file, host-less: each voice's file gain, and each
//  successor's from its boundary frame, compared against the files sample by
//  sample. The gains are powers of two, so a scaled sample is exact.
//

#import "AudioVoiceBusTestCase.h"

@interface AudioVoiceBusFileGainTests : AudioVoiceBusTestCase
@end

@implementation AudioVoiceBusFileGainTests

- (NSData *)scaled:(NSData *)source by:(float)gain {
    NSMutableData *scaled = [source mutableCopy];
    float *p = scaled.mutableBytes;
    for (NSUInteger i = 0; i < scaled.length / sizeof(float); i++) {
        p[i] *= gain;
    }
    return scaled;
}

// The capture's frames from `first` on, as many as `expected` holds.
- (NSData *)capture:(NSData *)capture from:(NSUInteger)first like:(NSData *)expected {
    NSUInteger bytes = first * 2 * sizeof(float);
    XCTAssertGreaterThanOrEqual(capture.length, bytes + expected.length);
    return [capture subdataWithRange:NSMakeRange(bytes, MIN(expected.length, capture.length - bytes))];
}

- (void)testAFileGainScalesEverySample {
    NSData *source = [self noiseFrames:20000 channels:2 seed:301];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"scaled.wav"];
    for (NSNumber *gain in @[@0.5f, @2.0f, @0.0f, @1.0f]) {
        [self makeBusAtRate:kRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:url] fileGain:gain.floatValue];
        NSData *capture = [self renderUntilEnded:voice blockSize:256 limit:100000];
        if (gain.floatValue == 0) {
            [self assertSilent:capture from:0]; // a byte compare would tell +0 from the scaled source's -0
        }
        else {
            [self assertCapture:[capture subdataWithRange:NSMakeRange(0, source.length)]
                   equalsSource:[self scaled:source by:gain.floatValue]];
        }
        XCTAssertEqual([self endedSnapshot:voice].fileGain, gain.floatValue);
    }
}

// The rule the plan asks for: the frame before the boundary is the ending
// file's at its gain, and the boundary frame the successor's first at its
// own, wherever the boundary falls in a render, its first frame included.
- (void)testASuccessorTakesItsGainOnTheBoundaryFrameAtEveryBlockSize {
    NSData *a = [self noiseFrames:6000 channels:2 seed:302];
    NSData *b = [self noiseFrames:9000 channels:2 seed:303];
    NSURL *first = [self writePCM:a rate:kRate channels:2 name:@"a.wav"];
    NSURL *second = [self writePCM:b rate:kRate channels:2 name:@"b.wav"];
    NSMutableData *expected = [[self scaled:a by:0.5f] mutableCopy];
    [expected appendData:[self scaled:b by:2]];
    for (NSNumber *block in @[@1, @63, @250, @256, @1024, @4096]) {
        [self makeBusAtRate:kRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:first] fileGain:0.5f];
        XCTAssertTrue([_bus queueSuccessor:[self open:second] startFrame:0 endFrame:0 fileGain:2 forVoice:voice]);
        NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:100000];
        [self assertCapture:[capture subdataWithRange:NSMakeRange(0, expected.length)] equalsSource:expected];
        const float *p = capture.bytes, *x = a.bytes, *y = b.bytes;
        XCTAssertEqual(p[5999 * 2], x[5999 * 2] * 0.5f, @"block %@", block);
        XCTAssertEqual(p[6000 * 2], y[0] * 2, @"block %@", block);
        XCTAssertEqual([self endedSnapshot:voice].boundary, 6000u, @"block %@", block);
        XCTAssertEqual([self endedSnapshot:voice].fileGain, 2.0f, @"block %@", block);
    }
}

// A fade across the boundary is one ramp over both files, each at its gain.
- (void)testAFadeAcrossTheBoundaryKeepsEachFilesGain {
    NSData *a = [self noiseFrames:6000 channels:2 seed:304];
    NSData *b = [self noiseFrames:6000 channels:2 seed:305];
    NSURL *first = [self writePCM:a rate:kRate channels:2 name:@"a.wav"];
    NSURL *second = [self writePCM:b rate:kRate channels:2 name:@"b.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [_bus startVoiceWithFile:[self open:first] atFrame:0 endFrame:0 fileGain:0.25f gain:0
                                            ramp:VibeVoiceRampMake(1, 9600, VibeFadeCurveEqualPower, VibeVoiceActionNone)
                                          paused:NO];
    XCTAssertTrue([_bus queueSuccessor:[self open:second] startFrame:0 endFrame:0 fileGain:4 forVoice:voice]);
    NSData *capture = [self renderUntilEnded:voice blockSize:512 limit:100000];
    const float *p = capture.bytes, *x = a.bytes, *y = b.bytes;
    for (NSUInteger frame = 0; frame < 12000; frame++) {
        float fade = VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 0, 1, (uint32_t)frame, 9600);
        float expected = frame < 6000 ? x[frame * 2] * fade * 0.25f : y[(frame - 6000) * 2] * fade * 4;
        XCTAssertEqualWithAccuracy(p[frame * 2], expected, 1e-5, @"frame %lu", (unsigned long)frame);
        if (fabsf(p[frame * 2] - expected) > 1e-5) {
            return;
        }
    }
}

// The converter carries across the boundary, and the gain still changes on
// its frame: the frames are the unity run's, at each file's gain, exactly.
- (void)testAResampledSuccessorTakesItsGainOnTheBoundaryFrame {
    NSURL *first = [self writePCM:[self noiseFrames:22050 channels:2 seed:306] rate:44100 channels:2 name:@"a441.wav"];
    NSURL *second = [self writePCM:[self noiseFrames:22050 channels:2 seed:307] rate:44100 channels:2 name:@"b441.wav"];
    NSData *runs[2];
    uint64_t boundary = 0;
    for (int run = 0; run < 2; run++) {
        [self makeBusAtRate:kRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:first] fileGain:run ? 0.5f : 1];
        XCTAssertTrue([_bus queueSuccessor:[self open:second] startFrame:0 endFrame:0 fileGain:run ? 2 : 1
                                  forVoice:voice]);
        runs[run] = [self renderUntilEnded:voice blockSize:300 limit:200000];
        boundary = [self endedSnapshot:voice].boundary;
    }
    XCTAssertEqual(boundary, 24000u);
    XCTAssertEqual(runs[0].length, runs[1].length);
    const float *unity = runs[0].bytes, *gained = runs[1].bytes;
    for (NSUInteger i = 0; i < runs[0].length / sizeof(float); i++) {
        float gain = i / 2 < boundary ? 0.5f : 2;
        if (gained[i] != unity[i] * gain) {
            XCTFail(@"frame %lu is %g, not %g", (unsigned long)(i / 2), gained[i], unity[i] * gain);
            return;
        }
    }
}

// Each successor of a chain sounds at its own gain from its own boundary.
- (void)testChainedSuccessorsEachTakeTheirOwnGain {
    NSData *a = [self noiseFrames:2000 channels:2 seed:308];
    NSData *b = [self noiseFrames:3000 channels:2 seed:309];
    NSData *c = [self noiseFrames:4000 channels:2 seed:310];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:[self writePCM:a rate:kRate channels:2 name:@"a.wav"]] fileGain:0.5f];
    XCTAssertTrue([_bus queueSuccessor:[self open:[self writePCM:b rate:kRate channels:2 name:@"b.wav"]]
                            startFrame:0 endFrame:0 fileGain:2 forVoice:voice]);
    NSMutableData *capture = [NSMutableData data];
    while ([self eventsForVoice:voice].count < 2 && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqual([_bus snapshotOfVoice:voice].fileGain, 2.0f);
    XCTAssertTrue([_bus queueSuccessor:[self open:[self writePCM:c rate:kRate channels:2 name:@"c.wav"]]
                            startFrame:0 endFrame:0 fileGain:0.25f forVoice:voice]);
    while (![self hasEnded:voice] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    NSMutableData *expected = [[self scaled:a by:0.5f] mutableCopy];
    [expected appendData:[self scaled:b by:2]];
    [expected appendData:[self scaled:c by:0.25f]];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, expected.length)] equalsSource:expected];
    XCTAssertEqual([self endedSnapshot:voice].fileGain, 0.25f);
}

// A successor taken back never sounds, at its gain or any other, and the one
// queued since follows the ending file's last frame at its own.
- (void)testATakenBackSuccessorsGainNeverSounds {
    NSData *a = [self noiseFrames:6000 channels:2 seed:311];
    NSData *c = [self noiseFrames:30000 channels:2 seed:313];
    NSURL *first = [self writePCM:a rate:kRate channels:2 name:@"a.wav"];
    NSURL *old = [self writePCM:[self noiseFrames:80000 channels:2 seed:312] rate:kRate channels:2 name:@"b.wav"];
    NSURL *next = [self writePCM:c rate:kRate channels:2 name:@"c.wav"];
    NSMutableData *expected = [[self scaled:a by:0.5f] mutableCopy];
    [expected appendData:[self scaled:c by:0.25f]];
    for (NSNumber *left in @[@2400, @576, @1, @0]) {
        [self makeBusAtRate:kRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:first] fileGain:0.5f];
        XCTAssertTrue([_bus queueSuccessor:[self open:old] startFrame:0 endFrame:0 fileGain:4 forVoice:voice]);
        [_bus fillInline];
        XCTAssertGreaterThan([_bus snapshotOfVoice:voice].written, 6000u + 4096, @"the decoder ran into the successor");
        NSMutableData *capture = [NSMutableData data];
        while (capture.length / 8 < 6000 - left.unsignedIntegerValue) {
            uint32_t block = (uint32_t)MIN(256u, 6000 - left.unsignedIntegerValue - capture.length / 8);
            if (left.unsignedIntegerValue > 0 || capture.length / 8 + block < 6000) {
                [self render:block into:capture];
            }
            else {
                [_bus fillInline]; // resting on the boundary, before the drain reports it
                [self renderWithoutFilling:block into:capture];
            }
        }
        XCTAssertFalse([_bus unqueueSuccessorForVoice:voice], @"%@ left", left);
        XCTAssertTrue([_bus takeBackSuccessorForVoice:voice], @"%@ left", left);
        XCTAssertEqual([_bus snapshotOfVoice:voice].fileGain, 0.5f, @"%@ left", left);
        XCTAssertTrue([_bus queueSuccessor:[self open:next] startFrame:0 endFrame:0 fileGain:0.25f forVoice:voice]);
        while (![self hasEnded:voice] && capture.length < 80000 * 8) {
            [self render:256 into:capture];
        }
        [self assertCapture:[capture subdataWithRange:NSMakeRange(0, expected.length)] equalsSource:expected];
        [self assertSilent:capture from:expected.length / sizeof(float)];
        XCTAssertEqual([self endedSnapshot:voice].fileGain, 0.25f, @"%@ left", left);
    }
}

// Named on the report while the render rests on the boundary, the next
// successor waits until the render has crossed it: the boundary's gain is
// taken first, and the next one starts on its own boundary frame.
- (void)testASuccessorNamedOnTheBoundaryWaitsForTheRenderToTakeItsGain {
    NSData *a = [self noiseFrames:2048 channels:2 seed:314];
    NSData *b = [self noiseFrames:3000 channels:2 seed:315];
    NSData *c = [self noiseFrames:3000 channels:2 seed:316];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:[self writePCM:a rate:kRate channels:2 name:@"a.wav"]] fileGain:0.5f];
    XCTAssertTrue([_bus queueSuccessor:[self open:[self writePCM:b rate:kRate channels:2 name:@"b.wav"]]
                            startFrame:0 endFrame:0 fileGain:2 forVoice:voice]);
    NSMutableData *capture = [NSMutableData data];
    for (int i = 0; i < 8; i++) {
        [self render:256 into:capture];
    }
    XCTAssertEqual([_bus snapshotOfVoice:voice].consumed, 2048u);
    XCTAssertEqualObjects([self eventsForVoice:voice], (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary)]));
    XCTAssertEqual([_bus snapshotOfVoice:voice].fileGain, 0.5f, @"nothing of the successor mixed yet");
    XCTAssertTrue([_bus queueSuccessor:[self open:[self writePCM:c rate:kRate channels:2 name:@"c.wav"]]
                            startFrame:0 endFrame:0 fileGain:0.25f forVoice:voice]);
    [self drain];
    XCTAssertEqual([_bus snapshotOfVoice:voice].successorGain, 2.0f, @"the next successor overwrote the gain");
    while (![self hasEnded:voice] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    NSMutableData *expected = [[self scaled:a by:0.5f] mutableCopy];
    [expected appendData:[self scaled:b by:2]];
    [expected appendData:[self scaled:c by:0.25f]];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, expected.length)] equalsSource:expected];
}

// A new gain for the queued successor lands in place while its boundary is
// unreported, and the render takes it on the boundary frame.
- (void)testASuccessorsGainMovesInPlaceBeforeItsBoundary {
    NSData *a = [self noiseFrames:6000 channels:2 seed:317];
    NSData *b = [self noiseFrames:6000 channels:2 seed:318];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:[self writePCM:a rate:kRate channels:2 name:@"a.wav"]] fileGain:1];
    XCTAssertTrue([_bus queueSuccessor:[self open:[self writePCM:b rate:kRate channels:2 name:@"b.wav"]]
                            startFrame:0 endFrame:0 fileGain:4 forVoice:voice]);
    NSMutableData *capture = [NSMutableData data];
    [self render:4096 into:capture];
    XCTAssertEqual([_bus snapshotOfVoice:voice].boundary, 6000u, @"the decoder has claimed the successor");
    XCTAssertTrue([_bus setSuccessorFileGain:0.5f forVoice:voice]);
    while (![self hasEnded:voice] && capture.length < 40000 * 8) {
        [self render:256 into:capture];
    }
    NSMutableData *expected = [a mutableCopy];
    [expected appendData:[self scaled:b by:0.5f]];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, expected.length)] equalsSource:expected];
    XCTAssertFalse([_bus setSuccessorFileGain:2 forVoice:voice], @"an ended voice takes none");
}

@end
