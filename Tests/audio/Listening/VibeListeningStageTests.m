//
//  VibeListeningStageTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "VibeListeningStage.h"
#include <malloc/malloc.h>
#include <math.h>

static const uint32_t kSlice = 512;

@interface VibeListeningStageTests : XCTestCase
@end

@implementation VibeListeningStageTests {
    VibeListeningStage *_stage;
}

- (void)tearDown {
    VibeListeningStageFree(_stage);
    _stage = NULL;
    [super tearDown];
}

#pragma mark - Helpers

static VibeEQBand *Band(VibeEQBandType type, double hz, double dB, double q) {
    return [VibeEQBand bandWithType:type frequency:hz gainDB:dB q:q];
}

static VibeListeningSettings *Edited(void (^edit)(VibeMutableListeningSettings *settings)) {
    VibeMutableListeningSettings *settings = [[VibeListeningSettings neutralSettings] mutableCopy];
    edit(settings);
    return [settings copy];
}

// An EQ of `bands` with the preamp at 0 dB, so the output is the curve alone.
static VibeListeningSettings *EQ(NSArray<VibeEQBand *> *bands) {
    return Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = bands;
        s.preampAutomatic = NO;
        s.preampDB = 0;
    });
}

// `channels` planes of `frames` floats each.
static NSMutableArray<NSMutableData *> *Planes(uint32_t channels, uint32_t frames) {
    NSMutableArray *planes = [NSMutableArray array];
    for (uint32_t c = 0; c < channels; c++) {
        [planes addObject:[NSMutableData dataWithLength:frames * sizeof(float)]];
    }
    return planes;
}

static float *Plane(NSArray<NSMutableData *> *planes, NSUInteger c) {
    return planes[c].mutableBytes;
}

// One step of a linear congruential generator, as a value from 0 to 1.
static double NextUniform(uint32_t *state) {
    *state = *state * 1664525u + 1013904223u;
    return (double)(*state >> 8) / (double)(1u << 24);
}

static float NoiseSample(uint32_t *state, float amplitude) {
    return amplitude * ((float)NextUniform(state) * 2.0f - 1.0f);
}

static void FillNoise(NSArray<NSMutableData *> *planes, uint32_t seed, float amplitude) {
    uint32_t state = seed;
    for (NSMutableData *plane in planes) {
        float *samples = plane.mutableBytes;
        for (NSUInteger i = 0; i < plane.length / sizeof(float); i++) {
            samples[i] = NoiseSample(&state, amplitude);
        }
    }
}

// A sine's frames from `start` on, at `phase` radians at frame 0.
static void FillSineFrom(float *samples, uint32_t start, uint32_t frames, double hz, double rate, float amplitude,
                         double phase) {
    for (uint32_t i = 0; i < frames; i++) {
        samples[i] = amplitude * (float)sin(2 * M_PI * hz * (start + i) / rate + phase);
    }
}

static void FillSine(float *samples, uint32_t frames, double hz, double rate, float amplitude) {
    FillSineFrom(samples, 0, frames, hz, rate, amplitude, 0);
}

// Renders every plane through the stage in place, in slices.
static void RenderPlanes(VibeListeningStage *stage, NSArray<NSMutableData *> *planes, uint32_t slice) {
    uint32_t frames = (uint32_t)(planes[0].length / sizeof(float));
    float *buffers[kVibeListeningMaxChannels];
    for (uint32_t offset = 0; offset < frames; offset += slice) {
        for (NSUInteger c = 0; c < planes.count; c++) {
            buffers[c] = Plane(planes, c) + offset;
        }
        VibeListeningStageRender(stage, buffers, MIN(slice, frames - offset));
    }
}

static NSArray<NSMutableData *> *CopyPlanes(NSArray<NSMutableData *> *planes) {
    NSMutableArray *copy = [NSMutableArray array];
    for (NSMutableData *plane in planes) {
        [copy addObject:[plane mutableCopy]];
    }
    return copy;
}

// The amplitude of a `hz` tone in `samples`, by least squares over a sine and
// a cosine, so the window needs no whole number of cycles.
static double ToneAmplitude(const float *samples, uint32_t frames, double hz, double rate) {
    double ss = 0, cc = 0, sc = 0, ys = 0, yc = 0;
    for (uint32_t i = 0; i < frames; i++) {
        double s = sin(2 * M_PI * hz * i / rate), c = cos(2 * M_PI * hz * i / rate);
        ss += s * s;
        cc += c * c;
        sc += s * c;
        ys += samples[i] * s;
        yc += samples[i] * c;
    }
    double det = ss * cc - sc * sc;
    double a = (ys * cc - yc * sc) / det, b = (yc * ss - ys * sc) / det;
    return hypot(a, b);
}

static float MaxStep(const float *samples, uint32_t from, uint32_t to) {
    float step = 0;
    for (uint32_t i = MAX(from, 1u); i < to; i++) {
        step = fmaxf(step, fabsf(samples[i] - samples[i - 1]));
    }
    return step;
}

// The tone the change tests play, at 48 kHz, and the cycle they measure: one
// of 60 Hz.
static const double kToneRate = 48000;
static const float kToneAmplitude = 0.5f;
static const double kTonePhase = M_PI_2 + 0.3;
static const uint32_t kCycleFrames = 800;

