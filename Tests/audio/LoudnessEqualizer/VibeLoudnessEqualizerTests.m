//
//  VibeLoudnessEqualizerTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "VibeLoudnessEqualizer.h"
#include <math.h>

static const double kRate = 48000;
static const uint32_t kLatency = 512 + 64; // the frame and the look-ahead at 48 kHz
static const uint32_t kSwitchFrames = 480; // 10 ms

// A stereo signal, built and kept by the test.
@interface LEQSignal : NSObject
@property (nonatomic, readonly) uint32_t frames;
- (instancetype)initWithFrames:(uint32_t)frames;
- (float *)left;
- (float *)right;
- (LEQSignal *)copySignal;
@end

@implementation LEQSignal {
    NSMutableData *_left, *_right;
}

- (instancetype)initWithFrames:(uint32_t)frames {
    self = [super init];
    _frames = frames;
    _left = [NSMutableData dataWithLength:frames * sizeof(float)];
    _right = [NSMutableData dataWithLength:frames * sizeof(float)];
    return self;
}

- (float *)left {
    return _left.mutableBytes;
}

- (float *)right {
    return _right.mutableBytes;
}

- (LEQSignal *)copySignal {
    LEQSignal *copy = [[LEQSignal alloc] initWithFrames:_frames];
    memcpy(copy.left, self.left, _frames * sizeof(float));
    memcpy(copy.right, self.right, _frames * sizeof(float));
    return copy;
}

@end

@interface VibeLoudnessEqualizerTests : XCTestCase
@end

@implementation VibeLoudnessEqualizerTests

#pragma mark - Helpers

static void LEQFillSine(LEQSignal *signal, double hz, float amplitude) {
    for (uint32_t i = 0; i < signal.frames; i++) {
        float value = amplitude * (float)sin(2.0 * M_PI * hz * i / kRate);
        signal.left[i] = value;
        signal.right[i] = value;
    }
}

static void LEQFillNoise(LEQSignal *signal, float amplitude, uint32_t seed) {
    uint32_t state = seed;
    for (uint32_t i = 0; i < signal.frames; i++) {
        state = state * 1664525u + 1013904223u;
        signal.left[i] = amplitude * ((float)(state >> 8) / (float)(1u << 24) * 2.0f - 1.0f);
        state = state * 1664525u + 1013904223u;
        signal.right[i] = amplitude * ((float)(state >> 8) / (float)(1u << 24) * 2.0f - 1.0f);
    }
}

// Renders the whole signal in place, in slices of `slice`.
static void LEQRender(VibeLoudnessEqualizer *stage, LEQSignal *signal, uint32_t slice) {
    for (uint32_t offset = 0; offset < signal.frames; offset += slice) {
        uint32_t count = MIN(slice, signal.frames - offset);
        float *channels[2] = { signal.left + offset, signal.right + offset };
        VibeLoudnessEqualizerRender(stage, channels, count);
    }
}

static VibeLoudnessEqualizer *LEQStage(BOOL enabled) {
    VibeLoudnessEqualizer *stage = VibeLoudnessEqualizerCreate(2, kRate);
    VibeLoudnessEqualizerSetEnabled(stage, enabled);
    return stage;
}

#pragma mark - Off

- (void)testOffIsBitPerfectAndCostsNothing {
    VibeLoudnessEqualizer *stage = LEQStage(NO);
    LEQSignal *signal = [[LEQSignal alloc] initWithFrames:48000];
    LEQFillNoise(signal, 0.9f, 1);
    LEQSignal *original = [signal copySignal];
    LEQRender(stage, signal, 512);
    XCTAssertEqual(memcmp(signal.left, original.left, signal.frames * sizeof(float)), 0);
    XCTAssertEqual(memcmp(signal.right, original.right, signal.frames * sizeof(float)), 0);
    XCTAssertFalse(VibeLoudnessEqualizerEngaged(stage));
    XCTAssertEqual(VibeLoudnessEqualizerRenders(stage), 0u);
    XCTAssertEqual(VibeLoudnessEqualizerLatencyFrames(stage), 0u);
    XCTAssertEqual(VibeLoudnessEqualizerGain(stage), 1.0f);
    VibeLoudnessEqualizerFree(stage);
}

