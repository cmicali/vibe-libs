//
//  VibeListeningStageTests.m
//  vibe-libs
//

#import <XCTest/XCTest.h>
#import "VibeListeningStage.h"
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

static void FillNoise(NSArray<NSMutableData *> *planes, uint32_t seed, float amplitude) {
    uint32_t state = seed;
    for (NSMutableData *plane in planes) {
        float *samples = plane.mutableBytes;
        for (NSUInteger i = 0; i < plane.length / sizeof(float); i++) {
            state = state * 1664525u + 1013904223u;
            samples[i] = amplitude * ((float)(state >> 8) / (float)(1u << 24) * 2.0f - 1.0f);
        }
    }
}

static void FillSine(float *samples, uint32_t frames, double hz, double rate, float amplitude) {
    for (uint32_t i = 0; i < frames; i++) {
        samples[i] = amplitude * (float)sin(2 * M_PI * hz * i / rate);
    }
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
    for (NSNumber *rate in @[@44100, @48000, @96000]) {
        for (VibeEQBand *band in cases) {
            for (NSNumber *hz in frequencies) {
                double expected = VibeListeningResponseDB(@[band], hz.doubleValue, rate.doubleValue);
                double measured = [self measuredDBAt:hz.doubleValue rate:rate.doubleValue settings:EQ(@[band])];
                XCTAssertEqualWithAccuracy(measured, expected, 0.1, @"%@ at %@ Hz, %@ Hz", band, hz, rate);
            }
        }
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
        float samples[240], *planes[] = {samples};
        double peak = 0, cyclePower = 0;
        for (unsigned first = 0; first < 72000; first += 240) {
            if (first == 48000) {
                s.bands = @[Band(VibeEQBandTypePeak, next, 12, q)];
                XCTAssertTrue(VibeListeningStageSetSettings(stage, s));
            }
            for (unsigned j = 0; j < 240; j++) {
                samples[j] = (float)(0.5 * cos(2 * M_PI * original * (first + j) / 48000 + 0.3));
            }
            VibeListeningStageRender(stage, planes, 240);
            if (first < 48000) continue;
            for (unsigned j = 0; j < 240; j++) {
                peak = fmax(peak, fabs(samples[j]));
                if (bass) {
                    cyclePower += samples[j] * samples[j];
                    if ((first + j + 1) % 800 == 0) {
                        // Each cycle stays within 1 dB of the input level.
                        XCTAssertGreaterThan(sqrt(2 * cyclePower / 800), 0.445);
                        cyclePower = 0;
                    }
                }
            }
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
        float samples[240], *planes[] = {samples};
        double cyclePower = 0, settled = 0.5 * pow(10, (preampRises ? -12 : -24) / 20.0);
        for (unsigned first = 0; first < 72000; first += 240) {
            if (first == 48000) {
                s.bands = edit;
                s.preampDB = preampRises ? 0 : -12;
                XCTAssertTrue(VibeListeningStageSetSettings(stage, s));
            }
            for (unsigned j = 0; j < 240; j++) {
                samples[j] = (float)(0.5 * cos(2 * M_PI * 60 * (first + j) / 48000 + 0.3));
            }
            VibeListeningStageRender(stage, planes, 240);
            for (unsigned j = 0; j < 240; j++) {
                cyclePower += samples[j] * samples[j];
                if ((first + j + 1) % 800 == 0) {
                    // The cycle that holds the preamp's fade is between the two levels.
                    if (first + j + 1 > (preampRises ? 48800u : 48000u)) {
                        XCTAssertEqualWithAccuracy(20 * log10(sqrt(2 * cyclePower / 800) / settled), 0, 0.5);
                    }
                    cyclePower = 0;
                }
            }
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