// Plays a tone at `hz` on the first channel, the others silent, through
// `stage` for `frames` frames, in slices of `slice` that divide it. `change`
// runs before the slice that starts at frame `at`, and `rendered`, if given,
// after each slice. Returns each channel's level in each cycle, in dB against
// the tone's amplitude, so cycle k holds frames k * 800 to (k + 1) * 800.
static NSArray<NSArray<NSNumber *> *> *CycleLevelsDB(VibeListeningStage *stage, uint32_t channels, double hz,
                                                     uint32_t frames, uint32_t slice, uint32_t at,
                                                     void (^change)(void),
                                                     void (^rendered)(float *const *planes, uint32_t first)) {
    NSArray<NSMutableData *> *planes = Planes(channels, slice);
    float *buffers[kVibeListeningMaxChannels];
    double power[kVibeListeningMaxChannels] = {0};
    NSMutableArray<NSMutableArray<NSNumber *> *> *levels = [NSMutableArray array];
    for (uint32_t c = 0; c < channels; c++) {
        buffers[c] = Plane(planes, c);
        [levels addObject:[NSMutableArray array]];
    }
    for (uint32_t first = 0; first < frames; first += slice) {
        if (first == at) {
            change();
        }
        FillSineFrom(buffers[0], first, slice, hz, kToneRate, kToneAmplitude, kTonePhase);
        for (uint32_t c = 1; c < channels; c++) {
            memset(buffers[c], 0, slice * sizeof(float));
        }
        VibeListeningStageRender(stage, buffers, slice);
        if (rendered) {
            rendered(buffers, first);
        }
        for (uint32_t j = 0; j < slice; j++) {
            for (uint32_t c = 0; c < channels; c++) {
                power[c] += buffers[c][j] * buffers[c][j];
            }
            if ((first + j + 1) % kCycleFrames == 0) {
                for (uint32_t c = 0; c < channels; c++) {
                    [levels[c] addObject:@(20 * log10(sqrt(2 * power[c] / kCycleFrames) / kToneAmplitude))];
                    power[c] = 0;
                }
            }
        }
    }
    return levels;
}

// The stage's measured gain for `bands` matches the response within 0.1 dB at
// each frequency and rate.
- (void)assertBands:(NSArray<VibeEQBand *> *)bands
    matchTheResponseAt:(NSArray<NSNumber *> *)frequencies
                 rates:(NSArray<NSNumber *> *)rates {
    for (NSNumber *rate in rates) {
        for (NSNumber *hz in frequencies) {
            double expected = VibeListeningResponseDB(bands, hz.doubleValue, rate.doubleValue);
            double measured = [self measuredDBAt:hz.doubleValue rate:rate.doubleValue settings:EQ(bands)];
            XCTAssertEqualWithAccuracy(measured, expected, 0.1, @"%@ at %@ Hz, %@ Hz", bands, hz, rate);
        }
    }
}

- (VibeListeningStage *)stageWithChannels:(uint32_t)channels rate:(double)rate settings:(VibeListeningSettings *)settings {
    VibeListeningStageFree(_stage);
    _stage = VibeListeningStageCreate(channels, rate);
    XCTAssertTrue(_stage != NULL);
    if (settings) {
        XCTAssertTrue(VibeListeningStageSetSettings(_stage, settings));
    }
    return _stage;
}

// The stage's gain in dB for a mono `hz` tone, once settled.
- (double)measuredDBAt:(double)hz rate:(double)rate settings:(VibeListeningSettings *)settings {
    VibeListeningStage *stage = [self stageWithChannels:1 rate:rate settings:settings];
    uint32_t settle = (uint32_t)(rate * 0.4), window = (uint32_t)(rate * 0.3);
    NSArray *planes = Planes(1, settle + window);
    FillSine(Plane(planes, 0), settle + window, hz, rate, 0.25f);
    RenderPlanes(stage, planes, kSlice);
    double amplitude = ToneAmplitude(Plane(planes, 0) + settle, window, hz, rate) / 0.25;
    return 20 * log10(amplitude);
}

#pragma mark - Neutral

- (void)testNeutralIsBitIdenticalAndRendersNothing {
    VibeListeningStage *stage = [self stageWithChannels:2 rate:48000 settings:[VibeListeningSettings neutralSettings]];
    NSArray *planes = Planes(2, 48000);
    FillNoise(planes, 1, 0.9f);
    NSArray *original = CopyPlanes(planes);
    RenderPlanes(stage, planes, kSlice);
    XCTAssertEqualObjects(planes, original);
    XCTAssertFalse(VibeListeningStageEngaged(stage));

    // On, then neutral again: once the fade is over, the signal is exact and
    // the stage counts no render.
    VibeListeningStageSetSettings(stage, EQ(@[Band(VibeEQBandTypePeak, 1000, 6, 1)]));
    RenderPlanes(stage, planes, kSlice);
    XCTAssertTrue(VibeListeningStageEngaged(stage));
    VibeListeningStageSetSettings(stage, [VibeListeningSettings neutralSettings]);
    RenderPlanes(stage, Planes(2, 4800), kSlice);
    XCTAssertFalse(VibeListeningStageEngaged(stage));
    uint64_t renders = VibeListeningStageRenders(stage);
    planes = CopyPlanes(original);
    RenderPlanes(stage, planes, kSlice);
    XCTAssertEqualObjects(planes, original);
    XCTAssertEqual(VibeListeningStageRenders(stage), renders);
}

- (void)testMonoAndCrossfeedOnAMonoStreamDoNothing {
    VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) {
        s.mono = YES;
        s.swapChannels = YES;
        s.crossfeed = VibeCrossfeedStrong;
        s.balance = 0.5;
    });
    VibeListeningStage *stage = [self stageWithChannels:1 rate:44100 settings:settings];
    NSArray *planes = Planes(1, 44100);
    FillNoise(planes, 2, 0.5f);
    NSArray *original = CopyPlanes(planes);
    RenderPlanes(stage, planes, kSlice);
    XCTAssertEqualObjects(planes, original);
}

#pragma mark - The EQ

