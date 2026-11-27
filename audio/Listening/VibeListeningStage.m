//
//  VibeListeningStage.m
//  vibe-libs
//

#import "VibeListeningStage.h"
#import "VibeListeningBiquad.h"
#import "FadeMath.h"
#import "VibeMacros.h"
#include <math.h>
#include <stdatomic.h>

enum { kChunkFrames = 512 };  // the scratch's length
static const double kDenormalFloor = 1e-25;
// A band whose gain moved this far or less keeps its state. Measured on gain
// steps of peaks and shelves with a tone on the band: up to 3 dB a kept state
// stays within 2.4 dB over the louder settled level. Past that, a band starts
// at rest and warms up, and stays within 1.6 dB.
static const double kCarriedGainStepDB = 3.0;
// The longest warm-up. At 150 ms a 55 Hz tone through random edits stays at
// its input's peak at 192 kHz. At 100 ms it rises 0.1 dB, and at 50 ms 3.2 dB.
static const double kWarmUpCapMilliseconds = 150.0;
// A move the render walks through its in-between curves. Each step goes half
// the carry limits, so 1.5 dB at most. With a tone at a shelf's corner, a
// 12 dB step then dips at most 2.7 dB under the quieter level, where one
// crossfade dipped 24.8 dB, because the two curves' phases nearly cancel.
// Whole carry limits per step dipped 7.3 dB.
static const double kStepShare = 0.5;
// A step lasts 1.5 times the moving bands' settling time, and at least 2 ms.
// At 1 time, a step rose 1.7 dB over the louder level, where one crossfade
// rose 1.2 dB.
static const double kStepPace = 1.5;
static const uint64_t kStepFadeMilliseconds = 2;
// Walked only when every band from the first moving one on settles within
// 15 ms. A slower band's steps pile up their transients: a 60 Hz Q 10 bell
// walked at 10 ms a step rose 7.9 dB. At 10 ms the 1 kHz shelves at Q 10
// dipped 5.8 dB again.
static const double kStepSettleMilliseconds = 15.0;
static const uint32_t kMaxSteps = 24;

#pragma mark - Crossfeed

// bs2b's levels: the cut frequency and the feed, how far the crossed signal
// sits under the direct one at low frequencies.
typedef struct {
    double cutHz, feedDB;
} VibeCrossfeedLevel;

static const VibeCrossfeedLevel kCrossfeedLevels[] = {
    [VibeCrossfeedLight] = {700, 4.5},
    [VibeCrossfeedMedium] = {700, 6.0},
    [VibeCrossfeedStrong] = {650, 9.5},
};

typedef struct {
    double loA0, loB1;          // the crossed channel's low-pass
    double hiA0, hiA1, hiB1;    // the direct channel's high boost
    double gain;                // undoes the low-frequency boost the sum makes
    double lo[2], hi[2], in[2]; // each channel's last low-pass, high boost, and input
} VibeCrossfeedFilter;

// bs2b's published method (Boris Mikhaylov, MIT).
static VibeCrossfeedFilter VibeCrossfeedFilterMake(VibeCrossfeed crossfeed, double sampleRate) {
    VibeCrossfeedLevel level = kCrossfeedLevels[crossfeed];
    double loDB = level.feedDB * -5.0 / 6.0 - 3.0;
    double hiDB = level.feedDB / 6.0 - 3.0;
    double loGain = pow(10.0, loDB / 20.0);
    double hiGain = 1.0 - pow(10.0, hiDB / 20.0);
    double hiCutHz = level.cutHz * pow(2.0, (loDB - 20.0 * log10(hiGain)) / 12.0);
    VibeCrossfeedFilter f = {0};
    double x = exp(-2.0 * M_PI * level.cutHz / sampleRate);
    f.loB1 = x;
    f.loA0 = loGain * (1.0 - x);
    x = exp(-2.0 * M_PI * hiCutHz / sampleRate);
    f.hiB1 = x;
    f.hiA0 = 1.0 - hiGain * (1.0 - x);
    f.hiA1 = -x;
    f.gain = 1.0 / (1.0 - hiGain + loGain);
    return f;
}

#pragma mark - The program

// A band as the program plays it. The tuning is the prewarped frequency, so a
// treble edit near Nyquist is judged by the same fraction of a filter's
// bandwidth as a bass edit.
typedef struct {
    NSUInteger slot;
    VibeEQBandType type;
    double tuning, gainDB, q;
    uint32_t settleFrames;  // from rest, capped
} VibeListeningBand;

