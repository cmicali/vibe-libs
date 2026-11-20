//
//  OutputFormatRules.h
//  vibe-libs
//
//  The output device layer's decisions, as static inlines so the host-less
//  suite reaches them without a HAL: whether a device is gone, then
//  bit-perfect output's — what a source's word length is, which of a
//  device's formats carries it unchanged, and whether a device may be driven
//  at all. The mechanism they serve is a player, which binds a device and
//  drives bit-perfect output. audio/Player keeps the report those reasons
//  fold into, and when a saved device may bind.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/AudioHardwareBase.h>
#include <math.h>

// Whether a direct HAL read of kAudioDevicePropertyDeviceIsAlive proves the
// device is gone: it answered "dead", or the object itself no longer exists.
// Any other failed read is UNKNOWN, never dead — a false removal falls back to
// System Output and persists it, which is why absence alone is never removal.
static inline BOOL VibeDeviceIsConfirmedDead(OSStatus readStatus, UInt32 isAlive) {
    if (readStatus == kAudioHardwareBadObjectError) {
        return YES;
    }
    return readStatus == noErr && isAlive == 0;
}

// The prepared stream owns the selected output channels. Extra device
// channels are harmless only when the live AU map sends them silence.
static inline BOOL VibeBitPerfectChannelMapPreservesSource(const SInt32 *map, UInt32 count,
        UInt32 sourceChannels, UInt32 firstStreamChannel, UInt32 streamChannels) {
    if (!map || sourceChannels == 0 || firstStreamChannel == 0
            || sourceChannels > streamChannels || firstStreamChannel > count
            || streamChannels > count - (firstStreamChannel - 1)) return NO;
    UInt32 start = firstStreamChannel - 1; // HAL stream channels are one-based
    for (UInt32 destination = 0; destination < count; destination++) {
        SInt32 expected = destination >= start && destination - start < sourceChannels
                ? (SInt32)(destination - start) : -1;
        if (map[destination] != expected) return NO;
    }
    return YES;
}

static const UInt32 kVibeBitPerfectAssumedLosslessDepth = 24;

// PCM: mBitsPerChannel. ALAC, FLAC, and Monkey's Audio ('APE ', audio/Decode's
// ID, which this piece cannot import): the kAppleLosslessFormatFlag_*
// source-depth flags, or 24 assumed when the flags say nothing. Lossy and
// unknown: 0, meaning no native depth to honor. The fold's SourceLossy is that
// 0, so the chooser and the report cannot disagree about a file.
static inline UInt32 VibeSourceBitDepth(AudioStreamBasicDescription source) {
    if (source.mFormatID == kAudioFormatLinearPCM) {
        return source.mBitsPerChannel;
    }
    if (source.mFormatID == kAudioFormatAppleLossless || source.mFormatID == kAudioFormatFLAC
            || source.mFormatID == 'APE ') {
        switch (source.mFormatFlags) {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16;
            case kAppleLosslessFormatFlag_20BitSourceData: return 20;
            case kAppleLosslessFormatFlag_24BitSourceData: return 24;
            case kAppleLosslessFormatFlag_32BitSourceData: return 32;
            default: return kVibeBitPerfectAssumedLosslessDepth;
        }
    }
    return 0;
}