- (void)testEachFilterTypeMatchesTheResponseAtEachRate {
    NSArray<VibeEQBand *> *cases = @[
        Band(VibeEQBandTypePeak, 1000, 6, 1), Band(VibeEQBandTypePeak, 3000, -9, 4),
        Band(VibeEQBandTypeLowShelf, 200, 6, 0.707), Band(VibeEQBandTypeHighShelf, 5000, -6, 0.707),
        Band(VibeEQBandTypeLowPass, 5000, 0, 0.707), Band(VibeEQBandTypeHighPass, 100, 0, 0.707),
    ];
    NSArray<NSNumber *> *frequencies = @[@20, @45, @100, @220, @500, @1000, @2200, @3000, @5000, @10000, @15000, @20000];
    for (VibeEQBand *band in cases) {
        [self assertBands:@[band] matchTheResponseAt:frequencies rates:@[@44100, @48000, @96000]];
    }
}

- (void)testTheAutomaticPreampKeepsAFullScaleToneAtThePeakUnderFullScale {
    NSArray *bands = @[Band(VibeEQBandTypePeak, 1000, 9, 1), Band(VibeEQBandTypePeak, 2500, 6, 2)];
    double peakHz = 20, peakDB = -INFINITY;
    for (double hz = 20; hz < 20000; hz *= 1.001) {
        double dB = VibeListeningResponseDB(bands, hz, 48000);
        if (dB > peakDB) {
            peakDB = dB;
            peakHz = hz;
        }
    }
    VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = bands;
    });
    VibeListeningStage *stage = [self stageWithChannels:2 rate:48000 settings:settings];
    uint32_t frames = 48000, ramp = 4800;
    NSArray *planes = Planes(2, frames);
    for (NSUInteger c = 0; c < 2; c++) {
        float *samples = Plane(planes, c);
        FillSine(samples, frames, peakHz, 48000, 1.0f);
        for (uint32_t i = 0; i < ramp; i++) {
            samples[i] *= (float)(0.5 - 0.5 * cos(M_PI * i / ramp));
        }
    }
    RenderPlanes(stage, planes, kSlice);
    float peak = 0;
    for (NSUInteger c = 0; c < 2; c++) {
        for (uint32_t i = 0; i < frames; i++) {
            peak = fmaxf(peak, fabsf(Plane(planes, c)[i]));
        }
    }
    XCTAssertLessThanOrEqual(peak, 1.0f);
    XCTAssertGreaterThan(peak, 0.99f, @"the tone sits at the curve's peak");
    XCTAssertEqual(VibeListeningStageClips(stage), 0u);
}

- (void)testAStackedCurveMatchesTheResponseAtSixRates {
    NSArray<VibeEQBand *> *bands = @[
        Band(VibeEQBandTypeLowShelf, 100, 4, 0.7), Band(VibeEQBandTypePeak, 60, -12, 6),
        Band(VibeEQBandTypePeak, 1000, 6, 8), Band(VibeEQBandTypePeak, 2500, 4, 2),
        Band(VibeEQBandTypePeak, 3200, -3, 1.5), Band(VibeEQBandTypeHighShelf, 8000, -5, 0.7),
    ];
    [self assertBands:bands
        matchTheResponseAt:@[@30, @60, @100, @300, @1000, @2500, @3200, @6000, @12000, @18000]
                     rates:@[@44100, @48000, @88200, @96000, @176400, @192000]];
}

- (void)testHeadroomCoversTheBassShelfAndThePlaybackRate {
    VibeListeningSettings *bass = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = @[Band(VibeEQBandTypeLowShelf, 20, 12, sqrt(0.5))];
    });
    XCTAssertEqualWithAccuracy([bass effectivePreampDBAtRate:48000], -12, 1e-5);
    XCTAssertEqualWithAccuracy([self measuredDBAt:10 rate:48000 settings:bass], -0.897, 0.01);
    VibeListeningSettings *treble = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.bands = [VibeListeningSettings graphicBandsWithGains:@[@0,@0,@0,@0,@0,@0,@1,@3,@5,@6]];
    });
    XCTAssertEqualWithAccuracy([self measuredDBAt:16000 rate:96000 settings:treble], -0.025, 0.01);
    VibeEQBand *high = Band(VibeEQBandTypeHighShelf, 20000, 12, sqrt(0.5));
    XCTAssertEqualWithAccuracy(VibeListeningAutomaticPreampDBAtRate(@[high], 96000), -12, 1e-6);
}

#pragma mark - Changes

- (void)testRetuningAPeakDoesNotBurstOrDropASustainedBassNote {
    for (NSNumber *hz in @[@8000, @60]) {
        BOOL bass = hz.integerValue == 60;
        double original = hz.doubleValue, next = bass ? 61 : 50, q = bass ? 6 : 5;
        VibeMutableListeningSettings *s = [VibeListeningSettings.neutralSettings mutableCopy];
        s.eqEnabled = YES;
        s.bands = @[Band(VibeEQBandTypePeak, original, 12, q)];
        VibeListeningStage *stage = [self stageWithChannels:1 rate:48000 settings:s];
        __block double peak = 0;
        NSArray<NSNumber *> *levels = CycleLevelsDB(stage, 1, original, 72000, 240, 48000, ^{
            s.bands = @[Band(VibeEQBandTypePeak, next, 12, q)];
            XCTAssertTrue(VibeListeningStageSetSettings(stage, s));
        }, ^(float *const *planes, uint32_t first) {
            for (uint32_t j = 0; j < 240 && first >= 48000; j++) {
                peak = fmax(peak, fabs(planes[0][j]));
            }
        })[0];
        // Each bass cycle stays within 1 dB of the input level: over 0.445.
        for (NSUInteger k = 48000 / kCycleFrames; bass && k < levels.count; k++) {
            XCTAssertGreaterThan(levels[k].doubleValue, 20 * log10(0.445 / kToneAmplitude), @"cycle %lu", k);
        }
        XCTAssertLessThan(peak, 0.51);
    }
}