typedef struct VibeListeningProgram VibeListeningProgram;
// One settings' filters at the stage's rate and channels, built on the queue.
// The render owns it once it takes it, and hands it back on the retired list.
struct VibeListeningProgram {
    VibeListeningProgram *next;  // on the retired list
    BOOL neutral;
    BOOL step;                   // one of the stage's two step programs, never retired
    // The channel tools act on the first two channels, with two or more.
    BOOL swap, mono, crossfeed, balance;
    double preamp;               // linear
    float balanceLeft, balanceRight;
    VibeCrossfeedFilter crossfeedFilter;
    uint32_t bandCount;
    VibeListeningBand bands[kVibeListeningMaxBands];
    VibeListeningBiquad filters[kVibeListeningMaxBands];
    double state[];              // channels × bandCount × 2, transposed direct form II
};

static size_t VibeListeningProgramSize(uint32_t channels, uint32_t bands) {
    return sizeof(VibeListeningProgram) + (size_t)channels * bands * 2 * sizeof(double);
}

// TRAP: Clang drops a memset(0) after calloc, and turns malloc and memset into
// calloc. A volatile write per page makes the queue take the page faults, not
// the audio thread.
static void VibeListeningTouch(void *memory, size_t size) {
    volatile char *bytes = memory;
    for (size_t i = 0; i < size; i += 4096) {
        bytes[i] = 0;
    }
}

// How long a band takes to settle from rest: three time constants of its
// slowest pole, held under the cap. Complex poles have the radius sqrt(a2).
// A low Q gives two real poles, and the larger one is the slower. A radius of
// 0 gives log(0) = -inf, so 0 frames.
static uint32_t VibeListeningSettleFrames(VibeListeningBiquad f, double sampleRate) CA_REALTIME_API {
    double cap = kWarmUpCapMilliseconds * 0.001 * sampleRate;
    double spread = f.a1 * f.a1 - 4.0 * f.a2;
    double radius = spread < 0 ? sqrt(f.a2) : (fabs(f.a1) + sqrt(spread)) * 0.5;
    double frames = radius < 1 ? -3.0 / log(radius) : cap;
    return (uint32_t)ceil(fmin(frames, cap));
}

static VibeListeningProgram *VibeListeningProgramCreate(VibeListeningSettings *settings, uint32_t channels,
                                                        double sampleRate) {
    VibeListeningBiquad filters[kVibeListeningMaxBands];
    VibeListeningBand bands[kVibeListeningMaxBands];
    uint32_t bandCount = 0;
    double preampDB = 0;
    if (settings.eqEnabled) {
        preampDB = [settings effectivePreampDBAtRate:sampleRate];
        NSUInteger slot = 0;
        for (VibeEQBand *band in settings.bands) {
            if (!band.neutral && bandCount < kVibeListeningMaxBands) {
                double tuning = tan(M_PI * fmin(band.frequency / sampleRate, 0.48));
                VibeListeningBiquad filter =
                    VibeListeningBiquadMake(band.type, band.frequency, band.gainDB, band.q, sampleRate);
                bands[bandCount] = (VibeListeningBand){slot, band.type, tuning, band.gainDB, band.q,
                                                       VibeListeningSettleFrames(filter, sampleRate)};
                filters[bandCount++] = filter;
            }
            slot++;
        }
    }
    size_t size = VibeListeningProgramSize(channels, bandCount);
    VibeListeningProgram *program = calloc(1, size);
    if (!program) {
        return NULL;
    }
    VibeListeningTouch(program, size);
    BOOL stereo = channels >= 2;
    program->bandCount = bandCount;
    memcpy(program->filters, filters, bandCount * sizeof(VibeListeningBiquad));
    memcpy(program->bands, bands, bandCount * sizeof(VibeListeningBand));
    program->preamp = pow(10.0, preampDB / 20.0);
    program->swap = stereo && settings.swapChannels;
    program->mono = stereo && settings.mono;
    program->crossfeed = stereo && settings.crossfeed != VibeCrossfeedOff;
    if (program->crossfeed) {
        program->crossfeedFilter = VibeCrossfeedFilterMake(settings.crossfeed, sampleRate);
    }
    program->balance = stereo && settings.balance != 0;
    program->balanceLeft = (float)fmin(1.0, 1.0 - settings.balance);
    program->balanceRight = (float)fmin(1.0, 1.0 + settings.balance);
    program->neutral = !program->swap && !program->mono && !program->crossfeed && !program->balance &&
                       program->preamp == 1.0 && bandCount == 0;
    return program;
}

