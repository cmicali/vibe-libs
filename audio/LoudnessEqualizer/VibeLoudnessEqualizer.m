//
//  VibeLoudnessEqualizer.m
//  vibe-libs
//

#import "VibeLoudnessEqualizer.h"
#import "VibeMacros.h"
#import <Accelerate/Accelerate.h>
#include <math.h>
#include <stdatomic.h>

#pragma mark - The constants

// The loudness model's 25 bands: each one's upper edge, and the power under
// which it counts for nothing.
#define kVibeLoudnessBands 25
static const float kBandUpperHz[kVibeLoudnessBands] = {
    100, 200, 300, 400, 510, 630, 770, 920, 1080, 1270, 1480, 1720, 2000,
    2320, 2700, 3150, 3700, 4400, 5300, 6400, 7700, 9500, 12000, 15500, 24000,
};
static const float kBandThreshold[kVibeLoudnessBands] = {
    1000.0f, 100.0f, 31.6f, 10.0f, 3.16f, 2.0f, 1.0f, 1.0f, 0.316f, 0.316f,
    1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f,
    4.0f, 10.0f, 100.0f, 1000.0f,
};

static const double kWindowScale = 16384.0;    // the window's peak, before dividing by H
static const unsigned kMaxFrameSize = 4096;
static const float kTargetLoudness = 1300.0f;
static const double kLoudnessScale = 1.72;
static const double kGainExponent = (double)1.6f;
static const float kMaxGain = 10.0f;           // +20 dB, and the gain a reset starts from
static const float kLoudnessFloor = 1e-32f;
static const float kReleaseStepFast = 0.1f;    // -20 dB per release step up to 3
static const float kReleaseStepSlow = 0.316f;  // -10 dB per step from 4 to 7
static const float kReleaseRate = 44100.0f;    // the rate the release weight is stated at

static const float kLimitThreshold = 0.985f;
static const float kLimitGarbage = 128.0f;     // a peak above this drops the slice
static const double kLimitRelease = 2.205;     // nepers per second, about 19 dB/s

static const double kSwitchSeconds = 0.010;

#pragma mark - The layout

struct VibeLoudnessEqualizer {
    uint32_t channels;
    double sampleRate;

    // The leveler. Frames of N with half-frames of H. in0 is the older input
    // half, in1 the half being filled; out0 is the half being played and out1
    // the next one's first ramp.
    unsigned frameSize, half, log2FrameSize;
    unsigned edges[kVibeLoudnessBands + 1];
    FFTSetup fft;
    float *window;      // frameSize
    float *frame;       // frameSize: the windowed frame, then its power
    DSPSplitComplex split; // half each: the frame's transform
    float *in0[kVibeLoudnessMaxChannels], *in1[kVibeLoudnessMaxChannels];
    float *out0[kVibeLoudnessMaxChannels], *out1[kVibeLoudnessMaxChannels];
    unsigned position;  // into the half-frames
    float gain;

    // The limiter: a look-ahead of L frames, one gain for every channel.
    unsigned lookAhead;
    float *delay[kVibeLoudnessMaxChannels]; // lookAhead each
    unsigned delayPosition;
    float limitGain, limitTarget, limitStep, limitPeak;
    unsigned limitCount;
    double limitRise, limitFall;

    // A chunk of the leveled, limited signal, at most a half-frame.
    float *wet[kVibeLoudnessMaxChannels];

    // The switch, the render's own: running while the stage is in the path,
    // warm frames before the wet signal is whole, and the wet signal's share.
    BOOL running;
    uint32_t warm;
    float mix;
    float mixStep;

    // The per-channel state, one span, cleared by a reset.
    float *state;
    size_t stateCount;
    float *storage;
    size_t storageCount;

    _Atomic int32_t enabled;
    _Atomic int32_t release;
    _Atomic float weight;   // the release's per-hop share of the way to the target
    _Atomic int32_t engaged;
    _Atomic float reportGain;
    _Atomic float reportLimitGain;
    _Atomic uint64_t renders;
};

#pragma mark - The queue

static unsigned VibeLoudnessFrameSize(double sampleRate) {
    // 2^ceil(log2(rate / 100)), at most 4096: 512 at 44.1 and 48 kHz.
    unsigned target = (unsigned)sampleRate / 100, size = 1;
    while (size < target && size < kMaxFrameSize) {
        size <<= 1;
    }
    return size < 2 ? 2 : size;
}

