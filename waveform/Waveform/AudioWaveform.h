//
//  AudioWaveform.h
//  vibe-libs
//

#import <Foundation/Foundation.h>
#include <Accelerate/Accelerate.h>
#include <memory>

#include "WaveformSummary.hpp"

// The waveform summary, BPM and key analyzers share one mono mix per buffer.
// For mono input it returns the buffer itself, with no copy. Otherwise it
// averages the channels, which are interleaved as L0 R0 L1 R1 and so on, into
// scratch, and returns scratch. scratch must hold numFrames floats.
static inline const float* AudioWaveformMonoMix(const float* buffer, float* scratch,
                                                NSUInteger numFrames, NSUInteger channels) {
    if (channels <= 1) {
        return buffer;
    }
    // vDSP_vasm rounds the sum before scaling it.
    float scale = 1.0f / (float)channels;
    if (channels == 2) {
        vDSP_vasm(buffer, 2, buffer + 1, 2, &scale, scratch, 1, numFrames);
        return scratch;
    }
    vDSP_vadd(buffer, (vDSP_Stride)channels, buffer + 1, (vDSP_Stride)channels, scratch, 1, numFrames);
    for (NSUInteger ch = 2; ch + 1 < channels; ch++) {
        vDSP_vadd(scratch, 1, buffer + ch, (vDSP_Stride)channels, scratch, 1, numFrames);
    }
    vDSP_vasm(scratch, 1, buffer + channels - 1, (vDSP_Stride)channels, &scale, scratch, 1, numFrames);
    return scratch;
}

// The waveform is this piece's summary: peaks and energy in bins of fixed
// time, read through its pyramid.
typedef wavecore::Summary AudioWaveform;

// The entry-format version. It is encoded in every archive and kept on each
// entry's row in AudioWaveformCache's store, so a row of another format is a
// miss and a decode replaces it. Bump it to invalidate every cached entry, as
// after a format change. A changed observer needs no bump: it takes a new identifier
// (AudioWaveformObserver.h). Mismatched entries simply regenerate.
extern const int kCodableAudioWaveformVersion;

@interface CodableAudioWaveform : NSObject <NSCoding>

// Owned: freed with the wrapper.
@property (nonatomic, readonly) AudioWaveform *waveform;

// Each observer's result, a property-list object, by its identifier
// (AudioWaveformObserver.h). They share the summary's decode, key and
// lifecycle. An observer the decode did not run has no result, so a request
// that lists it misses and decodes again.
@property (nonatomic, copy) NSDictionary<NSString *, id> *results;

// The cache's entry key it was read or decoded under, so its results name
// the version of the file they hold (VibeWaveformEntryKey). Set by
// AudioWaveformCache, held in memory only, and never archived. nil
// elsewhere.
@property (nonatomic, copy) NSString *entryKey;

// Takes ownership.
- (instancetype)initWithWaveform:(std::unique_ptr<AudioWaveform>)waveform;

@end