// A step program has room for every band, and the render fills it.
static VibeListeningProgram *VibeListeningStepCreate(uint32_t channels) {
    size_t size = VibeListeningProgramSize(channels, kVibeListeningMaxBands);
    VibeListeningProgram *program = calloc(1, size);
    if (program) {
        VibeListeningTouch(program, size);
        program->step = YES;
    }
    return program;
}

static void VibeListeningProgramFreeList(VibeListeningProgram *program) {
    while (program) {
        VibeListeningProgram *next = program->next;
        free(program);
        program = next;
    }
}

#pragma mark - The layout

struct VibeListeningStage {
    uint32_t channels;
    double sampleRate;
    uint32_t fadeFrames;

    // The queue publishes the newest program here, and the render takes it.
    _Atomic(VibeListeningProgram *) pending;
    // The render pushes the programs it has left, and the queue frees them.
    _Atomic(VibeListeningProgram *) retired;

    // The render's own. current plays; previous, while fading, is faded from.
    // NULL plays the input as it is. While warming up, previous alone is heard.
    // target is the newest program, while the render walks to it in steps,
    // which it fills into the two step programs in turn. hurried is set while
    // edits come faster than the changes play, as in a drag: a newer program
    // cut a walk short, or waited for a fade. Then the render takes each new
    // program at once, as a walk would fall behind. Measured on drags with an
    // edit every 10 ms, walking lagged up to 132 ms behind, against 48 ms.
    // It clears once the render is idle.
    VibeListeningProgram *current, *previous, *target;
    VibeListeningProgram *steps[2];
    BOOL fading, resting, hurried;
    uint32_t warmUpFrames, fadePosition, fadeLength, stepFadeFrames, stepFrames;
    float *scratch[kVibeListeningMaxChannels];  // kChunkFrames each
    float *storage;
    uint64_t rendered, frames, clips, lastClipFrame;

    _Atomic int32_t engaged;
    _Atomic uint64_t reportFrames;
    _Atomic uint64_t reportClips;
    _Atomic uint64_t reportLastClipFrame;  // a clip's frame + 1; 0 for none
    _Atomic uint64_t renders;
};

#pragma mark - The queue

VibeListeningStage *VibeListeningStageCreate(uint32_t channels, double sampleRate) {
    if (channels < 1 || channels > kVibeListeningMaxChannels || !(sampleRate >= kVibeListeningMinRate)) {
        return NULL;
    }
    VibeListeningStage *stage = calloc(1, sizeof(VibeListeningStage));
    if (!stage) {
        return NULL;
    }
    size_t storageSize = (size_t)channels * kChunkFrames * sizeof(float);
    stage->storage = calloc(1, storageSize);
    if (!stage->storage) {
        free(stage);
        return NULL;
    }
    VibeListeningTouch(stage->storage, storageSize);
    for (uint32_t c = 0; c < channels; c++) {
        stage->scratch[c] = stage->storage + (size_t)c * kChunkFrames;
    }
    for (int s = 0; s < 2; s++) {
        stage->steps[s] = VibeListeningStepCreate(channels);
        if (!stage->steps[s]) {
            VibeListeningStageFree(stage);
            return NULL;
        }
    }
    stage->channels = channels;
    stage->sampleRate = sampleRate;
    stage->fadeFrames = VibeFadeFramesForMilliseconds(kFadeDurationMilliseconds, sampleRate);
    stage->stepFadeFrames = VibeFadeFramesForMilliseconds(kStepFadeMilliseconds, sampleRate);
    stage->resting = YES;
    atomic_init(&stage->pending, NULL);
    atomic_init(&stage->retired, NULL);
    atomic_init(&stage->engaged, 0);
    atomic_init(&stage->reportFrames, 0);
    atomic_init(&stage->reportClips, 0);
    atomic_init(&stage->reportLastClipFrame, 0);
    atomic_init(&stage->renders, 0);
    return stage;
}