static unsigned VibeLoudnessLookAhead(double sampleRate) {
    return sampleRate <= 16000 ? 16 : sampleRate <= 32000 ? 32 : sampleRate <= 64000 ? 64 : 128;
}

// The release's weight: how far the gain moves toward a higher target in one
// hop. It scales with the frame and the rate, so its time in seconds holds.
static float VibeLoudnessWeight(const VibeLoudnessEqualizer *stage, int release) {
    float factor = 1.0f;
    int step = 0;
    for (; step < MIN(release, 3); step++) {
        factor *= kReleaseStepFast;
    }
    for (; step < MIN(release, 7); step++) {
        factor *= kReleaseStepSlow;
    }
    return (float)stage->frameSize * (1.0f / 128.0f) * factor * (kReleaseRate / (float)stage->sampleRate);
}

VibeLoudnessEqualizer *VibeLoudnessEqualizerCreate(uint32_t channels, double sampleRate) {
    if (channels < 1 || channels > kVibeLoudnessMaxChannels || !(sampleRate >= 800)) {
        return NULL;
    }
    VibeLoudnessEqualizer *stage = calloc(1, sizeof(VibeLoudnessEqualizer));
    if (!stage) {
        return NULL;
    }
    stage->channels = channels;
    stage->sampleRate = sampleRate;
    unsigned frameSize = VibeLoudnessFrameSize(sampleRate), half = frameSize / 2;
    stage->frameSize = frameSize;
    stage->half = half;
    stage->log2FrameSize = (unsigned)__builtin_ctz(frameSize);
    stage->lookAhead = VibeLoudnessLookAhead(sampleRate);
    stage->fft = vDSP_create_fftsetup(stage->log2FrameSize, kFFTRadix2);

    // The shared tables first, then each channel's state, so a reset clears
    // one span.
    stage->stateCount = (size_t)channels * (4 * half + stage->lookAhead);
    stage->storageCount = 3 * (size_t)frameSize + stage->stateCount + (size_t)channels * half;
    stage->storage = calloc(stage->storageCount, sizeof(float));
    if (!stage->fft || !stage->storage) {
        VibeLoudnessEqualizerFree(stage);
        return NULL;
    }
    // TRAP: vDSP_vclr, never memset. Clang drops a memset(0) after calloc, and
    // the audio thread would take the page faults on its first write.
    vDSP_vclr(stage->storage, 1, stage->storageCount);
    float *cursor = stage->storage;
    stage->window = cursor;
    cursor += frameSize;
    stage->frame = cursor;
    cursor += frameSize;
    stage->split.realp = cursor;
    stage->split.imagp = cursor + half;
    cursor += frameSize;
    stage->state = cursor;
    for (uint32_t c = 0; c < channels; c++) {
        stage->in0[c] = cursor;
        stage->in1[c] = cursor + half;
        stage->out0[c] = cursor + 2 * half;
        stage->out1[c] = cursor + 3 * half;
        stage->delay[c] = cursor + 4 * half;
        cursor += 4 * half + stage->lookAhead;
    }
    for (uint32_t c = 0; c < channels; c++) {
        stage->wet[c] = cursor;
        cursor += half;
    }

    // Each band's bins: from the last band's end to its upper edge's bin, at
    // least one bin, and never past H.
    float binsPerHz = 1.0f / ((float)sampleRate / (float)frameSize);
    stage->edges[0] = 0;
    for (int b = 0; b < kVibeLoudnessBands; b++) {
        unsigned edge = (unsigned)(kBandUpperHz[b] * binsPerHz + 1.0f);
        edge = MAX(edge, stage->edges[b] + 1);
        stage->edges[b + 1] = MIN(edge, half);
    }
    // A raised cosine, scaled so the band powers meet the thresholds.
    for (unsigned n = 0; n < frameSize; n++) {
        double phase = ((double)n + 0.5) / (double)frameSize * 2.0 * M_PI;
        stage->window[n] = (float)((kWindowScale - cos(phase) * kWindowScale) / (double)half);
    }

    stage->limitRise = exp(kLimitRelease / sampleRate);
    stage->limitFall = exp(-kLimitRelease / sampleRate);
    stage->mixStep = 1.0f / (float)MAX(1.0, round(sampleRate * kSwitchSeconds));

    atomic_init(&stage->enabled, 0);
    atomic_init(&stage->release, kVibeLoudnessReleaseDefault);
    atomic_init(&stage->weight, VibeLoudnessWeight(stage, kVibeLoudnessReleaseDefault));
    atomic_init(&stage->engaged, 0);
    atomic_init(&stage->reportGain, 1.0f);
    atomic_init(&stage->reportLimitGain, 1.0f);
    atomic_init(&stage->renders, 0);
    return stage;
}