// A 60 Hz tone through a narrow 60 Hz cut. An edit to the band before the cut,
// or a rise in the preamp, must leave every cycle at the cut's settled level.
- (void)testAnEditLeavesABassCutAfterItSettled {
    VibeEQBand *cut = Band(VibeEQBandTypePeak, 60, -12, 6);
    VibeEQBand *treble = Band(VibeEQBandTypePeak, 8000, 3, 1);
    NSArray<NSArray<VibeEQBand *> *> *edits = @[
        @[Band(VibeEQBandTypePeak, 8000, 6, 1), cut],
        @[Band(VibeEQBandTypePeak, 4000, 3, 1), cut],
        @[[treble bandWithEnabled:NO], cut],
        @[[treble bandWithGainDB:0], cut],
        @[treble, cut],
    ];
    for (NSArray<VibeEQBand *> *edit in edits) {
        // The last edit keeps the bands and raises the preamp by 12 dB.
        BOOL preampRises = edit == edits.lastObject;
        VibeMutableListeningSettings *s = [EQ(@[treble, cut]) mutableCopy];
        s.preampDB = -12;
        VibeListeningStage *stage = [self stageWithChannels:1 rate:48000 settings:s];
        double settledDB = preampRises ? -12 : -24;
        NSArray<NSNumber *> *levels = CycleLevelsDB(stage, 1, 60, 72000, 240, 48000, ^{
            s.bands = edit;
            s.preampDB = preampRises ? 0 : -12;
            XCTAssertTrue(VibeListeningStageSetSettings(stage, s));
        }, nil)[0];
        // The cycle that holds the preamp's fade is between the two levels.
        for (NSUInteger k = 48000 / kCycleFrames + (preampRises ? 1 : 0); k < levels.count; k++) {
            XCTAssertEqualWithAccuracy(levels[k].doubleValue, settledDB, 0.5, @"cycle %lu", k);
        }
    }
}

// A 60 Hz tone on the left alone, through a narrow 60 Hz cut. Swap and mono
// carry the cut's state to the channel's new input, so once the fade is over
// every cycle is at the cut's settled level.
- (void)testSwapAndMonoKeepABassCutSettled {
    for (int mono = 0; mono < 2; mono++) {
        VibeMutableListeningSettings *s = [EQ(@[Band(VibeEQBandTypePeak, 60, -12, 6)]) mutableCopy];
        VibeListeningStage *stage = [self stageWithChannels:2 rate:48000 settings:s];
        // Mono plays half the left on each side.
        double settledDB = -12 + (mono ? 20 * log10(0.5) : 0);
        NSArray<NSArray<NSNumber *> *> *levels = CycleLevelsDB(stage, 2, 60, 72000, 240, 48000, ^{
            s.mono = mono;
            s.swapChannels = !mono;
            XCTAssertTrue(VibeListeningStageSetSettings(stage, s));
        }, nil);
        // The fade ends in the first cycle after the change.
        for (int c = mono ? 0 : 1; c < 2; c++) {
            for (NSUInteger k = 48000 / kCycleFrames + 1; k < levels[c].count; k++) {
                XCTAssertEqualWithAccuracy(levels[c][k].doubleValue, settledDB, 0.5, @"%@, channel %d, cycle %lu",
                                           mono ? @"mono" : @"swap", c, k);
            }
        }
    }
}

// A gain step past the carried one makes a 60 Hz bell start at rest. It warms
// up on the input while the old curve alone is heard, so a bass note on the
// bell neither dips nor bursts when the new curve fades in.
- (void)testALargeChangeWarmsUpBeforeItIsHeard {
    double steps[][2] = {{6, 12}, {12, 6}, {-6, 6}};
    for (int k = 0; k < 3; k++) {
        double from = steps[k][0], to = steps[k][1];
        VibeMutableListeningSettings *s = [EQ(@[Band(VibeEQBandTypePeak, 60, from, 6)]) mutableCopy];
        s.preampDB = -12;
        VibeListeningStage *stage = [self stageWithChannels:1 rate:48000 settings:s];
        VibeListeningStage *reference = VibeListeningStageCreate(1, 48000);
        VibeListeningStageSetSettings(reference, s);
        // Slices off the warm-up's grid, so its end splits a slice.
        NSArray<NSMutableData *> *oldPlanes = Planes(1, 500);
        float *old = Plane(oldPlanes, 0);
        const uint32_t change = 48000;
        __block uint32_t heard = 0;
        NSArray<NSNumber *> *levels = CycleLevelsDB(stage, 1, 60, 96000, 500, change, ^{
            s.bands = @[Band(VibeEQBandTypePeak, 60, to, 6)];
            XCTAssertTrue(VibeListeningStageSetSettings(stage, s));
        }, ^(float *const *planes, uint32_t first) {
            float *oldBuffers[] = {old};
            FillSineFrom(old, first, 500, 60, kToneRate, kToneAmplitude, kTonePhase);
            VibeListeningStageRender(reference, oldBuffers, 500);
            for (uint32_t j = 0; j < 500 && first >= change; j++) {
                if (!heard && planes[0][j] != old[j]) {
                    heard = first + j - change;
                }
            }
            if (first >= change && first < change + 4800) {
                XCTAssertTrue(VibeListeningStageEngaged(stage));
            }
        })[0];
        VibeListeningStageFree(reference);
        // The preamp is -12 dB.
        double low = INFINITY, high = -INFINITY;
        for (NSUInteger k = change / kCycleFrames; k < levels.count; k++) {
            low = fmin(low, levels[k].doubleValue + 12);
            high = fmax(high, levels[k].doubleValue + 12);
        }
        // A boost to +12 dB at Q 6 takes 190 ms to settle, so its warm-up is
        // the cap, 150 ms. A bell at +6 dB takes 135 ms. The fade's first
        // frame still plays the old curve alone.
        XCTAssertEqual(heard, (to == 12 ? 7200u : 6475u) + 1, @"%g to %g dB", from, to);
        XCTAssertGreaterThan(low, fmin(from, to) - 0.5, @"%g to %g dB", from, to);
        XCTAssertLessThan(high, fmax(from, to) + 0.5, @"%g to %g dB", from, to);
    }
}

