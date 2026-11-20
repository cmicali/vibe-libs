//
//  DSFFixtures.h
//  vibe-libs
//
//  DSF files written here, from a delta-sigma modulator of the tests' own, so
//  no recording is kept. VibeDSFFile modulates a signal into a file of any
//  channel type, DSD rate, and bit order, with a tag at its end when given
//  (AudioFileFixtures.h's VibeID3v2Tag makes one). docs/dsd-to-pcm.md has the
//  modulator's design.
//

#import <Foundation/Foundation.h>

#include <math.h>

#import "VibeDSD.h"
#import "VibeDSF.h"

// The value of channel `channel` at `seconds`, in -1 to 1. Half of full scale
// is 0 dB SACD.
typedef double (^VibeDSFSignal)(uint32_t channel, double seconds);

// One channel modulated, most significant bit first: a fifth-order
// error-feedback modulator whose noise transfer function has five zeros at DC
// and Butterworth poles, its out-of-band gain held to 1.5 so it stays stable
// for a signal up to half of full scale.
static inline void VibeDSDModulate(VibeDSFSignal signal, uint32_t channel, double rate, uint64_t samples, uint8_t *out) {
    static const double b[6] = {1, -5, 10, -10, 5, -1};
    static const double a[6] = {1, -4.1922821511385058, 7.0857914157082877, -6.0296073835111077,
                                2.5812079389633515, -0.44444444401209632};
    double e[6] = {0}, w[6] = {0};
    for (uint64_t i = 0; i < samples; i++) {
        double feedback = 0;
        for (int k = 1; k <= 5; k++) {
            feedback += (b[k] - a[k]) * e[k] - a[k] * w[k];
        }
        double v = signal(channel, (double)i / rate) + feedback, y = v >= 0 ? 1 : -1;
        for (int k = 5; k > 1; k--) {
            e[k] = e[k - 1];
            w[k] = w[k - 1];
        }
        e[1] = y - v;
        w[1] = feedback;
        if (i % 8 == 0) {
            out[i / 8] = 0;
        }
        if (y > 0) {
            out[i / 8] |= (uint8_t)(0x80 >> (i % 8));
        }
    }
}

static inline void VibeDSFAppendLE(NSMutableData *data, uint64_t value, int bytes) {
    for (int i = 0; i < bytes; i++) {
        uint8_t byte = (uint8_t)(value >> (8 * i));
        [data appendBytes:&byte length:1];
    }
}

// A DSF of `samples` samples a channel at `rateMultiple` times `baseRate`
// (kVibeDSD64Rate or kVibeDSD64Rate48k), with `tag` at its end when given. The last
// block's padding is zeros, as the spec has it.
static inline NSData *VibeDSFFileAtRate(uint32_t channelType, double baseRate, uint32_t rateMultiple, BOOL lsbFirst,
                                        uint64_t samples, VibeDSFSignal signal, NSData *tag) {
    enum { kBlock = kVibeDSFBlockBytes };
    uint32_t channels = VibeDSFChannelsOfType(channelType);
    double rate = baseRate * rateMultiple;
    uint64_t bytes = (samples + 7) / 8, blocks = (bytes + kBlock - 1) / kBlock;
    uint64_t dataBytes = blocks * channels * kBlock;
    NSMutableData *planes = [NSMutableData dataWithLength:(NSUInteger)(blocks * kBlock * channels)];
    for (uint32_t c = 0; c < channels; c++) {
        uint8_t *plane = (uint8_t *)planes.mutableBytes + c * blocks * kBlock;
        VibeDSDModulate(signal, c, rate, samples, plane);
        if (samples % 8) {
            plane[bytes - 1] &= (uint8_t)(0xFF << (8 - samples % 8));
        }
        if (lsbFirst) {
            for (uint64_t i = 0; i < bytes; i++) {
                plane[i] = __builtin_bitreverse8(plane[i]);
            }
        }
    }
    uint64_t audioEnd = 92 + dataBytes;
    NSMutableData *file = [NSMutableData data];
    [file appendBytes:"DSD " length:4];
    VibeDSFAppendLE(file, 28, 8);
    VibeDSFAppendLE(file, audioEnd + tag.length, 8);
    VibeDSFAppendLE(file, tag.length ? audioEnd : 0, 8);
    [file appendBytes:"fmt " length:4];
    VibeDSFAppendLE(file, 52, 8);
    VibeDSFAppendLE(file, 1, 4); // version
    VibeDSFAppendLE(file, 0, 4); // raw DSD
    VibeDSFAppendLE(file, channelType, 4);
    VibeDSFAppendLE(file, channels, 4);
    VibeDSFAppendLE(file, (uint64_t)rate, 4);
    VibeDSFAppendLE(file, lsbFirst ? 1 : 8, 4);
    VibeDSFAppendLE(file, samples, 8);
    VibeDSFAppendLE(file, kBlock, 4);
    VibeDSFAppendLE(file, 0, 4);
    [file appendBytes:"data" length:4];
    VibeDSFAppendLE(file, 12 + dataBytes, 8);
    const uint8_t *source = (const uint8_t *)planes.bytes;
    for (uint64_t block = 0; block < blocks; block++) {
        for (uint32_t c = 0; c < channels; c++) {
            [file appendBytes:source + (c * blocks + block) * kBlock length:kBlock];
        }
    }
    if (tag) {
        [file appendData:tag];
    }
    return file;
}

static inline NSData *VibeDSFFile(uint32_t channelType, uint32_t rateMultiple, BOOL lsbFirst, uint64_t samples,
                                  VibeDSFSignal signal, NSData *tag) {
    return VibeDSFFileAtRate(channelType, kVibeDSD64Rate, rateMultiple, lsbFirst, samples, signal, tag);
}

// A sine at `frequency` and `amplitude` on every channel.
static inline VibeDSFSignal VibeDSFSine(double frequency, double amplitude) {
    VibeDSFSignal sine = ^double(uint32_t channel, double seconds) {
        (void)channel;
        return amplitude * sin(2 * M_PI * frequency * seconds);
    };
    return [sine copy];
}