void VibeLoudnessEqualizerFree(VibeLoudnessEqualizer *stage) {
    if (!stage) {
        return;
    }
    if (stage->fft) {
        vDSP_destroy_fftsetup(stage->fft);
    }
    free(stage->storage);
    free(stage);
}

void VibeLoudnessEqualizerSetEnabled(VibeLoudnessEqualizer *stage, BOOL enabled) {
    atomic_store_explicit(&stage->enabled, enabled ? 1 : 0, memory_order_relaxed);
}

BOOL VibeLoudnessEqualizerEnabled(const VibeLoudnessEqualizer *stage) {
    return atomic_load_explicit(&stage->enabled, memory_order_relaxed) != 0;
}

void VibeLoudnessEqualizerSetRelease(VibeLoudnessEqualizer *stage, int release) {
    release = MAX(kVibeLoudnessReleaseFastest, MIN(kVibeLoudnessReleaseSlowest, release));
    atomic_store_explicit(&stage->release, release, memory_order_relaxed);
    atomic_store_explicit(&stage->weight, VibeLoudnessWeight(stage, release), memory_order_relaxed);
}

int VibeLoudnessEqualizerRelease(const VibeLoudnessEqualizer *stage) {
    return atomic_load_explicit(&stage->release, memory_order_relaxed);
}

uint32_t VibeLoudnessEqualizerChannels(const VibeLoudnessEqualizer *stage) CA_REALTIME_API {
    return stage->channels;
}

double VibeLoudnessEqualizerSampleRate(const VibeLoudnessEqualizer *stage) {
    return stage->sampleRate;
}

BOOL VibeLoudnessEqualizerEngaged(const VibeLoudnessEqualizer *stage) {
    return atomic_load_explicit(&stage->engaged, memory_order_relaxed) != 0;
}

float VibeLoudnessEqualizerGain(const VibeLoudnessEqualizer *stage) {
    return atomic_load_explicit(&stage->reportGain, memory_order_relaxed);
}

float VibeLoudnessEqualizerLimiterGain(const VibeLoudnessEqualizer *stage) {
    return atomic_load_explicit(&stage->reportLimitGain, memory_order_relaxed);
}

uint32_t VibeLoudnessEqualizerLatencyFrames(const VibeLoudnessEqualizer *stage) {
    return VibeLoudnessEqualizerEngaged(stage) ? stage->frameSize + stage->lookAhead : 0;
}

uint64_t VibeLoudnessEqualizerRenders(const VibeLoudnessEqualizer *stage) {
    return atomic_load_explicit(&stage->renders, memory_order_relaxed);
}

#pragma mark - The audio thread

// The calls the compiler cannot check: Accelerate's, and libm's, which carry
// no attributes.
VIBE_REALTIME_UNCHECKED_BEGIN
static inline void VibeLoudnessClear(float *values, size_t count) CA_REALTIME_API {
    vDSP_vclr(values, 1, count);
}

static inline void VibeLoudnessCopy(float *to, const float *from, size_t count) CA_REALTIME_API {
    memcpy(to, from, count * sizeof(float));
}

// One channel's power spectrum over [prev, cur], into stage->frame[0...H].
// vDSP's real FFT gives twice the transform, so each power is a quarter of
// its square; the DC and Nyquist bins arrive packed in bin 0.
static void VibeLoudnessPowerSpectrum(VibeLoudnessEqualizer *stage, const float *prev, const float *cur) CA_REALTIME_API {
    unsigned half = stage->half;
    float *frame = stage->frame;
    vDSP_vmul(prev, 1, stage->window, 1, frame, 1, half);
    vDSP_vmul(cur, 1, stage->window + half, 1, frame + half, 1, half);
    vDSP_ctoz((const DSPComplex *)frame, 2, &stage->split, 1, half);
    vDSP_fft_zrip(stage->fft, &stage->split, 1, stage->log2FrameSize, kFFTDirection_Forward);
    float dc = stage->split.realp[0] * 0.5f, nyquist = stage->split.imagp[0] * 0.5f;
    frame[0] = dc * dc;
    for (unsigned k = 1; k < half; k++) {
        float re = stage->split.realp[k], im = stage->split.imagp[k];
        frame[k] = (re * re + im * im) * 0.25f;
    }
    frame[half] = nyquist * nyquist;
}

static inline float VibeLoudnessFourthRoot(float x) CA_REALTIME_API {
    return (float)sqrt(sqrt((double)x));
}