- (void)testCreateRefusesWhatItCannotRun {
    XCTAssertTrue(VibeLoudnessEqualizerCreate(0, kRate) == NULL);
    XCTAssertTrue(VibeLoudnessEqualizerCreate(9, kRate) == NULL);
    XCTAssertTrue(VibeLoudnessEqualizerCreate(2, 400) == NULL);
    XCTAssertTrue(VibeLoudnessEqualizerCreate(2, NAN) == NULL);
    VibeLoudnessEqualizer *mono = VibeLoudnessEqualizerCreate(1, 44100);
    XCTAssertTrue(mono != NULL);
    XCTAssertEqual(VibeLoudnessEqualizerChannels(mono), 1u);
    VibeLoudnessEqualizerFree(mono);
    VibeLoudnessEqualizerFree(NULL);
}

#pragma mark - The frame and the latency

- (void)testTheLatencyIsTheFrameAndTheLookAheadAtEachRate {
    struct { double rate; uint32_t latency; } cases[] = {
        {8000, 128 + 16}, {22050, 256 + 32}, {44100, 512 + 64}, {48000, 512 + 64},
        {88200, 1024 + 128}, {96000, 1024 + 128}, {192000, 2048 + 128}, {384000, 4096 + 128},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        VibeLoudnessEqualizer *stage = VibeLoudnessEqualizerCreate(1, cases[i].rate);
        VibeLoudnessEqualizerSetEnabled(stage, YES);
        float buffer[64] = {0};
        float *channels[1] = { buffer };
        VibeLoudnessEqualizerRender(stage, channels, 64);
        XCTAssertEqual(VibeLoudnessEqualizerLatencyFrames(stage), cases[i].latency, @"at %.0f Hz", cases[i].rate);
        VibeLoudnessEqualizerFree(stage);
    }
}

#pragma mark - The leveler

// The values pw-loudness-eq's own leveler and limiter give, chained, for
// this signal: noise, quieted 26 dB through its middle third. They hold the
// FFT's scale, the window, the bands, the loudness law, the release, the
// crossfade, and the limiter to the method. The FFTs differ, so they agree to
// rounding, not to the bit.
- (void)testTheChainMatchesTheReferenceImplementation {
    LEQSignal *signal = [[LEQSignal alloc] initWithFrames:30000];
    LEQFillNoise(signal, 0.3f, 6);
    for (uint32_t i = 10000; i < 20000; i++) {
        signal.left[i] *= 0.05f;
        signal.right[i] *= 0.05f;
    }
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    struct { uint32_t until; float gain; } gains[] = {
        {10000, 0.907259345f}, {20000, 1.30033612f}, {30000, 0.926840067f},
    };
    uint32_t done = 0;
    for (size_t g = 0; g < 3; g++) {
        for (; done < gains[g].until; done++) {
            float *channels[2] = { signal.left + done, signal.right + done };
            VibeLoudnessEqualizerRender(stage, channels, 1);
        }
        XCTAssertEqualWithAccuracy(VibeLoudnessEqualizerGain(stage), gains[g].gain, 1e-5, @"at %u", done);
    }
    struct { uint32_t frame; float left, right; } samples[] = {
        {2000, 0.270700961f, -0.198311493f}, {5000, -0.0372244567f, -0.134982899f},
        {9999, -0.132888705f, 0.110736765f}, {12345, -0.000574594538f, -0.00791849662f},
        {15000, 0.0138836419f, -0.012760778f}, {19999, -0.0133575136f, 0.0143020796f},
        {25000, -0.168254599f, -0.166297987f}, {29999, 0.011111116f, -0.223805949f},
    };
    for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); i++) {
        XCTAssertEqualWithAccuracy(signal.left[samples[i].frame], samples[i].left, 1e-6, @"frame %u", samples[i].frame);
        XCTAssertEqualWithAccuracy(signal.right[samples[i].frame], samples[i].right, 1e-6, @"frame %u", samples[i].frame);
    }
    VibeLoudnessEqualizerFree(stage);
}

- (void)testSilenceRisesTowardTheCapAndALoudPassageCutsAtOnce {
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    LEQSignal *loud = [[LEQSignal alloc] initWithFrames:4800];
    LEQFillNoise(loud, 0.9f, 2);
    LEQRender(stage, loud, 256);
    float cut = VibeLoudnessEqualizerGain(stage);
    XCTAssertLessThan(cut, 1.0f);

    LEQSignal *silence = [[LEQSignal alloc] initWithFrames:48000];
    LEQRender(stage, silence, 256);
    float risen = VibeLoudnessEqualizerGain(stage);
    XCTAssertGreaterThan(risen, cut);
    XCTAssertLessThan(risen, 10.0f, @"one second is well under the release's 4.6 s time constant");

    LEQFillNoise(loud, 0.9f, 3);
    LEQRender(stage, loud, 256);
    XCTAssertEqualWithAccuracy(VibeLoudnessEqualizerGain(stage), cut, cut * 0.05);
    VibeLoudnessEqualizerFree(stage);
}

