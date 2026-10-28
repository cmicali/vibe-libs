//
//  FadeMath.h
//  vibe-libs
//
//  Every fade exists because a gain step at a non-zero sample clicks. The
//  ≤10 ms declick is linear, which keeps its per-sample step small at every
//  rate; a longer fade is equal-power, so the two sides of a crossfade do not
//  dip at the midpoint. audio/Player's voice bus evaluates both per frame on
//  the audio thread. AudioFX's send gates step a log curve on the player queue
//  instead.
//

#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioBaseTypes.h>
#import <math.h>

// The declick length, and the tunable that matters: long enough that no
// transport edge clicks, short enough to feel instant.
static const uint64_t kFadeDurationMilliseconds = 10;

typedef NS_ENUM(int32_t, VibeFadeCurve) {
    VibeFadeCurveLinear = 0,
    VibeFadeCurveEqualPower = 1,
};

// Declick-length fades are linear; every longer fade is one side of a crossfade.
static inline VibeFadeCurve VibeFadeCurveForMilliseconds(uint64_t milliseconds) {
    return milliseconds <= kFadeDurationMilliseconds ? VibeFadeCurveLinear : VibeFadeCurveEqualPower;
}

static inline uint32_t VibeFadeFramesForMilliseconds(uint64_t milliseconds, double sampleRate) {
    return (uint32_t)llround((double)milliseconds * sampleRate / 1000.0);
}

// Computed from the frame index, not accumulated, so the ramp lands on `to`
// exactly.
static inline float VibeFadeGainAtFrame(VibeFadeCurve curve, float from, float to,
                                        uint32_t frame, uint32_t frames) CA_REALTIME_API {
    if (frames == 0 || frame >= frames) {
        return to;
    }
    float t = (float)frame / (float)frames;
    if (curve == VibeFadeCurveEqualPower) {
        float power = from * from * (1.0f - t) + to * to * t;
        return sqrtf(power > 0.0f ? power : 0.0f);
    }
    return from + (to - from) * t;
}

#pragma mark - Stepped fades (AudioFX's send gates)

static const int kFadeSteps = 10;
static const uint64_t kFadeStepMicroseconds = kFadeDurationMilliseconds * 1000 / kFadeSteps;
static const float kFadeFloor = 0.001f; // -60 dB

// Equal multiplicative steps, landing exactly on `to`; the floor keeps the
// log interpolation defined through silence.
static inline float VibeFadeVolumeOverSteps(float from, float to, int step, int totalSteps) {
    if (step >= totalSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)totalSteps);
}
