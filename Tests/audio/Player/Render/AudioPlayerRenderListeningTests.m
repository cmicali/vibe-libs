//
//  AudioPlayerRenderListeningTests.m
//

#import "AudioPlayerRenderTestCase.h"

// The listening stage in the master bus: exact while neutral, heard once set,
// exact again once neutral, with no click at a change, its clipping and its
// rate reported, and out of the path under bit-perfect output. The stage's own tests hold
// its math (Tests/audio/Listening).
@interface AudioPlayerRenderListeningTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderListeningTests

static VibeListeningSettings *Peak(double hz, double dB) {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    settings.eqEnabled = YES;
    settings.bands = @[[VibeEQBand bandWithType:VibeEQBandTypePeak frequency:hz gainDB:dB q:1]];
    settings.preampAutomatic = NO;
    return [settings copy];
}

static float MaxStep(NSData *capture, NSUInteger channel, NSRange frames) {
    const float *p = capture.bytes;
    float step = 0;
    for (NSUInteger f = MAX(frames.location, 1u); f < NSMaxRange(frames); f++) {
        step = fmaxf(step, fabsf(p[f * 2 + channel] - p[(f - 1) * 2 + channel]));
    }
    return step;
}

- (void)testNeutralIsExactASettingIsHeardAndNeutralIsExactAgain {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    XCTAssertTrue(_player.listening.neutral);
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:VibePCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    XCTAssertFalse([_player.debugRenderCounts[@"listening"] boolValue], @"no stage before the first setting");

    // A 1 kHz tone through a +6 dB peak there plays 6 dB louder.
    _player.listening = Peak(1000, 6);
    NSURL *tone = [self write:VibeStereoTone(48000, 48000, 1000, 0.25f) rate:48000 channels:2 name:@"tone1000.wav"];
    [self play:tone paused:NO position:0];
    [_capture setLength:0];
    [self render:24000];
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertTrue([counts[@"listeningEngaged"] boolValue]);
    XCTAssertGreaterThan([counts[@"listeningRenders"] unsignedLongLongValue], 0u);
    double amplitude = VibeToneAmplitude(_capture, 2, 0, 48000, 1000, NSMakeRange(12000, 9600));
    XCTAssertEqualWithAccuracy(20 * log10(amplitude / 0.25), 6, 0.1);

    // Neutral: after its 10 ms fade the track plays as the file, bit for bit.
    _player.listening = [VibeListeningSettings neutralSettings];
    [self play:noise paused:NO position:0];
    [self render:12000];
    XCTAssertTrue([_player.debugRenderCounts[@"listening"] boolValue], @"kept once neutral, so the change fades out");
    XCTAssertFalse([_player.debugRenderCounts[@"listeningEngaged"] boolValue]);
    uint64_t renders = [_player.debugRenderCounts[@"listeningRenders"] unsignedLongLongValue];
    [_capture setLength:0];
    [self render:24000];
    XCTAssertEqual([self assertExactExcerptsOf:@[VibePCM([self read:noise])] inCapture:[_capture copy] rampFrames:0 ramped:NULL], 1u,
                   @"the track after the stage turned neutral is the file exactly");
    XCTAssertEqual([_player.debugRenderCounts[@"listeningRenders"] unsignedLongLongValue], renders,
                   @"the stage rendered while neutral");
}

- (void)testAChangeMidPlayMakesNoClick {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *tone = [self write:VibeStereoTone(4 * 48000, 48000, 211, 0.4f) rate:48000 channels:2 name:@"tone211.wav"];
    [self play:tone paused:NO position:0];
    [self render:9600];
    [_capture setLength:0];
    [self render:9600];
    _player.listening = Peak(211, 12);
    [self render:19200];
    _player.listening = [VibeListeningSettings neutralSettings];
    [self render:19200];
    NSData *capture = [_capture copy];
    // A settled 211 Hz tone at +12 dB steps by about 2π · 211 / 48000 · 1.6,
    // and 211 Hz keeps each change off a zero crossing.
    // A hard switch from 0.4 to 1.6 steps by up to 1.2.
    float settled = MaxStep(capture, 0, NSMakeRange(19200 + 9600, 9600));
    XCTAssertGreaterThan(settled, 0.03f, @"the boost was heard");
    for (NSUInteger c = 0; c < 2; c++) {
        XCTAssertLessThanOrEqual(MaxStep(capture, c, NSMakeRange(1, capture.length / 8 - 1)), 1.1f * settled + 0.002f);
    }
}

- (void)testClippingTurnsOnAndOff {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *tone = [self write:VibeStereoTone(6 * 48000, 48000, 1000, 0.5f) rate:48000 channels:2 name:@"tone1000.wav"];
    [self play:tone paused:NO position:0];
    [self render:4800];
    XCTAssertFalse(_player.listeningClipping);

    // +12 dB on a half-scale tone passes full scale.
    _player.listening = Peak(1000, 12);
    [self render:9600];
    XCTAssertTrue(_player.listeningClipping);
    XCTAssertGreaterThan([_player.debugRenderCounts[@"listeningClips"] unsignedLongLongValue], 0u);
    NSArray *clipping = [self eventsNamed:@"clipping"];
    XCTAssertEqual(clipping.count, 1u);
    XCTAssertEqualObjects(clipping.lastObject[@"clipping"], @YES);

    // The automatic preamp cuts by the boost, and a second later the report
    // ends.
    VibeMutableListeningSettings *automatic = [Peak(1000, 12) mutableCopy];
    automatic.preampAutomatic = YES;
    _player.listening = automatic;
    [self render:48000 + 4800];
    XCTAssertFalse(_player.listeningClipping);
    clipping = [_events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"event == 'clipping'"]];
    XCTAssertEqual(clipping.count, 2u);
    XCTAssertEqualObjects(clipping.lastObject[@"clipping"], @NO);
}

// The real engine tells the delegate once, on main, when the bus's rate
// changes, and the player then reports the new rate.
- (void)testARateChangeReachesTheDelegateOnceOnMain {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self landMainQueue];
    XCTAssertEqual(_player.listeningSampleRate, 48000.0);
    [_events removeAllObjects];

    XCTAssertTrue([_player debugSetOutputRate:96000]);
    _rate = 96000;
    XCTAssertTrue([_player debugSetOutputRate:96000], @"the current rate is a no-op");
    [self landMainQueue];
    NSArray *rates = [self eventsNamed:@"listeningRate"];
    XCTAssertEqual(rates.count, 1u);
    XCTAssertEqualObjects(rates.firstObject[@"rate"], @96000);
    XCTAssertEqualObjects(rates.firstObject[@"main"], @YES);
    XCTAssertEqual(_player.listeningSampleRate, 96000.0);
}

- (void)testBitPerfectOutputHostsNoStage {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.listening = Peak(1000, 6);
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:VibePCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    XCTAssertFalse([_player.debugRenderCounts[@"listening"] boolValue]);
    XCTAssertEqualObjects(_player.listening, Peak(1000, 6), @"the setting is kept for later");
}

@end