// Plays a 1 kHz tone of amplitude 0.5 through `stage` at 48 kHz, in slices
// of 64 frames, and publishes `changes[k]` before the slice at frame
// `at + k * every`. Returns each 48-frame cycle's level in dB against the tone.
static NSArray<NSNumber *> *KilohertzCyclesDB(VibeListeningStage *stage, uint32_t frames, uint32_t at, uint32_t every,
                                              NSArray<VibeListeningSettings *> *changes) {
    const uint32_t slice = 64, cycle = 48;
    float samples[64], *planes[] = {samples};
    NSMutableArray<NSNumber *> *levels = [NSMutableArray array];
    double power = 0;
    NSUInteger next = 0;
    for (uint32_t first = 0; first < frames; first += slice) {
        while (next < changes.count && first >= at + next * every) {
            VibeListeningStageSetSettings(stage, changes[next++]);
        }
        FillSineFrom(samples, first, slice, 1000, kToneRate, kToneAmplitude, kTonePhase);
        VibeListeningStageRender(stage, planes, slice);
        for (uint32_t j = 0; j < slice; j++) {
            power += samples[j] * samples[j];
            if ((first + j + 1) % cycle == 0) {
                [levels addObject:@(10 * log10(fmax(2 * power / cycle, 1e-30) / (kToneAmplitude * kToneAmplitude)))];
                power = 0;
            }
        }
    }
    return levels;
}

// A 12 dB gain step on a 1 kHz shelf, the tone at its corner, with the
// automatic preamp. The two curves' phases nearly cancel there, so one
// crossfade dipped 24.8 dB under the quieter level. The render walks the
// in-between curves instead. Measured: at most 2.7 dB under and 1.2 dB over.
- (void)testALargeGainStepOnAShelfWalksWithoutADip {
    for (NSNumber *type in @[@(VibeEQBandTypeHighShelf), @(VibeEQBandTypeLowShelf)]) {
        for (NSNumber *q in @[@3, @10]) {
            for (int up = 0; up < 2; up++) {
                double from = up ? -6 : 6, to = -from;
                VibeListeningSettings * (^shelf)(double) = ^(double gain) {
                    return Edited(^(VibeMutableListeningSettings *s) {
                        s.eqEnabled = YES;
                        s.bands = @[Band(type.integerValue, 1000, gain, q.doubleValue)];
                    });
                };
                VibeListeningStage *stage = [self stageWithChannels:1 rate:kToneRate settings:shelf(from)];
                NSArray<NSNumber *> *levels = KilohertzCyclesDB(stage, 48000, 24000, 0, @[shelf(to)]);
                double before = levels[24000 / 48 - 1].doubleValue, after = levels.lastObject.doubleValue;
                double low = INFINITY, high = -INFINITY;
                for (NSUInteger k = 24000 / 48; k < levels.count; k++) {
                    low = fmin(low, levels[k].doubleValue);
                    high = fmax(high, levels[k].doubleValue);
                }
                XCTAssertGreaterThan(low, fmin(before, after) - 3, @"type %@ Q %@ %g to %g dB", type, q, from, to);
                XCTAssertLessThan(high, fmax(before, after) + 1.5, @"type %@ Q %@ %g to %g dB", type, q, from, to);
            }
        }
    }
}

// A fast drag of a 1 kHz bell's gain, 4 dB every 10 ms from -24 to +24 dB,
// the tone on the bell. The output follows each edit and never bursts.
// Measured: each edit is reached within 25 ms, and no cycle is louder than
// the loudest edit's settled level.
- (void)testAFastDragKeepsUpAndNeverBursts {
    for (int down = 0; down < 2; down++) {
        NSMutableArray<VibeListeningSettings *> *edits = [NSMutableArray array];
        NSMutableArray<NSNumber *> *settled = [NSMutableArray array];
        for (int i = 0; i <= 12; i++) {
            double gain = down ? 24 - 4 * i : -24 + 4 * i;
            VibeMutableListeningSettings *s = [EQ(@[Band(VibeEQBandTypePeak, 1000, gain, 2)]) mutableCopy];
            s.preampDB = -24;
            [edits addObject:s];
            [settled addObject:@(VibeListeningResponseDB(s.bands, 1000, kToneRate) - 24)];
        }
        VibeListeningStage *stage = [self stageWithChannels:1 rate:kToneRate settings:edits[0]];
        const uint32_t start = 24000, every = 480;
        NSArray<NSNumber *> *levels = KilohertzCyclesDB(
            stage, 48000, start, every, [edits subarrayWithRange:NSMakeRange(1, edits.count - 1)]);
        double loudest = fmax(settled.firstObject.doubleValue, settled.lastObject.doubleValue);
        for (NSUInteger k = start / 48; k < levels.count; k++) {
            XCTAssertLessThan(levels[k].doubleValue, loudest + 0.5, @"cycle %lu", (unsigned long)k);
        }
        // Each edit is reached, or passed the way the drag goes, within 40 ms.
        for (NSUInteger e = 1; e < edits.count; e++) {
            NSUInteger at = (start + (e - 1) * every) / 48;
            BOOL reached = NO;
            for (NSUInteger k = at; k < at + 40 && k < levels.count && !reached; k++) {
                double ahead = (down ? -1 : 1) * (levels[k].doubleValue - settled[e].doubleValue);
                reached = ahead >= -1;
            }
            XCTAssertTrue(reached, @"%@, edit %lu", down ? @"down" : @"up", (unsigned long)e);
        }
    }
}