static inline float VibeLoudnessTargetGain(float loudness) CA_REALTIME_API {
    float target = (float)pow((double)(kTargetLoudness / loudness), kGainExponent);
    return target < kMaxGain ? target : kMaxGain;
}

static inline unsigned VibeLoudnessCeil(float x) CA_REALTIME_API {
    return (unsigned)(long long)ceilf(x);
}
VIBE_REALTIME_END

VIBE_REALTIME_CHECKED_BEGIN
static void VibeLoudnessReset(VibeLoudnessEqualizer *stage) CA_REALTIME_API {
    VibeLoudnessClear(stage->state, stage->stateCount);
    stage->position = 0;
    stage->gain = kMaxGain;
    stage->delayPosition = 0;
    stage->limitGain = 1.0f;
    stage->limitTarget = 1.0f;
    stage->limitStep = 0.0f;
    stage->limitPeak = kLimitThreshold;
    stage->limitCount = 0;
}

// The loudness of a frame: a compressive power law over the bands' power
// above their thresholds.
static float VibeLoudnessOfBands(const float energy[kVibeLoudnessBands]) CA_REALTIME_API {
    float sum = 0.0f;
    for (int b = 0; b < kVibeLoudnessBands; b++) {
        float x = energy[b] - kBandThreshold[b];
        if (!(x > 0.0f)) { // NaN counts as nothing too
            x = kLoudnessFloor;
        }
        sum += VibeLoudnessFourthRoot(x);
    }
    return (float)((double)sum * kLoudnessScale);
}

// A full frame: measure it, move the gain, and finish the older half with a
// linear crossfade from the last gain to this one.
static void VibeLoudnessHop(VibeLoudnessEqualizer *stage) CA_REALTIME_API {
    unsigned half = stage->half;
    float energy[kVibeLoudnessBands] = {0};
    for (uint32_t c = 0; c < stage->channels; c++) {
        VibeLoudnessPowerSpectrum(stage, stage->in0[c], stage->in1[c]);
        for (int b = 0; b < kVibeLoudnessBands; b++) {
            float e = 0.0f;
            for (unsigned k = stage->edges[b]; k < stage->edges[b + 1]; k++) {
                e += stage->frame[k];
            }
            energy[b] += e;
        }
    }
    float target = VibeLoudnessTargetGain(VibeLoudnessOfBands(energy));
    // Down at once, up slowly.
    float last = stage->gain;
    stage->gain = last > target ? target
            : (target - last) * atomic_load_explicit(&stage->weight, memory_order_relaxed) + last;
    float gain = stage->gain, fullHalf = (float)half;
    for (uint32_t c = 0; c < stage->channels; c++) {
        float *prev = stage->in0[c], *cur = stage->in1[c];
        float *finished = stage->out1[c], *next = stage->out0[c];
        for (unsigned n = 0; n < half; n++) {
            finished[n] += prev[n] * (((float)n * gain) / fullHalf);
            next[n] = cur[n] * (((float)(half - n) * gain) / fullHalf);
        }
        stage->in0[c] = cur;
        stage->in1[c] = prev;
        stage->out0[c] = finished;
        stage->out1[c] = next;
    }
    stage->position = 0;
}

// The limiter's gain for the frame leaving the delay, from the peak of the
// frame entering it; negative for a peak no signal reaches.
static float VibeLoudnessLimitGain(VibeLoudnessEqualizer *stage, float peak) CA_REALTIME_API {
    float gain = stage->limitGain, tracked = stage->limitPeak;
    if (peak > tracked) {
        if (peak > kLimitGarbage) {
            return -1.0f;
        }
        float target = kLimitThreshold / peak;
        if (target < gain) {
            float step = (gain - target) / (float)stage->lookAhead;
            if (stage->limitCount == 0) {
                // Down over the look-ahead, reaching the target as the peak leaves.
                stage->limitCount = stage->lookAhead;
                stage->limitStep = step;
            }
            else if (stage->limitTarget < gain - (float)stage->limitCount * step) {
                // The running ramp is steeper: keep it, and run it longer.
                stage->limitCount += VibeLoudnessCeil((stage->limitTarget - target) / stage->limitStep);
            }
            else {
                stage->limitCount = stage->lookAhead;
                stage->limitStep = step;
            }
            stage->limitTarget = target;
        }
        stage->limitPeak = tracked = peak;
    }
    if (stage->limitCount == 0) {
        // Up only once the signal is 6 dB under the tracked peak.
        if (peak + peak <= tracked && gain < 1.0f) {
            gain = (float)((double)gain * stage->limitRise);
            stage->limitPeak = (float)((double)tracked * stage->limitFall);
            if (gain >= 1.0f || stage->limitPeak <= kLimitThreshold) {
                gain = 1.0f;
                stage->limitPeak = kLimitThreshold;
            }
        }
    }
    else {
        gain -= stage->limitStep;
        stage->limitCount--;
    }
    stage->limitGain = gain;
    return gain;
}