static inline BOOL VibePhysicalFormatIsFloat(AudioStreamBasicDescription format) {
    return (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

// A source is asked the PCM question only when it is PCM: the ALAC and FLAC
// depth flags reuse the same low bits.
static inline BOOL VibeSourceIsFloat(AudioStreamBasicDescription source) {
    return source.mFormatID == kAudioFormatLinearPCM && VibePhysicalFormatIsFloat(source);
}

// Whether one PCM format carries `source`'s samples unchanged: the same
// representation at no less width — a float source needs a float format at
// least as wide, an integer source an integer depth >= its own or a float
// significand that holds it (float32's is 24 bits, float64's 53). A lossy
// source (depth 0) is carried by anything.
static inline BOOL VibePCMFormatCarries(AudioStreamBasicDescription pcm,
                                        AudioStreamBasicDescription source) {
    if (pcm.mFormatID != kAudioFormatLinearPCM) return NO;
    if (VibeSourceIsFloat(source)) {
        return VibePhysicalFormatIsFloat(pcm) && pcm.mBitsPerChannel >= source.mBitsPerChannel;
    }
    UInt32 carried = pcm.mBitsPerChannel;
    if (VibePhysicalFormatIsFloat(pcm)) {
        carried = (pcm.mBitsPerChannel == 32) ? 24 : (pcm.mBitsPerChannel == 64) ? 53 : 0;
    }
    return carried >= VibeSourceBitDepth(source);
}

// YES when the path delivers `source` unchanged: the device at the source's
// rate, and both the decode's processing format (AudioFileHandle decodes to
// float32, so a 32-bit integer source is never delivered in full, whatever
// the device offers) and the device's physical format carry it. The report's
// depth check, not the chooser's preference.
static inline BOOL VibePhysicalFormatSatisfies(AudioStreamBasicDescription physical,
                                               AudioStreamBasicDescription source,
                                               AudioStreamBasicDescription processing) {
    return physical.mSampleRate == source.mSampleRate
            && VibePCMFormatCarries(processing, source)
            && VibePCMFormatCarries(physical, source);
}

// Whether the mode may drive a chosen device: its transport carries bits
// unchanged — an ALLOWLIST, so anything Apple adds later is out until argued
// in. The System Output policy (-1) is the absence of a chosen device; the
// device that happens to be the default is judged by its transport like any
// other. The switch, an app's device list, and the report all read it, so
// they cannot disagree. allowAnyDevice is a testing override. It bypasses only
// the transport.
static inline BOOL VibeBitPerfectDeviceEligible(UInt32 transportType, BOOL allowAnyDevice) {
    if (allowAnyDevice) return YES;
    switch (transportType) {
        case kAudioDeviceTransportTypeBuiltIn:
        case kAudioDeviceTransportTypePCI:
        case kAudioDeviceTransportTypeUSB:
        case kAudioDeviceTransportTypeFireWire:
        case kAudioDeviceTransportTypeThunderbolt:
        case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort:
        case kAudioDeviceTransportTypeAVB:
        case kAudioDeviceTransportTypeVirtual:
            return YES;
        default:
            return NO;
    }
}

static inline BOOL VibeRangedFormatOffersRate(AudioStreamRangedDescription format, double rate) {
    if (format.mFormat.mSampleRate == rate) {
        return YES;
    }
    return format.mSampleRateRange.mMinimum <= rate && rate <= format.mSampleRateRange.mMaximum;
}

// The rate rule: exact PCM carrying every source channel, else the smallest
// such integer multiple, else 0. A narrow offer cannot hide a usable rate.
static inline double VibeBitPerfectTargetRate(double sourceRate, UInt32 sourceChannels,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count) {
    if (!isfinite(sourceRate) || sourceRate <= 0) {
        return 0;
    }
    double target = 0;
    for (UInt32 i = 0; i < count; i++) {
        if (formats[i].mFormat.mFormatID != kAudioFormatLinearPCM
                || formats[i].mFormat.mChannelsPerFrame < sourceChannels) continue;
        // Discrete rates and continuous ranges both contribute their smallest
        // integral ratio. Scanning the offers also covers 3x, 6x and ratios
        // above 16x without an arbitrary search ceiling.
        double candidates[] = { formats[i].mFormat.mSampleRate,
            sourceRate * MAX(1.0, ceil(formats[i].mSampleRateRange.mMinimum / sourceRate)) };
        for (unsigned j = 0; j < 2; j++) {
            double rate = candidates[j];
            if (isfinite(rate) && rate >= sourceRate && fmod(rate, sourceRate) == 0
                    && VibeRangedFormatOffersRate(formats[i], rate)
                    && (target == 0 || rate < target)) {
                target = rate;
            }
        }
    }
    return target;
}

static inline BOOL VibePhysicalFormatsEquivalent(AudioStreamBasicDescription a,
                                                 AudioStreamBasicDescription b) {
    return a.mSampleRate == b.mSampleRate
            && a.mFormatID == b.mFormatID
            && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket
            && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mChannelsPerFrame == b.mChannelsPerFrame;
}

// Shared by the silent settlement and the gapless gate: even an unchanged
// device needs a rebuild when the bus would resample into it.
static inline BOOL VibeBitPerfectOutputNeedsSwitch(AudioStreamBasicDescription current,
                                                   AudioStreamBasicDescription chosen,
                                                   double mixerRate) {
    return !VibePhysicalFormatsEquivalent(current, chosen) || mixerRate != chosen.mSampleRate;
}

// The depth rule at `rate`, as-is. This piece's AGENTS.md says why. The
// integer pick is the widest integer depth not below the source's, and the
// float pick the widest float. An integer source takes the integer pick. A
// float or lossy source takes the float pick first, since only a float format
// carries a float decode unchanged. Only formats wide enough for all source
// channels qualify. Returns NO when none is usable at `rate`. The caller
// compares the choice against what the device has before writing.
static inline BOOL VibeBitPerfectChooseFormat(AudioStreamBasicDescription source,
                                              double rate,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count,
                                              AudioStreamBasicDescription *chosen) {
    UInt32 depth = VibeSourceBitDepth(source);
    AudioStreamBasicDescription integerPick = {0}, floatPick = {0};
    for (UInt32 i = 0; i < count; i++) {
        if (!VibeRangedFormatOffersRate(formats[i], rate)
                || formats[i].mFormat.mFormatID != kAudioFormatLinearPCM
                || formats[i].mFormat.mChannelsPerFrame < source.mChannelsPerFrame) {
            continue;
        }
        AudioStreamBasicDescription candidate = formats[i].mFormat;
        candidate.mSampleRate = rate;
        BOOL isFloat = VibePhysicalFormatIsFloat(candidate);
        if (!isFloat && candidate.mBitsPerChannel < depth) {
            continue; // never below the source
        }
        AudioStreamBasicDescription *pick = isFloat ? &floatPick : &integerPick;
        if (candidate.mBitsPerChannel > pick->mBitsPerChannel) {
            *pick = candidate;
        }
    }
    BOOL haveInteger = integerPick.mBitsPerChannel > 0, haveFloat = floatPick.mBitsPerChannel > 0;
    if (!haveInteger && !haveFloat) {
        return NO;
    }
    BOOL preferFloat = (VibeSourceIsFloat(source) || depth == 0) ? haveFloat : !haveInteger;
    *chosen = preferFloat ? floatPick : integerPick;
    return YES;
}