// A walk cut short by newer edits again and again. The render drops the rest
// of each walk, the queue frees every program, and the last edit plays.
// Under Address Sanitizer this finds a use after free. The bytes in use come
// back to where they were, so nothing leaks.
- (void)testAWalkCutShortFreesEveryProgram {
    malloc_statistics_t start, end;
    malloc_zone_statistics(NULL, &start);
    @autoreleasepool {
        VibeListeningStage *stage = VibeListeningStageCreate(2, 48000);
        NSArray *planes = Planes(2, 64), *rest = Planes(2, 4800);
        for (int i = 0; i < 300; i++) {
            @autoreleasepool {
                double gain = i % 2 ? 12 : -12;
                VibeListeningStageSetSettings(stage, EQ(@[Band(VibeEQBandTypeHighShelf, 1000, gain, 3)]));
                FillNoise(planes, (uint32_t)i, 0.5f);
                // A walk of 12 dB at 1 kHz lasts about 30 ms. Every third
                // edit plays out and lets the render go idle, so the next
                // walks. 64 frames leave that walk partway, and the next edit
                // cuts it short. Some edits wait unrendered behind a newer one.
                if (i % 3 == 2) {
                    FillNoise(rest, (uint32_t)i, 0.5f);
                    RenderPlanes(stage, rest, 512);
                }
                else if (i % 7 != 6) {
                    RenderPlanes(stage, planes, 64);
                }
            }
        }
        XCTAssertTrue(VibeListeningStageEngaged(stage));
        // The last edit, +12 dB at 1 kHz with no preamp, settles.
        VibeListeningSettings *last = EQ(@[Band(VibeEQBandTypeHighShelf, 1000, 12, 3)]);
        VibeListeningStageSetSettings(stage, last);
        NSMutableArray *settle = Planes(2, 24000);
        FillSine(Plane(settle, 0), 24000, 5000, 48000, 0.25f);
        RenderPlanes(stage, settle, 512);
        double measured = 20 * log10(ToneAmplitude(Plane(settle, 0) + 12000, 12000, 5000, 48000) / 0.25);
        XCTAssertEqualWithAccuracy(measured, VibeListeningResponseDB(last.bands, 5000, 48000), 0.01);
        VibeListeningStageFree(stage);
    }
    malloc_zone_statistics(NULL, &end);
    // One program for a band in stereo is about 1 KB, so a leak of the 300
    // would show as about 300 KB.
    XCTAssertLessThan((double)end.size_in_use - (double)start.size_in_use, 64 * 1024.0);
}

// Random edits to six random bands, every 20 ms, over noise and a bass tone.
static uint32_t gEditState;
static double NextRandom(void) {
    return NextUniform(&gEditState);
}

static VibeEQBand *RandomBand(void) {
    VibeEQBandType type = (VibeEQBandType)(int)(NextRandom() * 5);
    double hz = 20 * pow(1000, NextRandom()), gain = -24 + 48 * NextRandom(), q = 0.1 * pow(100, NextRandom());
    return [[VibeEQBand alloc] initWithType:type frequency:hz gainDB:gain q:q enabled:NextRandom() > 0.15];
}

- (void)testRandomEditsNeverBurst {
    double rates[] = {44100, 96000, 192000};
    for (int r = 0; r < 3; r++) {
        for (int tone = 0; tone < 2; tone++) {
            gEditState = 99 + (uint32_t)r;
            NSMutableArray<VibeEQBand *> *bands = [NSMutableArray array];
            for (int i = 0; i < 6; i++) {
                [bands addObject:RandomBand()];
            }
            VibeMutableListeningSettings *s = [EQ(bands) mutableCopy];
            s.preampAutomatic = YES;
            VibeListeningStage *stage = [self stageWithChannels:1 rate:rates[r] settings:s];
            uint32_t block = (uint32_t)(rates[r] / 50), noise = 5, frame = 0;
            NSMutableData *plane = [NSMutableData dataWithLength:block * sizeof(float)];
            float *samples = plane.mutableBytes, *planes[] = {samples};
            double peak = 0;
            BOOL finite = YES;
            for (int edit = 0; edit < 300; edit++) {
                int kind = (int)(NextRandom() * 4), index = (int)(NextRandom() * 6);
                VibeEQBand *old = bands[index];
                if (kind == 0) {
                    bands[index] = RandomBand();
                }
                else if (kind == 1) {
                    bands[index] = [old bandWithGainDB:fmax(-24, fmin(24, old.gainDB + (NextRandom() - 0.5) * 8))];
                }
                else if (kind == 2) {
                    double hz = old.frequency * pow(1.3, NextRandom() - 0.5);
                    bands[index] = [[VibeEQBand alloc] initWithType:old.type frequency:hz gainDB:old.gainDB
                                                                  q:old.q enabled:old.enabled];
                }
                else {
                    bands[index] = [old bandWithEnabled:!old.enabled];
                }
                s.bands = bands;
                VibeListeningStageSetSettings(stage, s);
                for (uint32_t j = 0; j < block; j++, frame++) {
                    float noiseSample = NoiseSample(&noise, 0.25f);
                    samples[j] = tone ? (float)(0.25 * sin(2 * M_PI * 55 * frame / rates[r])) : noiseSample;
                }
                VibeListeningStageRender(stage, planes, block);
                for (uint32_t j = 0; j < block; j++) {
                    finite = finite && isfinite(samples[j]);
                    peak = fmax(peak, fabs(samples[j]));
                }
            }
            // Measured: the tone stays at or under its input's peak. With no
            // warm-up it rose 11.4 dB at 192 kHz. The noise rises up to 3.2 dB
            // either way, since the curves themselves boost it.
            double overDB = 20 * log10(peak / 0.25);
            XCTAssertTrue(finite);
            XCTAssertLessThan(overDB, tone ? 0.5 : 3.5, @"%@ at %g Hz", tone ? @"tone" : @"noise", rates[r]);
        }
    }
}