static void VibeLoudnessLimit(VibeLoudnessEqualizer *stage, uint32_t frames) CA_REALTIME_API {
    uint32_t channels = stage->channels;
    BOOL drop = NO;
    for (uint32_t i = 0; i < frames; i++) {
        float peak = 0.0f;
        for (uint32_t c = 0; c < channels; c++) {
            float level = __builtin_fabsf(stage->wet[c][i]);
            peak = level > peak ? level : peak;
        }
        float gain = VibeLoudnessLimitGain(stage, peak);
        drop = drop || gain < 0.0f;
        for (uint32_t c = 0; c < channels; c++) {
            float *slot = stage->delay[c] + stage->delayPosition;
            float leaving = *slot;
            *slot = stage->wet[c][i];
            stage->wet[c][i] = leaving * gain;
        }
        if (++stage->delayPosition == stage->lookAhead) {
            stage->delayPosition = 0;
        }
    }
    if (drop) {
        for (uint32_t c = 0; c < channels; c++) {
            VibeLoudnessClear(stage->wet[c], frames);
        }
    }
}

// The dry input and the wet signal, by the switch's share.
static void VibeLoudnessMix(VibeLoudnessEqualizer *stage, float *const *channels, uint32_t offset, uint32_t frames,
                            BOOL wanted) CA_REALTIME_API {
    uint32_t count = stage->channels;
    for (uint32_t i = 0; i < frames; i++) {
        float mix = stage->mix;
        if (!wanted) {
            mix = mix - stage->mixStep > 0.0f ? mix - stage->mixStep : 0.0f;
        }
        else if (stage->warm > 0) {
            stage->warm--;
        }
        else {
            mix = mix + stage->mixStep < 1.0f ? mix + stage->mixStep : 1.0f;
        }
        stage->mix = mix;
        if (mix == 0.0f) {
            continue;
        }
        for (uint32_t c = 0; c < count; c++) {
            float *sample = channels[c] + offset + i;
            float wet = stage->wet[c][i];
            *sample = mix == 1.0f ? wet : *sample + mix * (wet - *sample);
        }
    }
}

void VibeLoudnessEqualizerRender(VibeLoudnessEqualizer *stage, float *const *channels, uint32_t frames) CA_REALTIME_API {
    BOOL wanted = atomic_load_explicit(&stage->enabled, memory_order_relaxed) != 0;
    if (!stage->running) {
        if (!wanted) {
            return;
        }
        VibeLoudnessReset(stage);
        stage->running = YES;
        stage->mix = 0.0f;
        stage->warm = stage->frameSize + stage->lookAhead;
        atomic_store_explicit(&stage->engaged, 1, memory_order_relaxed);
    }
    for (uint32_t done = 0; done < frames; ) {
        uint32_t count = MIN(stage->half - stage->position, frames - done);
        for (uint32_t c = 0; c < stage->channels; c++) {
            VibeLoudnessCopy(stage->wet[c], stage->out0[c] + stage->position, count);
            VibeLoudnessCopy(stage->in1[c] + stage->position, channels[c] + done, count);
        }
        stage->position += count;
        VibeLoudnessLimit(stage, count);
        VibeLoudnessMix(stage, channels, done, count, wanted);
        if (stage->position == stage->half) {
            VibeLoudnessHop(stage);
        }
        done += count;
    }
    atomic_fetch_add_explicit(&stage->renders, 1, memory_order_relaxed);
    if (!wanted && stage->mix == 0.0f) {
        stage->running = NO;
        atomic_store_explicit(&stage->engaged, 0, memory_order_relaxed);
        atomic_store_explicit(&stage->reportGain, 1.0f, memory_order_relaxed);
        atomic_store_explicit(&stage->reportLimitGain, 1.0f, memory_order_relaxed);
        return;
    }
    atomic_store_explicit(&stage->reportGain, stage->gain, memory_order_relaxed);
    atomic_store_explicit(&stage->reportLimitGain, stage->limitGain, memory_order_relaxed);
}
VIBE_REALTIME_END