void VibeListeningStageFree(VibeListeningStage *stage) {
    if (!stage) {
        return;
    }
    VibeListeningProgramFreeList(atomic_exchange(&stage->pending, NULL));
    VibeListeningProgramFreeList(atomic_exchange(&stage->retired, NULL));
    VibeListeningProgram *held[] = {stage->current, stage->previous, stage->target};
    for (int p = 0; p < 3; p++) {
        if (held[p] && !held[p]->step) {
            free(held[p]);
        }
    }
    free(stage->steps[0]);
    free(stage->steps[1]);
    free(stage->storage);
    free(stage);
}

BOOL VibeListeningStageSetSettings(VibeListeningStage *stage, VibeListeningSettings *settings) {
    // The render pushed these after its last read of them.
    VibeListeningProgramFreeList(atomic_exchange_explicit(&stage->retired, NULL, memory_order_acquire));
    VibeListeningProgram *program = VibeListeningProgramCreate(settings, stage->channels, stage->sampleRate);
    if (!program) {
        return NO;
    }
    // A program the render never took is still the queue's.
    free(atomic_exchange_explicit(&stage->pending, program, memory_order_acq_rel));
    return YES;
}

uint32_t VibeListeningStageChannels(const VibeListeningStage *stage) CA_REALTIME_API {
    return stage->channels;
}

double VibeListeningStageSampleRate(const VibeListeningStage *stage) {
    return stage->sampleRate;
}

BOOL VibeListeningStageEngaged(const VibeListeningStage *stage) {
    return atomic_load_explicit(&stage->engaged, memory_order_relaxed) != 0;
}

uint64_t VibeListeningStageClips(const VibeListeningStage *stage) {
    return atomic_load_explicit(&stage->reportClips, memory_order_relaxed);
}

BOOL VibeListeningStageClipping(const VibeListeningStage *stage) {
    uint64_t last = atomic_load_explicit(&stage->reportLastClipFrame, memory_order_relaxed);
    uint64_t frames = atomic_load_explicit(&stage->reportFrames, memory_order_relaxed);
    return VibeListeningStageEngaged(stage) && last != 0 && frames - (last - 1) <= (uint64_t)stage->sampleRate;
}

uint64_t VibeListeningStageRenders(const VibeListeningStage *stage) {
    return atomic_load_explicit(&stage->renders, memory_order_relaxed);
}

#pragma mark - The audio thread

VIBE_REALTIME_CHECKED_BEGIN

static void VibeListeningSwapAndMono(float *left, float *right, BOOL swap, BOOL mono, uint32_t frames)
    CA_REALTIME_API {
    if (mono) {
        for (uint32_t i = 0; i < frames; i++) {
            left[i] = right[i] = (left[i] + right[i]) * 0.5f;
        }
    }
    else if (swap) {
        for (uint32_t i = 0; i < frames; i++) {
            float l = left[i];
            left[i] = right[i];
            right[i] = l;
        }
    }
}

// One channel's preamp and EQ. Each band runs over the whole chunk with its
// coefficients and state in locals, in double, so the cascade keeps double
// precision between bands.
static void VibeListeningEQ(const VibeListeningProgram *program, double *state, float *samples, uint32_t frames)
    CA_REALTIME_API {
    double work[kChunkFrames];
    double preamp = program->preamp;
    for (uint32_t i = 0; i < frames; i++) {
        work[i] = samples[i] * preamp;
    }
    for (uint32_t b = 0; b < program->bandCount; b++) {
        VibeListeningBiquad f = program->filters[b];
        double s0 = state[2 * b], s1 = state[2 * b + 1];
        for (uint32_t i = 0; i < frames; i++) {
            double x = work[i];
            double y = f.b0 * x + s0;
            s0 = f.b1 * x - f.a1 * y + s1;
            s1 = f.b2 * x - f.a2 * y;
            work[i] = y;
        }
        state[2 * b] = fabs(s0) < kDenormalFloor ? 0 : s0;
        state[2 * b + 1] = fabs(s1) < kDenormalFloor ? 0 : s1;
    }
    for (uint32_t i = 0; i < frames; i++) {
        samples[i] = (float)work[i];
    }
}

