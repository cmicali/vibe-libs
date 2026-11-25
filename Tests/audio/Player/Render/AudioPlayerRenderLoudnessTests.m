//
//  AudioPlayerRenderLoudnessTests.m
//

#import "AudioPlayerRenderTestCase.h"

// The loudness stage in the master bus: exact while off, leveling while on,
// exact again once off, and out of the path under bit-perfect output.
@interface AudioPlayerRenderLoudnessTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderLoudnessTests

- (void)testOffIsExactOnLevelsAndOffIsExactAgain {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:VibePCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertFalse([counts[@"loudness"] boolValue], @"no stage before the first turn on");
    XCTAssertEqual([counts[@"loudnessLatency"] doubleValue], 0.0);

    // A quiet low tone is raised, and the limiter keeps it under full scale.
    _player.loudnessEqualization = YES;
    [self play:[self fixture:@"100.wav"] paused:NO position:0];
    [_capture setLength:0];
    [self render:48000];
    counts = _player.debugRenderCounts;
    XCTAssertTrue([counts[@"loudnessEngaged"] boolValue]);
    XCTAssertEqualWithAccuracy([counts[@"loudnessLatency"] doubleValue], (512 + 64) / 48000.0, 1e-9);
    XCTAssertGreaterThan([counts[@"loudnessGain"] floatValue], 1.0f);
    NSUInteger frames = _capture.length / sizeof(float) / 2;
    double rms = VibeRMS(_capture, 2, 0, NSMakeRange(frames - 9600, 9600));
    XCTAssertGreaterThan(rms, 1.5 * 0.25 / sqrt(2), @"the quiet tone was not raised");
    [self assertFinite:_capture peak:1.0f];

    // Off: after its 10 ms fade the track plays on as the file, bit for bit.
    _player.loudnessEqualization = NO;
    [self play:noise paused:NO position:0];
    [self render:12000];
    XCTAssertTrue([_player.debugRenderCounts[@"loudness"] boolValue], @"kept once off, so the switch fades out");
    XCTAssertFalse([_player.debugRenderCounts[@"loudnessEngaged"] boolValue]);
    uint64_t renders = [_player.debugRenderCounts[@"loudnessRenders"] unsignedLongLongValue];
    [_capture setLength:0];
    [self render:24000];
    XCTAssertEqual([self assertExactExcerptsOf:@[VibePCM([self read:noise])] inCapture:[_capture copy] rampFrames:0 ramped:NULL], 1u,
                   @"the track after the stage turned off is the file exactly");
    XCTAssertEqual([_player.debugRenderCounts[@"loudnessRenders"] unsignedLongLongValue], renders, @"the stage rendered while off");
}

- (void)testBitPerfectOutputHostsNoStage {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.loudnessEqualization = YES;
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:VibePCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    XCTAssertFalse([_player.debugRenderCounts[@"loudness"] boolValue]);
    XCTAssertTrue(_player.loudnessEqualization, @"the setting is kept for later");
}

@end
