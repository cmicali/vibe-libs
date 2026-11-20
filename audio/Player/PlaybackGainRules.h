//
//  PlaybackGainRules.h
//  vibe-libs
//
//  A gain per file: the linear factor an item carries (VibePlayableItem's
//  fileGain), and its conversion from decibels. The player multiplies the
//  file's samples by it on the audio thread, before the pitch, the FX and the
//  volume.
//

#import <Foundation/Foundation.h>
#import <math.h>

#import "VibePlayableItem.h"

NS_ASSUME_NONNULL_BEGIN

// Unity: the file's samples untouched.
static const float kVibeFileGainUnity = 1.0f;

// The ceiling, +40 dB, which keeps a broken value from overflowing a sample.
static const float kVibeFileGainMaximum = 100.0f;

// The one guard: NaN is unity, and the gain is held between 0, silence, and
// the ceiling. Leveling policy, such as a preamp or peak protection, is the
// caller's.
static inline float VibeFileGainApplied(float gain) {
    if (isnan(gain)) {
        return kVibeFileGainUnity;
    }
    return fminf(fmaxf(gain, 0), kVibeFileGainMaximum);
}

// Decibels to the linear gain: 10^(dB / 20). So 0 dB is 1, −6.02 dB is 0.5,
// and a ReplayGain tag's "-7.5 dB" is -7.5 here.
static inline float VibeFileGainFromDecibels(float decibels) {
    return powf(10.0f, decibels / 20.0f);
}

// What the player applies for `item`: its fileGain through the guard, or
// unity for an item that has none.
static inline float VibeFileGainOfItem(id<VibePlayableItem> _Nullable item) {
    return [item respondsToSelector:@selector(fileGain)] ? VibeFileGainApplied(item.fileGain) : kVibeFileGainUnity;
}

// What the player applies for `item` in a file that is DSD or not, with the
// player's dsdGain. A DSD file decodes 0 dB SACD at -6 dBFS
// (docs/dsd-to-pcm.md), so an app may raise it. The DSD gain applies only to
// a DSD file whose item plays at unity: an item that carries a gain of its
// own was leveled already, by a loudness its app measured or read, and
// raising it again would undo that leveling's peak protection.
static inline float VibeFileGainOfItemInFile(id<VibePlayableItem> _Nullable item, BOOL dsd, float dsdGain) {
    float gain = VibeFileGainOfItem(item);
    return dsd && gain == kVibeFileGainUnity ? VibeFileGainApplied(dsdGain) : gain;
}

NS_ASSUME_NONNULL_END