static void VibeListeningCrossfeed(VibeCrossfeedFilter *filter, float *left, float *right, uint32_t frames)
    CA_REALTIME_API {
    VibeCrossfeedFilter f = *filter;
    for (uint32_t i = 0; i < frames; i++) {
        double l = left[i], r = right[i];
        f.lo[0] = f.loA0 * l + f.loB1 * f.lo[0];
        f.lo[1] = f.loA0 * r + f.loB1 * f.lo[1];
        f.hi[0] = f.hiA0 * l + f.hiA1 * f.in[0] + f.hiB1 * f.hi[0];
        f.hi[1] = f.hiA0 * r + f.hiA1 * f.in[1] + f.hiB1 * f.hi[1];
        f.in[0] = l;
        f.in[1] = r;
        left[i] = (float)((f.hi[0] + f.lo[1]) * f.gain);
        right[i] = (float)((f.hi[1] + f.lo[0]) * f.gain);
    }
    for (int c = 0; c < 2; c++) {
        f.lo[c] = fabs(f.lo[c]) < kDenormalFloor ? 0 : f.lo[c];
        f.hi[c] = fabs(f.hi[c]) < kDenormalFloor ? 0 : f.hi[c];
    }
    *filter = f;
}

static void VibeListeningProgramRun(VibeListeningProgram *program, float *const *buffers, uint32_t channels,
                                    uint32_t frames) CA_REALTIME_API {
    if (!program || program->neutral) {
        return;
    }
    float *left = buffers[0], *right = channels >= 2 ? buffers[1] : buffers[0];
    VibeListeningSwapAndMono(left, right, program->swap, program->mono, frames);
    if (program->bandCount > 0 || program->preamp != 1.0) {
        for (uint32_t c = 0; c < channels; c++) {
            VibeListeningEQ(program, program->state + (size_t)c * program->bandCount * 2, buffers[c], frames);
        }
    }
    if (program->crossfeed) {
        VibeListeningCrossfeed(&program->crossfeedFilter, left, right, frames);
    }
    if (program->balance) {
        float gainLeft = program->balanceLeft, gainRight = program->balanceRight;
        for (uint32_t i = 0; i < frames; i++) {
            left[i] *= gainLeft;
            right[i] *= gainRight;
        }
    }
}

// The new program starts from the old one's filter state for each band that
// keeps its slot and type and moved only a little, so a small edit's crossfade
// joins two near-equal signals. A band that moved far, or a new one, starts at
// rest, because its old state describes another resonance. A peak or shelf
// that comes or goes near 0 dB is a small move, as a walk's last step is. The
// bands after a band at rest, or after a removed band, keep their state, but their input changed, so they
// settle too. Returns how many frames the new program needs to settle before
// it is heard: the slowest of those bands' settling times, or 0 when no band
// changed far.
static BOOL VibeListeningBandKeepsState(VibeListeningBand old, VibeListeningBand next) CA_REALTIME_API {
    double q = fmax(old.q, next.q);
    return old.type == next.type &&
           fabs(next.tuning - old.tuning) <= fmin(old.tuning, next.tuning) * fmin(0.1, 0.5 / q) &&
           fabs(old.gainDB - next.gainDB) <= kCarriedGainStepDB && fabs(old.q - next.q) <= 0.1 * q;
}

// A peak or shelf at 0 dB passes its input and holds no state, so a band that
// appears or goes away within the carried gain step is a small move too.
static BOOL VibeListeningBandFades(VibeListeningBand band) CA_REALTIME_API {
    return band.type != VibeEQBandTypeLowPass && band.type != VibeEQBandTypeHighPass;
}

static BOOL VibeListeningBandNearFlat(VibeListeningBand band) CA_REALTIME_API {
    return VibeListeningBandFades(band) && fabs(band.gainDB) <= kStepShare * kCarriedGainStepDB + 1e-9;
}

// A channel's carried state: the mean of its own and the other's as mono
// starts, else the other's, which is its own unless the channels cross.
static inline double VibeListeningCarried(double own, double other, BOOL toMono) CA_REALTIME_API {
    return toMono ? (own + other) * 0.5 : other;
}

