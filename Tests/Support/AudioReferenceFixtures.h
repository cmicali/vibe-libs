//
//  AudioReferenceFixtures.h
//  The player's tests
//
//  Fixtures beside the audio files of AudioFileFixtures.h, which it imports.
//  VibeReferenceResample is the one reference conversion. The tone fit both
//  quality measurements share is ToneFit.h's. VibeRangedPCMFormat is a device's offered format, for
//  the bit-perfect format rules. VibeReadWithAVAudioFile decodes through
//  Apple's reader alone.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioFileFixtures.h"
#import "AudioResampler.h"
#import "ToneFit.h"

// A format a device offers at exactly `rate`: stereo PCM of `bits`, integer
// or float.
static inline AudioStreamRangedDescription VibeRangedPCMFormat(double rate, UInt32 bits, BOOL isFloat) {
    AudioStreamRangedDescription r = {0};
    r.mFormat.mSampleRate = rate;
    r.mFormat.mFormatID = kAudioFormatLinearPCM;
    r.mFormat.mFormatFlags = isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger;
    r.mFormat.mBitsPerChannel = bits;
    r.mFormat.mChannelsPerFrame = 2;
    r.mSampleRateRange.mMinimum = rate;
    r.mSampleRateRange.mMaximum = rate;
    return r;
}

// Decode through AVAudioFile without Vibe's handle wrapper. Both paths can
// use Apple's codecs. Returns nil on failure.
static inline AVAudioPCMBuffer *VibeReadWithAVAudioFile(NSURL *url, NSError **error) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:error];
    AVAudioPCMBuffer *whole = file ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                 frameCapacity:(AVAudioFrameCount)file.length] : nil;
    return whole && [file readIntoBuffer:whole error:error] ? whole : nil;
}

typedef struct {
    __unsafe_unretained AVAudioPCMBuffer *source;
    AVAudioFrameCount next;
} VibeReferenceFeed;

static inline uint32_t VibeReferenceSupply(void *userData, uint32_t maxFrames, const float **channels) {
    static float silence[4096];
    VibeReferenceFeed *feed = (VibeReferenceFeed *)userData;
    AVAudioFrameCount left = feed->source.frameLength - feed->next;
    uint32_t count = MIN(maxFrames, 4096u);
    if (left > 0) {
        count = MIN(count, left);
    }
    for (AVAudioChannelCount c = 0; c < feed->source.format.channelCount; c++) {
        channels[c] = left > 0 ? feed->source.floatChannelData[c] + feed->next : silence;
    }
    feed->next += left > 0 ? count : 0;
    return count;
}

// The whole float32 non-interleaved `source` at `rate`: the resampler itself,
// off the bus — no file handle, decoder, ring, render or stream-end logic —
// its tail pushed out with silence and cut at round(N × ratio), as the bus's
// flush does. nil when it cannot convert.
static inline AVAudioPCMBuffer *VibeReferenceResample(AVAudioPCMBuffer *source, double rate) {
    AVAudioChannelCount channels = source.format.channelCount;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    AVAudioFrameCount length = (AVAudioFrameCount)llround((double)source.frameLength * rate / source.format.sampleRate);
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:MAX(length, 1u)];
    VibeResampler *resampler = VibeResamplerCreate(source.format.sampleRate, rate, channels);
    if (!out || !resampler) {
        return nil;
    }
    float **into = (float **)calloc(channels, sizeof(float *));
    VibeReferenceFeed feed = { source, 0 };
    AVAudioFrameCount made = 0;
    while (made < length) {
        for (AVAudioChannelCount c = 0; c < channels; c++) {
            into[c] = out.floatChannelData[c] + made;
        }
        uint32_t frames = VibeResamplerFill(resampler, VibeReferenceSupply, &feed, MIN(length - made, 4096u), into);
        if (frames == 0) {
            break;
        }
        made += frames;
    }
    free(into);
    VibeResamplerDispose(resampler);
    out.frameLength = made;
    return made == length ? out : nil;
}