- (void)testASlowerReleaseRisesMoreSlowly {
    float risen[2];
    int releases[2] = { kVibeLoudnessReleaseFastest, kVibeLoudnessReleaseSlowest };
    for (int i = 0; i < 2; i++) {
        VibeLoudnessEqualizer *stage = LEQStage(YES);
        VibeLoudnessEqualizerSetRelease(stage, releases[i]);
        LEQSignal *loud = [[LEQSignal alloc] initWithFrames:4800];
        LEQFillNoise(loud, 0.9f, 4);
        LEQRender(stage, loud, 256);
        LEQSignal *quiet = [[LEQSignal alloc] initWithFrames:9600];
        LEQFillNoise(quiet, 0.01f, 5);
        LEQRender(stage, quiet, 256);
        risen[i] = VibeLoudnessEqualizerGain(stage);
        VibeLoudnessEqualizerFree(stage);
    }
    XCTAssertGreaterThan(risen[0], risen[1] * 2);
}

- (void)testTheReleaseIsHeldToItsRange {
    VibeLoudnessEqualizer *stage = LEQStage(NO);
    XCTAssertEqual(VibeLoudnessEqualizerRelease(stage), kVibeLoudnessReleaseDefault);
    VibeLoudnessEqualizerSetRelease(stage, 0);
    XCTAssertEqual(VibeLoudnessEqualizerRelease(stage), kVibeLoudnessReleaseFastest);
    VibeLoudnessEqualizerSetRelease(stage, 12);
    XCTAssertEqual(VibeLoudnessEqualizerRelease(stage), kVibeLoudnessReleaseSlowest);
    VibeLoudnessEqualizerFree(stage);
}

- (void)testTheSliceSizeChangesNothing {
    LEQSignal *source = [[LEQSignal alloc] initWithFrames:30000];
    LEQFillNoise(source, 0.3f, 6);
    for (uint32_t i = 10000; i < 20000; i++) {
        source.left[i] *= 0.05f;
        source.right[i] *= 0.05f;
    }
    LEQSignal *reference = nil;
    uint32_t slices[] = { 4096, 1, 37, 256, 512, 1000 };
    for (size_t s = 0; s < sizeof(slices) / sizeof(slices[0]); s++) {
        VibeLoudnessEqualizer *stage = LEQStage(YES);
        LEQSignal *signal = [source copySignal];
        LEQRender(stage, signal, slices[s]);
        if (!reference) {
            reference = signal;
        }
        else {
            XCTAssertEqual(memcmp(signal.left, reference.left, signal.frames * sizeof(float)), 0, @"slices of %u", slices[s]);
            XCTAssertEqual(memcmp(signal.right, reference.right, signal.frames * sizeof(float)), 0, @"slices of %u", slices[s]);
        }
        VibeLoudnessEqualizerFree(stage);
    }
}

#pragma mark - The limiter

- (void)testTheBoostNeverPassesTheCeiling {
    struct { double hz; float amplitude; } cases[] = {
        {3000, 0.3f}, {3000, 0.95f}, {1000, 0.2f}, {6000, 0.5f}, {100, 1.0f},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        VibeLoudnessEqualizer *stage = LEQStage(YES);
        LEQSignal *signal = [[LEQSignal alloc] initWithFrames:48000];
        // Silence first, so the gain sits at its cap when the tone arrives.
        LEQSignal *tone = [[LEQSignal alloc] initWithFrames:24000];
        LEQFillSine(tone, cases[i].hz, cases[i].amplitude);
        memcpy(signal.left + 24000, tone.left, 24000 * sizeof(float));
        memcpy(signal.right + 24000, tone.right, 24000 * sizeof(float));
        LEQRender(stage, signal, 512);
        float peak = 0;
        for (uint32_t f = 0; f < signal.frames; f++) {
            peak = fmaxf(peak, fmaxf(fabsf(signal.left[f]), fabsf(signal.right[f])));
        }
        // The look-ahead's ramp lands exactly on each peak; the frames just
        // before one may pass 0.985 by a little, but never full scale.
        XCTAssertLessThanOrEqual(peak, 1.0f, @"%.0f Hz at %.2f", cases[i].hz, cases[i].amplitude);
        VibeLoudnessEqualizerFree(stage);
    }
}