static uint32_t VibeListeningProgramInherit(VibeListeningProgram *to, const VibeListeningProgram *from,
                                            uint32_t channels) CA_REALTIME_API {
    if (!from) {
        return 0;
    }
    // The preamp runs before the bands and the crossfeed, so their state
    // scales with it.
    double stateGain = to->preamp / from->preamp;
    // A filter's state follows its input. Mono's input is the mean of the two
    // channels, so its state is the mean of theirs. A swap takes the other
    // channel's. Leaving mono, each channel starts from the mono state.
    BOOL toMono = to->mono && !from->mono, swapped = !to->mono && !from->mono && to->swap != from->swap;
    BOOL crossed = toMono || swapped;  // the first two channels take each other's state
    uint32_t o = 0, warmUp = 0;
    BOOL changed = NO;  // a band before this one was removed or starts at rest
    for (uint32_t b = 0; b < to->bandCount; b++) {
        while (o < from->bandCount && from->bands[o].slot < to->bands[b].slot) {
            changed = changed || !VibeListeningBandNearFlat(from->bands[o]);
            o++;
        }
        // The old band in the same slot, if there is one.
        const VibeListeningBand *old =
            o < from->bandCount && from->bands[o].slot == to->bands[b].slot ? &from->bands[o++] : NULL;
        BOOL kept = old ? VibeListeningBandKeepsState(*old, to->bands[b]) : VibeListeningBandNearFlat(to->bands[b]);
        changed = changed || !kept;
        if (changed) {
            warmUp = MAX(warmUp, to->bands[b].settleFrames);
        }
        if (!kept || !old) {
            continue;
        }
        size_t oldIndex = (size_t)(old - from->bands);
        for (uint32_t c = 0; c < channels; c++) {
            uint32_t other = c < 2 && crossed ? 1 - c : c;
            const double *ownState = from->state + ((size_t)c * from->bandCount + oldIndex) * 2;
            const double *otherState = from->state + ((size_t)other * from->bandCount + oldIndex) * 2;
            double *target = to->state + ((size_t)c * to->bandCount + b) * 2;
            for (int s = 0; s < 2; s++) {
                target[s] = VibeListeningCarried(ownState[s], otherState[s], toMono) * stateGain;
            }
        }
    }
    if (to->crossfeed && from->crossfeed) {
        const VibeCrossfeedFilter *old = &from->crossfeedFilter;
        VibeCrossfeedFilter *next = &to->crossfeedFilter;
        for (int c = 0; c < 2; c++) {
            int other = crossed ? 1 - c : c;
            next->lo[c] = VibeListeningCarried(old->lo[c], old->lo[other], toMono) * stateGain;
            next->hi[c] = VibeListeningCarried(old->hi[c], old->hi[other], toMono) * stateGain;
            next->in[c] = VibeListeningCarried(old->in[c], old->in[other], toMono) * stateGain;
        }
    }
    return warmUp;
}

typedef struct {
    VibeListeningBand from, to;
} VibeListeningMove;

static BOOL VibeListeningSameTools(const VibeListeningProgram *a, const VibeListeningProgram *b) CA_REALTIME_API {
    return a->swap == b->swap && a->mono == b->mono && a->crossfeed == b->crossfeed &&
           a->crossfeedFilter.loA0 == b->crossfeedFilter.loA0 && a->crossfeedFilter.hiA0 == b->crossfeedFilter.hiA0 &&
           a->balance == b->balance && a->balanceLeft == b->balanceLeft && a->balanceRight == b->balanceRight;
}

// How many even steps keep each one within kStepShare of the carry limits,
// with the frequency and Q moved on a log scale.
static uint32_t VibeListeningStepsFor(VibeListeningBand a, VibeListeningBand b) CA_REALTIME_API {
    double q = fmax(a.q, b.q);
    double gain = fabs(b.gainDB - a.gainDB) / (kStepShare * kCarriedGainStepDB);
    double tuning = fabs(log(b.tuning / a.tuning)) / log1p(kStepShare * fmin(0.1, 0.5 / q));
    double width = fabs(log(b.q / a.q)) / -log1p(-kStepShare * 0.1);
    return (uint32_t)ceil(fmax(gain, fmax(tuning, width)) - 1e-9);
}

