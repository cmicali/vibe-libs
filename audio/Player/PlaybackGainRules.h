//
//  PlaybackGainRules.h
//  vibe-libs
//
//  A gain per file: the linear factor an app's request gives the player, and
//  its conversion from decibels. The player multiplies the file's samples by
//  it on the audio thread, before the pitch, the FX and the volume.
//

#import <Foundation/Foundation.h>
#import <math.h>

NS_ASSUME_NONNULL_BEGIN

// Unity: the file's samples untouched.
static const float kVibeFileGainUnity = 1.0f;

// The most a file is raised: +24 dB. No loudness tag asks for more, and a
// bound keeps a bad tag's sample finite.
static const float kVibeFileGainMaximum = 15.848932f;

// The gain the player applies for a requested one: the request's when it is
// finite and between 0 and kVibeFileGainMaximum, the bound past it, and unity
// for a negative or non-finite one. 0 is silence. A gain above 1 can clip;
// keeping under a file's peak is the app's choice.
static inline float VibeFileGainApplied(float gain) {
    if (!isfinite(gain) || gain < 0) {
        return kVibeFileGainUnity;
    }
    return gain > kVibeFileGainMaximum ? kVibeFileGainMaximum : gain;
}

// Decibels to the linear gain: 10^(dB / 20), held at +24 dB. So 0 dB is 1,
// −6.02 dB is 0.5, and +6.02 dB is 2. A ReplayGain tag's "-7.5 dB" is -7.5
// here. −infinity is silence, and NaN is unity.
static inline float VibeFileGainFromDecibels(double decibels) {
    if (isnan(decibels)) {
        return kVibeFileGainUnity;
    }
    double gain = pow(10.0, decibels / 20.0);
    return gain > kVibeFileGainMaximum ? kVibeFileGainMaximum : (float)gain;
}

// The inverse, for display: 20 · log10(gain). Silence is −infinity.
static inline double VibeFileGainInDecibels(float gain) {
    return gain > 0 ? 20.0 * log10((double)gain) : -INFINITY;
}

NS_ASSUME_NONNULL_END