- (void)testAChangeMidPlayMakesNoClick {
    NSArray<VibeListeningSettings *> *steps = @[
        EQ(@[Band(VibeEQBandTypePeak, 211, 12, 1)]),
        EQ(@[Band(VibeEQBandTypeLowShelf, 300, -12, 0.7), Band(VibeEQBandTypeHighPass, 150, 0, 0.7)]),
        Edited(^(VibeMutableListeningSettings *s) { s.swapChannels = YES; }),
        Edited(^(VibeMutableListeningSettings *s) { s.crossfeed = VibeCrossfeedStrong; }),
        Edited(^(VibeMutableListeningSettings *s) { s.balance = 1; }),
        Edited(^(VibeMutableListeningSettings *s) { s.mono = YES; }),
        [VibeListeningSettings neutralSettings],
    ];
    VibeListeningStage *stage = [self stageWithChannels:2 rate:48000 settings:nil];
    uint32_t segment = 9600, frames = segment * (uint32_t)(steps.count + 1);
    NSArray *planes = Planes(2, frames);
    // Off the slice grid's phase, so a switch lands away from a zero crossing.
    FillSine(Plane(planes, 0), frames, 211, 48000, 0.4f);
    FillSine(Plane(planes, 1), frames, 157, 48000, 0.3f);
    float bound = 0;
    float *buffers[2];
    for (uint32_t offset = 0; offset < frames; offset += kSlice) {
        if (offset % segment == 0 && offset > 0) {
            VibeListeningStageSetSettings(stage, steps[offset / segment - 1]);
        }
        buffers[0] = Plane(planes, 0) + offset;
        buffers[1] = Plane(planes, 1) + offset;
        VibeListeningStageRender(stage, buffers, MIN(kSlice, frames - offset));
    }
    for (NSUInteger c = 0; c < 2; c++) {
        bound = fmaxf(bound, MaxStep(Plane(planes, c), 0, segment));
    }
    for (NSUInteger c = 0; c < 2; c++) {
        float *samples = Plane(planes, c);
        for (NSUInteger s = 1; s <= steps.count; s++) {
            uint32_t start = (uint32_t)s * segment;
            float settledBefore = MaxStep(samples, start - 2400, start);
            float settledAfter = MaxStep(samples, start + 2400, start + segment);
            float during = MaxStep(samples, start - 1, start + 2400);
            XCTAssertLessThanOrEqual(during, 1.1f * fmaxf(settledBefore, settledAfter) + 0.002f,
                                     @"step %lu on channel %lu", (unsigned long)s, (unsigned long)c);
        }
    }
    XCTAssertGreaterThan(bound, 0);
}

- (void)testAnOldProgramIsFreedOnlyAfterTheRenderLeavesIt {
    // Many changes between renders: each publish frees the one before it, so
    // only what the render holds stays. Run under Address Sanitizer, this
    // finds a use after free.
    VibeListeningStage *stage = [self stageWithChannels:2 rate:48000 settings:nil];
    NSArray *planes = Planes(2, kSlice);
    for (int i = 0; i < 200; i++) {
        VibeListeningStageSetSettings(stage, EQ(@[Band(VibeEQBandTypePeak, 1000, i % 12, 1)]));
        if (i % 3 == 0) {
            FillNoise(planes, (uint32_t)i, 0.5f);
            RenderPlanes(stage, planes, 64);
        }
    }
    XCTAssertTrue(VibeListeningStageEngaged(stage));
}

#pragma mark - Crossfeed

// bs2b's crossfeed, as its library writes it, in double.
static void ReferenceBS2B(double cutHz, double feedDB, double rate, float *left, float *right, uint32_t frames) {
    double GB_lo = feedDB * -5.0 / 6.0 - 3.0, GB_hi = feedDB / 6.0 - 3.0;
    double G_lo = pow(10, GB_lo / 20.0), G_hi = 1.0 - pow(10, GB_hi / 20.0);
    double Fc_hi = cutHz * pow(2.0, (GB_lo - 20.0 * log10(G_hi)) / 12.0);
    double x = exp(-2.0 * M_PI * cutHz / rate);
    double b1_lo = x, a0_lo = G_lo * (1.0 - x);
    x = exp(-2.0 * M_PI * Fc_hi / rate);
    double b1_hi = x, a0_hi = 1.0 - G_hi * (1.0 - x), a1_hi = -x;
    double gain = 1.0 / (1.0 - G_hi + G_lo);
    double lo[2] = {0}, hi[2] = {0}, asis[2] = {0};
    for (uint32_t i = 0; i < frames; i++) {
        double s[2] = {left[i], right[i]};
        lo[0] = a0_lo * s[0] + b1_lo * lo[0];
        lo[1] = a0_lo * s[1] + b1_lo * lo[1];
        hi[0] = a0_hi * s[0] + a1_hi * asis[0] + b1_hi * hi[0];
        hi[1] = a0_hi * s[1] + a1_hi * asis[1] + b1_hi * hi[1];
        asis[0] = s[0];
        asis[1] = s[1];
        left[i] = (float)((hi[0] + lo[1]) * gain);
        right[i] = (float)((hi[1] + lo[0]) * gain);
    }
}