// Fills `step` with the first of the even steps from `from` to `to`, and
// returns how many there are. Returns 0 when `to` should be taken at once:
// it carries every band, the channel tools changed, a band changed type or a
// pass filter came or went, or the move needs more than kMaxSteps. A peak or
// shelf at one end only moves from or to 0 dB. The coefficients come from
// libm alone, at most a few calls for each of 20 bands, once a step.
static uint32_t VibeListeningPlanStep(VibeListeningProgram *step, const VibeListeningProgram *from,
                                      const VibeListeningProgram *to, uint32_t channels,
                                      double sampleRate, uint32_t *settleFrames) CA_REALTIME_API {
    if (!from || !VibeListeningSameTools(from, to)) {
        return 0;
    }
    VibeListeningMove moves[kVibeListeningMaxBands];
    uint32_t count = 0, steps = 0, f = 0, t = 0, settle = 0;
    while (f < from->bandCount || t < to->bandCount) {
        NSUInteger fromSlot = f < from->bandCount ? from->bands[f].slot : NSUIntegerMax;
        NSUInteger toSlot = t < to->bandCount ? to->bands[t].slot : NSUIntegerMax;
        VibeListeningMove move;
        if (fromSlot == toSlot) {
            move = (VibeListeningMove){from->bands[f++], to->bands[t++]};
        }
        else if (fromSlot < toSlot) {
            move.from = move.to = from->bands[f++];
            move.to.gainDB = 0;
        }
        else {
            move.from = move.to = to->bands[t++];
            move.from.gainDB = 0;
        }
        if (count == kVibeListeningMaxBands || move.from.type != move.to.type ||
            (fromSlot != toSlot && !VibeListeningBandFades(move.from))) {
            return 0;
        }
        uint32_t need = VibeListeningStepsFor(move.from, move.to);
        // A band after a moving one sees its input move, so it must keep up too.
        if (need > 0 || steps > 0) {
            settle = MAX(settle, MAX(move.from.settleFrames, move.to.settleFrames));
        }
        steps = MAX(steps, need);
        moves[count++] = move;
    }
    if (steps < 2 || steps > kMaxSteps || settle > kStepSettleMilliseconds * 0.001 * sampleRate) {
        return 0;
    }
    *settleFrames = settle;
    double share = 1.0 / steps;
    for (uint32_t b = 0; b < count; b++) {
        VibeListeningBand a = moves[b].from, z = moves[b].to, band = z;
        band.tuning = a.tuning * pow(z.tuning / a.tuning, share);
        band.gainDB = a.gainDB + (z.gainDB - a.gainDB) * share;
        band.q = a.q * pow(z.q / a.q, share);
        double hz = atan(band.tuning) * sampleRate / M_PI;
        step->filters[b] = VibeListeningBiquadMake(band.type, hz, band.gainDB, band.q, sampleRate);
        band.settleFrames = VibeListeningSettleFrames(step->filters[b], sampleRate);
        step->bands[b] = band;
    }
    step->bandCount = count;
    // In dB, as the band gains move.
    step->preamp = from->preamp * pow(to->preamp / from->preamp, share);
    step->swap = to->swap;
    step->mono = to->mono;
    step->crossfeed = to->crossfeed;
    step->crossfeedFilter = to->crossfeedFilter;
    for (int c = 0; c < 2; c++) {
        step->crossfeedFilter.lo[c] = step->crossfeedFilter.hi[c] = step->crossfeedFilter.in[c] = 0;
    }
    step->balance = to->balance;
    step->balanceLeft = to->balanceLeft;
    step->balanceRight = to->balanceRight;
    step->neutral = NO;
    for (size_t i = 0; i < (size_t)channels * count * 2; i++) {
        step->state[i] = 0;
    }
    return steps;
}

static void VibeListeningRetire(VibeListeningStage *stage, VibeListeningProgram *program) CA_REALTIME_API {
    if (!program || program->step) {
        return;
    }
    VibeListeningProgram *head = atomic_load_explicit(&stage->retired, memory_order_relaxed);
    do {
        program->next = head;
    } while (!atomic_compare_exchange_weak_explicit(&stage->retired, &head, program, memory_order_release,
                                                    memory_order_relaxed));
}