- (void)testAWhistleIsLimitedWhileItIsBoosted {
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    LEQSignal *signal = [[LEQSignal alloc] initWithFrames:24000];
    LEQFillSine(signal, 3000, 0.2f);
    LEQRender(stage, signal, 512);
    float gain = VibeLoudnessEqualizerGain(stage);
    if (gain * 0.2f > 0.985f) {
        XCTAssertLessThan(VibeLoudnessEqualizerLimiterGain(stage), 1.0f);
    }
    else {
        XCTAssertEqual(VibeLoudnessEqualizerLimiterGain(stage), 1.0f);
    }
    VibeLoudnessEqualizerFree(stage);
}

- (void)testAPeakNoSignalReachesDropsTheSlice {
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    LEQSignal *signal = [[LEQSignal alloc] initWithFrames:4800];
    LEQFillNoise(signal, 0.5f, 7);
    LEQRender(stage, signal, 512);
    LEQSignal *garbage = [[LEQSignal alloc] initWithFrames:512];
    LEQFillNoise(garbage, 0.5f, 8);
    garbage.left[100] = 1000.0f;
    LEQRender(stage, garbage, 512);
    for (uint32_t i = 0; i < 512; i++) {
        XCTAssertTrue(isfinite(garbage.left[i]) && isfinite(garbage.right[i]));
    }
    VibeLoudnessEqualizerFree(stage);
}

#pragma mark - The switch

- (void)testTurningOnPlaysTheInputUntilWarmThenCrossfades {
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    LEQSignal *signal = [[LEQSignal alloc] initWithFrames:4800];
    LEQFillNoise(signal, 0.5f, 9);
    LEQSignal *input = [signal copySignal];
    LEQRender(stage, signal, 128);
    XCTAssertTrue(VibeLoudnessEqualizerEngaged(stage));
    XCTAssertEqual(memcmp(signal.left, input.left, kLatency * sizeof(float)), 0, @"dry while warming");
    // Past the crossfade the output is wholly wet: the input, late by the latency.
    double correlation = 0, power = 0;
    for (uint32_t i = kLatency + kSwitchFrames; i < signal.frames; i++) {
        correlation += signal.left[i] * input.left[i - kLatency];
        power += signal.left[i] * signal.left[i];
    }
    XCTAssertGreaterThan(correlation / power * VibeLoudnessEqualizerGain(stage), 0.9);
    VibeLoudnessEqualizerFree(stage);
}

- (void)testTurningOffCrossfadesBackThenIsBitPerfect {
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    LEQSignal *warmup = [[LEQSignal alloc] initWithFrames:9600];
    LEQFillNoise(warmup, 0.5f, 10);
    LEQRender(stage, warmup, 256);
    VibeLoudnessEqualizerSetEnabled(stage, NO);

    LEQSignal *signal = [[LEQSignal alloc] initWithFrames:4800];
    LEQFillNoise(signal, 0.5f, 11);
    LEQSignal *input = [signal copySignal];
    LEQRender(stage, signal, 256);
    XCTAssertFalse(VibeLoudnessEqualizerEngaged(stage));
    XCTAssertEqual(VibeLoudnessEqualizerLatencyFrames(stage), 0u);
    // The fade ends inside the second slice; from the slice after, nothing is touched.
    uint32_t from = 2 * 256;
    XCTAssertEqual(memcmp(signal.left + from, input.left + from, (signal.frames - from) * sizeof(float)), 0);
    XCTAssertEqual(memcmp(signal.right + from, input.right + from, (signal.frames - from) * sizeof(float)), 0);
    VibeLoudnessEqualizerFree(stage);
}

- (void)testTurningBackOnWhileFadingOutFadesStraightBackIn {
    VibeLoudnessEqualizer *stage = LEQStage(YES);
    LEQSignal *warmup = [[LEQSignal alloc] initWithFrames:9600];
    LEQFillNoise(warmup, 0.5f, 12);
    LEQRender(stage, warmup, 256);
    VibeLoudnessEqualizerSetEnabled(stage, NO);
    LEQSignal *some = [[LEQSignal alloc] initWithFrames:128];
    LEQRender(stage, some, 128);
    XCTAssertTrue(VibeLoudnessEqualizerEngaged(stage));
    VibeLoudnessEqualizerSetEnabled(stage, YES);
    LEQSignal *more = [[LEQSignal alloc] initWithFrames:4800];
    LEQFillNoise(more, 0.5f, 13);
    LEQRender(stage, more, 256);
    XCTAssertTrue(VibeLoudnessEqualizerEngaged(stage));
    XCTAssertLessThan(VibeLoudnessEqualizerGain(stage), 10.0f, @"the leveler kept its state");
    VibeLoudnessEqualizerFree(stage);
}

@end
