//
//  VibeDSDToPCM.c
//  vibe-libs
//

#include "VibeDSDToPCM.h"
#include "VibeDSF.h"
#include "VibeDSDFilterTaps.h"

#include <stdlib.h>
#include <string.h>

enum {
    kMaxChannels = 8,
    kSecondTaps = sizeof kVibeDSDSecondStage / sizeof kVibeDSDSecondStage[0],
};
_Static_assert(kSecondTaps == 97, "the delay below assumes 97 taps");

// One channel's history. Each ring is written twice, at i and i + its
// length, so the window ending at the newest entry is always contiguous.
typedef struct {
    uint8_t *bytes;   // 2 × the first stage's bytes
    float first[2 * kSecondTaps];
    unsigned bytePosition;
    unsigned firstPosition;
} VibeDSDChannel;

struct VibeDSDToPCM {
    unsigned channels;
    unsigned multiple;
    unsigned tables;  // the first stage's taps over 8: one table a byte
    float *table;     // tables × 256: each byte value's sum of eight ±taps
    float silence;    // the first stage's output for silence
    float second[kSecondTaps];
    VibeDSDChannel channel[kMaxChannels];
};

static const double *VibeFirstStage(unsigned multiple, unsigned *count) {
    switch (multiple) {
        case 1: *count = sizeof kVibeDSDFirstStage1 / sizeof(double); return kVibeDSDFirstStage1;
        case 2: *count = sizeof kVibeDSDFirstStage2 / sizeof(double); return kVibeDSDFirstStage2;
        case 4: *count = sizeof kVibeDSDFirstStage4 / sizeof(double); return kVibeDSDFirstStage4;
        case 8: *count = sizeof kVibeDSDFirstStage8 / sizeof(double); return kVibeDSDFirstStage8;
        default: *count = 0; return NULL;
    }
}

VibeDSDToPCM *VibeDSDToPCMCreate(unsigned channels, unsigned multiple) {
    unsigned taps;
    const double *first = VibeFirstStage(multiple, &taps);
    if (!first || channels == 0 || channels > kMaxChannels || taps % 8 != 0) {
        return NULL;
    }
    VibeDSDToPCM *converter = calloc(1, sizeof *converter);
    if (!converter) {
        return NULL;
    }
    converter->channels = channels;
    converter->multiple = multiple;
    converter->tables = taps / 8;
    converter->table = malloc(sizeof(float) * converter->tables * 256);
    bool failed = !converter->table;
    for (unsigned c = 0; c < channels && !failed; c++) {
        converter->channel[c].bytes = malloc(2 * converter->tables);
        failed = !converter->channel[c].bytes;
    }
    if (failed) {
        VibeDSDToPCMFree(converter);
        return NULL;
    }
    // Table t is the window's t-th byte, oldest first, its first bit in its
    // most significant. A 1 bit is +1, a 0 bit -1.
    for (unsigned t = 0; t < converter->tables; t++) {
        for (unsigned value = 0; value < 256; value++) {
            double sum = 0;
            for (unsigned bit = 0; bit < 8; bit++) {
                double tap = first[taps - 1 - (8 * t + bit)];
                sum += (value >> (7 - bit)) & 1 ? tap : -tap;
            }
            converter->table[t * 256 + value] = (float)sum;
        }
    }
    double silence = 0;
    for (unsigned t = 0; t < converter->tables; t++) {
        silence += converter->table[t * 256 + kVibeDSDSilence];
    }
    converter->silence = (float)silence;
    for (unsigned i = 0; i < kSecondTaps; i++) {
        converter->second[i] = (float)kVibeDSDSecondStage[kSecondTaps - 1 - i];
    }
    VibeDSDToPCMReset(converter);
    return converter;
}

void VibeDSDToPCMFree(VibeDSDToPCM *converter) {
    if (!converter) {
        return;
    }
    for (unsigned c = 0; c < kMaxChannels; c++) {
        free(converter->channel[c].bytes);
    }
    free(converter->table);
    free(converter);
}

void VibeDSDToPCMReset(VibeDSDToPCM *converter) {
    for (unsigned c = 0; c < converter->channels; c++) {
        VibeDSDChannel *channel = &converter->channel[c];
        memset(channel->bytes, kVibeDSDSilence, 2 * converter->tables);
        for (unsigned i = 0; i < 2 * kSecondTaps; i++) {
            channel->first[i] = converter->silence;
        }
        channel->bytePosition = 0;
        channel->firstPosition = 0;
    }
}

unsigned VibeDSDToPCMBytesPerFrame(const VibeDSDToPCM *converter) {
    return 2 * converter->multiple;
}

// The first stage's next output, after `multiple` more bytes.
static inline float VibeFirstStageStep(const VibeDSDToPCM *converter, VibeDSDChannel *channel, const uint8_t *bytes) {
    unsigned tables = converter->tables;
    for (unsigned i = 0; i < converter->multiple; i++) {
        channel->bytes[channel->bytePosition] = channel->bytes[channel->bytePosition + tables] = bytes[i];
        channel->bytePosition = channel->bytePosition + 1 == tables ? 0 : channel->bytePosition + 1;
    }
    // The oldest byte is at bytePosition now.
    const uint8_t *window = channel->bytes + channel->bytePosition;
    const float *table = converter->table;
    float sum = 0;
    for (unsigned t = 0; t < tables; t++, table += 256) {
        sum += table[window[t]];
    }
    return sum;
}

static inline void VibeFirstStagePush(VibeDSDChannel *channel, float value) {
    channel->first[channel->firstPosition] = channel->first[channel->firstPosition + kSecondTaps] = value;
    channel->firstPosition = channel->firstPosition + 1 == kSecondTaps ? 0 : channel->firstPosition + 1;
}

void VibeDSDToPCMProcess(VibeDSDToPCM *converter, unsigned channel, const uint8_t *bytes, size_t frames,
                         float *out, size_t stride) {
    VibeDSDChannel *state = &converter->channel[channel];
    unsigned multiple = converter->multiple;
    for (size_t f = 0; f < frames; f++, bytes += 2 * multiple) {
        VibeFirstStagePush(state, VibeFirstStageStep(converter, state, bytes));
        VibeFirstStagePush(state, VibeFirstStageStep(converter, state, bytes + multiple));
        const float *window = state->first + state->firstPosition;
        // Four sums, so the adds need not wait on each other.
        float sums[4] = {0, 0, 0, 0};
        unsigned i = 0;
        for (; i + 4 <= kSecondTaps; i += 4) {
            for (unsigned lane = 0; lane < 4; lane++) {
                sums[lane] += converter->second[i + lane] * window[i + lane];
            }
        }
        for (; i < kSecondTaps; i++) {
            sums[0] += converter->second[i] * window[i];
        }
        out[f * stride] = (sums[0] + sums[1]) + (sums[2] + sums[3]);
    }
}