// Renders the first frames of a chunk and returns how many. A warm-up's end
// splits a chunk, so the fade starts on the frame after it. So does a step's
// end, so the next step starts on the frame after it.
static uint32_t VibeListeningChunk(VibeListeningStage *stage, float *const *buffers, uint32_t frames) CA_REALTIME_API {
    uint32_t channels = stage->channels;
    if (!stage->fading) {
        VibeListeningProgram *next = atomic_exchange_explicit(&stage->pending, NULL, memory_order_acquire);
        if (next) {
            // A newer program ends a walk to an older one, which was never heard.
            stage->hurried = stage->hurried || stage->target != NULL;
            VibeListeningRetire(stage, stage->target);
            stage->target = next;
        }
        if (stage->target) {
            // The step program the render isn't playing.
            VibeListeningProgram *step = stage->steps[stage->steps[0] == stage->current ? 1 : 0];
            uint32_t settle = 0;
            BOOL stepping = !stage->hurried && VibeListeningPlanStep(step, stage->current, stage->target, channels,
                                                                     stage->sampleRate, &settle) > 0;
            VibeListeningProgram *heard = stepping ? step : stage->target;
            if (stepping) {
                stage->stepFrames = MAX(stage->stepFadeFrames, (uint32_t)(settle * kStepPace));
            }
            else {
                stage->target = NULL;
            }
            stage->warmUpFrames = VibeListeningProgramInherit(heard, stage->current, channels);
            BOOL walking = stepping || (stage->current && stage->current->step);
            stage->fadeLength = walking && stage->warmUpFrames == 0 ? stage->stepFrames : stage->fadeFrames;
            stage->previous = stage->current;
            stage->current = heard;
            stage->fading = YES;
            stage->fadePosition = 0;
        }
        else {
            stage->hurried = NO;
        }
    }
    if (stage->fading) {
        // While warming, the new program runs unheard on the copy and the old
        // one is heard. Then the old one runs on the copy and fades out.
        BOOL warming = stage->warmUpFrames > 0;
        if (warming) {
            frames = MIN(frames, stage->warmUpFrames);
        }
        else if (stage->target) {
            frames = MIN(frames, stage->fadeLength - stage->fadePosition);
        }
        for (uint32_t c = 0; c < channels; c++) {
            for (uint32_t i = 0; i < frames; i++) {
                stage->scratch[c][i] = buffers[c][i];
            }
        }
        VibeListeningProgramRun(warming ? stage->current : stage->previous, stage->scratch, channels, frames);
        VibeListeningProgramRun(warming ? stage->previous : stage->current, buffers, channels, frames);
        if (warming) {
            stage->warmUpFrames -= frames;
        }
        else {
            for (uint32_t i = 0; i < frames; i++) {
                float t = VibeFadeGainAtFrame(VibeFadeCurveLinear, 0.0f, 1.0f, stage->fadePosition + i,
                                              stage->fadeLength);
                for (uint32_t c = 0; c < channels; c++) {
                    float old = stage->scratch[c][i];
                    buffers[c][i] = old + (buffers[c][i] - old) * t;
                }
            }
            stage->fadePosition += frames;
            if (stage->fadePosition >= stage->fadeLength) {
                stage->fading = NO;
                stage->hurried =
                    stage->hurried || atomic_load_explicit(&stage->pending, memory_order_relaxed) != NULL;
                VibeListeningRetire(stage, stage->previous);
                stage->previous = NULL;
            }
        }
    }
    else {
        VibeListeningProgramRun(stage->current, buffers, channels, frames);
    }
    for (uint32_t c = 0; c < channels; c++) {
        const float *samples = buffers[c];
        float peak = 0;
        for (uint32_t i = 0; i < frames; i++) {
            peak = fmaxf(peak, fabsf(samples[i]));
        }
        for (uint32_t i = 0; peak > 1.0f && i < frames; i++) {
            if (fabsf(samples[i]) > 1.0f) {
                stage->clips++;
                stage->lastClipFrame = MAX(stage->lastClipFrame, stage->frames + i + 1);
            }
        }
    }
    stage->frames += frames;
    return frames;
}

void VibeListeningStageRender(VibeListeningStage *stage, float *const *channels, uint32_t frames) CA_REALTIME_API {
    if (stage->resting && !atomic_load_explicit(&stage->pending, memory_order_relaxed)) {
        return;
    }
    float *chunk[kVibeListeningMaxChannels];
    for (uint32_t offset = 0; offset < frames;) {
        uint32_t count = frames - offset < kChunkFrames ? frames - offset : kChunkFrames;
        for (uint32_t c = 0; c < stage->channels; c++) {
            chunk[c] = channels[c] + offset;
        }
        offset += VibeListeningChunk(stage, chunk, count);
    }
    stage->resting = !stage->fading && !stage->target && (!stage->current || stage->current->neutral);
    stage->rendered++;
    atomic_store_explicit(&stage->engaged, stage->resting ? 0 : 1, memory_order_relaxed);
    atomic_store_explicit(&stage->reportClips, stage->clips, memory_order_relaxed);
    atomic_store_explicit(&stage->reportLastClipFrame, stage->lastClipFrame, memory_order_relaxed);
    atomic_store_explicit(&stage->reportFrames, stage->frames, memory_order_relaxed);
    atomic_store_explicit(&stage->renders, stage->rendered, memory_order_relaxed);
}

VIBE_REALTIME_END