- (void)testCrossfeedMatchesBS2BAtEachLevel {
    struct { VibeCrossfeed level; double cutHz, feedDB; } levels[] = {
        {VibeCrossfeedLight, 700, 4.5}, {VibeCrossfeedMedium, 700, 6.0}, {VibeCrossfeedStrong, 650, 9.5},
    };
    for (size_t l = 0; l < 3; l++) {
        VibeCrossfeed level = levels[l].level;
        VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) { s.crossfeed = level; });
        // The fade from the input takes 10 ms, so the comparison starts after it.
        VibeListeningStage *stage = [self stageWithChannels:2 rate:44100 settings:settings];
        NSArray *planes = Planes(2, 44100);
        FillNoise(planes, 7, 0.5f);
        NSArray *reference = CopyPlanes(planes);
        RenderPlanes(stage, planes, kSlice);
        ReferenceBS2B(levels[l].cutHz, levels[l].feedDB, 44100, Plane(reference, 0), Plane(reference, 1), 44100);
        for (NSUInteger c = 0; c < 2; c++) {
            for (uint32_t i = 441; i < 44100; i++) {
                XCTAssertEqualWithAccuracy(Plane(planes, c)[i], Plane(reference, c)[i], 1e-6f);
            }
        }

        // A low tone on the left alone reaches the right lower by the level.
        stage = [self stageWithChannels:2 rate:44100 settings:settings];
        planes = Planes(2, 44100);
        FillSine(Plane(planes, 0), 44100, 30, 44100, 0.5f);
        RenderPlanes(stage, planes, kSlice);
        double direct = ToneAmplitude(Plane(planes, 0) + 22050, 22050, 30, 44100);
        double crossed = ToneAmplitude(Plane(planes, 1) + 22050, 22050, 30, 44100);
        XCTAssertEqualWithAccuracy(20 * log10(direct / crossed), levels[l].feedDB, 0.1);
    }
}

#pragma mark - The channel tools

- (void)testMonoSwapAndBalance {
    double rate = 48000;
    uint32_t frames = 4800, settled = 480;
    NSArray *input = Planes(2, frames);
    FillNoise(input, 3, 0.5f);
    float *l = Plane(input, 0), *r = Plane(input, 1);

    NSArray *planes = CopyPlanes(input);
    RenderPlanes([self stageWithChannels:2 rate:rate settings:Edited(^(VibeMutableListeningSettings *s) {
                       s.swapChannels = YES;
                   })],
                 planes, kSlice);
    for (uint32_t i = settled; i < frames; i++) {
        XCTAssertEqual(Plane(planes, 0)[i], r[i]);
        XCTAssertEqual(Plane(planes, 1)[i], l[i]);
    }

    planes = CopyPlanes(input);
    RenderPlanes([self stageWithChannels:2 rate:rate settings:Edited(^(VibeMutableListeningSettings *s) {
                       s.mono = YES;
                   })],
                 planes, kSlice);
    for (uint32_t i = settled; i < frames; i++) {
        XCTAssertEqual(Plane(planes, 0)[i], (l[i] + r[i]) * 0.5f);
        XCTAssertEqual(Plane(planes, 1)[i], (l[i] + r[i]) * 0.5f);
    }

    planes = CopyPlanes(input);
    RenderPlanes([self stageWithChannels:2 rate:rate settings:Edited(^(VibeMutableListeningSettings *s) {
                       s.balance = -0.25;
                   })],
                 planes, kSlice);
    for (uint32_t i = settled; i < frames; i++) {
        XCTAssertEqual(Plane(planes, 0)[i], l[i]);
        XCTAssertEqual(Plane(planes, 1)[i], r[i] * 0.75f);
    }
}

- (void)testPastTwoChannelsTheToolsTouchOnlyTheFirstTwo {
    VibeListeningSettings *settings = Edited(^(VibeMutableListeningSettings *s) {
        s.eqEnabled = YES;
        s.preampAutomatic = NO;
        s.preampDB = -6;
        s.swapChannels = YES;
        s.balance = 0.5;
    });
    uint32_t frames = 4800, settled = 480;
    NSArray *input = Planes(4, frames);
    FillNoise(input, 4, 0.5f);
    NSArray *planes = CopyPlanes(input);
    RenderPlanes([self stageWithChannels:4 rate:48000 settings:settings], planes, kSlice);
    float preamp = (float)pow(10, -6 / 20.0);
    for (uint32_t i = settled; i < frames; i++) {
        XCTAssertEqualWithAccuracy(Plane(planes, 0)[i], Plane(input, 1)[i] * preamp * 0.5f, 1e-6f);
        XCTAssertEqualWithAccuracy(Plane(planes, 1)[i], Plane(input, 0)[i] * preamp, 1e-6f);
        XCTAssertEqualWithAccuracy(Plane(planes, 2)[i], Plane(input, 2)[i] * preamp, 1e-6f);
        XCTAssertEqualWithAccuracy(Plane(planes, 3)[i], Plane(input, 3)[i] * preamp, 1e-6f);
    }
}

#pragma mark - Clipping

- (void)testClippingTurnsOnAndOff {
    VibeListeningSettings *boost = EQ(@[Band(VibeEQBandTypePeak, 1000, 12, 1)]);
    VibeListeningStage *stage = [self stageWithChannels:2 rate:48000 settings:boost];
    NSArray *planes = Planes(2, 9600);
    FillSine(Plane(planes, 0), 9600, 1000, 48000, 0.5f);
    RenderPlanes(stage, planes, kSlice);
    XCTAssertGreaterThan(VibeListeningStageClips(stage), 0u);
    XCTAssertTrue(VibeListeningStageClipping(stage));

    // A second of output with no clip ends it.
    RenderPlanes(stage, Planes(2, 48000 + kSlice), kSlice);
    XCTAssertFalse(VibeListeningStageClipping(stage));

    // And neutral settings end it at once.
    planes = Planes(2, 9600);
    FillSine(Plane(planes, 0), 9600, 1000, 48000, 0.5f);
    RenderPlanes(stage, planes, kSlice);
    XCTAssertTrue(VibeListeningStageClipping(stage));
    VibeListeningStageSetSettings(stage, [VibeListeningSettings neutralSettings]);
    RenderPlanes(stage, Planes(2, 960), kSlice);
    XCTAssertFalse(VibeListeningStageClipping(stage));
}

@end
