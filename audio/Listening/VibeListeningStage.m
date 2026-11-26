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

// The render works in chunks of this many frames, the scratch's length.
enum { kChunkFrames = 512 };

// A filter state this small is flushed to zero, so a decaying tail never
// reaches the slow denormal range.
static const double kDenormalFloor = 1e-25;

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

// One settings' filters at the stage's rate and channels, built on the queue.
// The render owns it once it takes it, and hands it back on the retired list.
typedef struct VibeListeningProgram VibeListeningProgram;
struct VibeListeningProgram {
    VibeListeningProgram *next;  // on the retired list
    BOOL neutral;
    // The channel tools act on the first two channels, with two or more.
    BOOL swap, mono, crossfeed, balance;
    double preamp;               // linear
    float balanceLeft, balanceRight;
    VibeCrossfeedFilter crossfeedFilter;
    uint32_t channels, bandCount;
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

static VibeListeningProgram *VibeListeningProgramCreate(VibeListeningSettings *settings, uint32_t channels,
                                                        double sampleRate) {
    VibeListeningBiquad filters[kVibeListeningMaxBands];
    uint32_t bandCount = 0;
    double preampDB = 0;
    if (settings.eqEnabled) {
        preampDB = settings.effectivePreampDB;
        for (VibeEQBand *band in settings.bands) {
            if (!band.neutral && bandCount < kVibeListeningMaxBands) {
                filters[bandCount++] =
                    VibeListeningBiquadMake(band.type, band.frequency, band.gainDB, band.q, sampleRate);
            }
        }
    }
    size_t size = VibeListeningProgramSize(channels, bandCount);
    VibeListeningProgram *program = calloc(1, size);
    if (!program) {
        return NULL;
    }
    VibeListeningTouch(program, size);
    BOOL stereo = channels >= 2;
    program->channels = channels;
    program->bandCount = bandCount;
    memcpy(program->filters, filters, bandCount * sizeof(VibeListeningBiquad));
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
                       preampDB == 0 && bandCount == 0;
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
    // NULL plays the input as it is.
    VibeListeningProgram *current, *previous;
    BOOL fading, resting;
    uint32_t fadePosition;
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
    if (channels < 1 || channels > kVibeListeningMaxChannels || !(sampleRate >= 8000)) {
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
    stage->channels = channels;
    stage->sampleRate = sampleRate;
    stage->fadeFrames = VibeFadeFramesForMilliseconds(kFadeDurationMilliseconds, sampleRate);
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
    free(stage->current);
    free(stage->previous);
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

static void VibeListeningProgramRun(VibeListeningProgram *program, float *const *buffers, uint32_t frames)
    CA_REALTIME_API {
    if (!program || program->neutral) {
        return;
    }
    float *left = buffers[0], *right = program->channels >= 2 ? buffers[1] : buffers[0];
    if (program->swap || program->mono) {
        for (uint32_t i = 0; i < frames; i++) {
            float l = left[i], r = right[i];
            if (program->mono) {
                l = r = (l + r) * 0.5f;
            }
            left[i] = program->swap ? r : l;
            right[i] = program->swap ? l : r;
        }
    }
    uint32_t bands = program->bandCount;
    if (bands > 0 || program->preamp != 1.0) {
        for (uint32_t c = 0; c < program->channels; c++) {
            float *samples = buffers[c];
            double *state = program->state + (size_t)c * bands * 2;
            double preamp = program->preamp;
            for (uint32_t i = 0; i < frames; i++) {
                double x = samples[i] * preamp;
                for (uint32_t b = 0; b < bands; b++) {
                    const VibeListeningBiquad *f = &program->filters[b];
                    double *s = state + 2 * b;
                    double y = f->b0 * x + s[0];
                    s[0] = f->b1 * x - f->a1 * y + s[1];
                    s[1] = f->b2 * x - f->a2 * y;
                    x = y;
                }
                samples[i] = (float)x;
            }
            for (uint32_t k = 0; k < bands * 2; k++) {
                if (fabs(state[k]) < kDenormalFloor) {
                    state[k] = 0;
                }
            }
        }
    }
    if (program->crossfeed) {
        VibeCrossfeedFilter *f = &program->crossfeedFilter;
        for (uint32_t i = 0; i < frames; i++) {
            double in[2] = {left[i], right[i]};
            for (int c = 0; c < 2; c++) {
                f->lo[c] = f->loA0 * in[c] + f->loB1 * f->lo[c];
                f->hi[c] = f->hiA0 * in[c] + f->hiA1 * f->in[c] + f->hiB1 * f->hi[c];
                f->in[c] = in[c];
            }
            left[i] = (float)((f->hi[0] + f->lo[1]) * f->gain);
            right[i] = (float)((f->hi[1] + f->lo[0]) * f->gain);
        }
        for (int c = 0; c < 2; c++) {
            f->lo[c] = fabs(f->lo[c]) < kDenormalFloor ? 0 : f->lo[c];
            f->hi[c] = fabs(f->hi[c]) < kDenormalFloor ? 0 : f->hi[c];
        }
    }
    if (program->balance) {
        for (uint32_t i = 0; i < frames; i++) {
            left[i] *= program->balanceLeft;
            right[i] *= program->balanceRight;
        }
    }
}

// The new program starts from the old one's filter state where they match,
// so a small edit's crossfade joins two near-equal signals.
static void VibeListeningProgramInherit(VibeListeningProgram *to, const VibeListeningProgram *from)
    CA_REALTIME_API {
    if (!from) {
        return;
    }
    if (to->bandCount == from->bandCount) {
        size_t count = (size_t)to->channels * to->bandCount * 2;
        for (size_t k = 0; k < count; k++) {
            to->state[k] = from->state[k];
        }
    }
    if (to->crossfeed && from->crossfeed) {
        for (int c = 0; c < 2; c++) {
            to->crossfeedFilter.lo[c] = from->crossfeedFilter.lo[c];
            to->crossfeedFilter.hi[c] = from->crossfeedFilter.hi[c];
            to->crossfeedFilter.in[c] = from->crossfeedFilter.in[c];
        }
    }
}

static void VibeListeningRetire(VibeListeningStage *stage, VibeListeningProgram *program) CA_REALTIME_API {
    if (!program) {
        return;
    }
    VibeListeningProgram *head = atomic_load_explicit(&stage->retired, memory_order_relaxed);
    do {
        program->next = head;
    } while (!atomic_compare_exchange_weak_explicit(&stage->retired, &head, program, memory_order_release,
                                                    memory_order_relaxed));
}

static void VibeListeningChunk(VibeListeningStage *stage, float *const *buffers, uint32_t frames) CA_REALTIME_API {
    uint32_t channels = stage->channels;
    if (!stage->fading) {
        VibeListeningProgram *next = atomic_exchange_explicit(&stage->pending, NULL, memory_order_acquire);
        if (next) {
            VibeListeningProgramInherit(next, stage->current);
            stage->previous = stage->current;
            stage->current = next;
            stage->fading = YES;
            stage->fadePosition = 0;
        }
    }
    if (stage->fading) {
        for (uint32_t c = 0; c < channels; c++) {
            for (uint32_t i = 0; i < frames; i++) {
                stage->scratch[c][i] = buffers[c][i];
            }
        }
        VibeListeningProgramRun(stage->previous, stage->scratch, frames);
        VibeListeningProgramRun(stage->current, buffers, frames);
        for (uint32_t i = 0; i < frames; i++) {
            float t = VibeFadeGainAtFrame(VibeFadeCurveLinear, 0.0f, 1.0f, stage->fadePosition + i, stage->fadeFrames);
            for (uint32_t c = 0; c < channels; c++) {
                float old = stage->scratch[c][i];
                buffers[c][i] = old + (buffers[c][i] - old) * t;
            }
        }
        stage->fadePosition += frames;
        if (stage->fadePosition >= stage->fadeFrames) {
            stage->fading = NO;
            VibeListeningRetire(stage, stage->previous);
            stage->previous = NULL;
        }
    }
    else {
        VibeListeningProgramRun(stage->current, buffers, frames);
    }
    for (uint32_t c = 0; c < channels; c++) {
        for (uint32_t i = 0; i < frames; i++) {
            if (fabsf(buffers[c][i]) > 1.0f) {
                stage->clips++;
                stage->lastClipFrame = stage->frames + i + 1;
            }
        }
    }
    stage->frames += frames;
}

void VibeListeningStageRender(VibeListeningStage *stage, float *const *channels, uint32_t frames) CA_REALTIME_API {
    if (stage->resting && !atomic_load_explicit(&stage->pending, memory_order_relaxed)) {
        return;
    }
    float *chunk[kVibeListeningMaxChannels];
    for (uint32_t offset = 0; offset < frames; offset += kChunkFrames) {
        uint32_t count = frames - offset < kChunkFrames ? frames - offset : kChunkFrames;
        for (uint32_t c = 0; c < stage->channels; c++) {
            chunk[c] = channels[c] + offset;
        }
        VibeListeningChunk(stage, chunk, count);
    }
    stage->resting = !stage->fading && (!stage->current || stage->current->neutral);
    stage->rendered++;
    atomic_store_explicit(&stage->engaged, stage->resting ? 0 : 1, memory_order_relaxed);
    atomic_store_explicit(&stage->reportClips, stage->clips, memory_order_relaxed);
    atomic_store_explicit(&stage->reportLastClipFrame, stage->lastClipFrame, memory_order_relaxed);
    atomic_store_explicit(&stage->reportFrames, stage->frames, memory_order_relaxed);
    atomic_store_explicit(&stage->renders, stage->rendered, memory_order_relaxed);
}

VIBE_REALTIME_END
