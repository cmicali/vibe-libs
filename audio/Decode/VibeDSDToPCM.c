//
//  VibeDSDToPCM.c
//  vibe-libs
//

#include "VibeDSDToPCM.h"
#include "VibeDSDFilterTaps.h"

#include <stdlib.h>
#include <string.h>

enum {
    kMaxChannels = 8,
    kSecondTaps = sizeof kVibeDSDSecondStage / sizeof kVibeDSDSecondStage[0],
    kSecondHistory = kSecondTaps - 1,
    kSecondHalf = kSecondTaps / 2,
    // The frames one pass of Process converts, so its buffers stay small.
    kPassFrames = 1024,
};
_Static_assert(kSecondTaps == 97, "the delay assumes 97 taps, centered on one");
_Static_assert(kSecondHalf % 4 == 0, "the folded sum runs in four lanes");

struct VibeDSDToPCM {
    unsigned channels;
    unsigned multiple;
    unsigned tables;      // the first stage's taps over 8: one table a byte of its window
    float *table;         // tables × 256: each byte value's sum of eight ±taps
    float second[kSecondHalf + 1]; // the second stage, folded: each tap pair, then the center
    uint8_t *byteHistory; // a channel's last tables - 1 bytes, after another
    float *firstHistory;  // a channel's last kSecondHistory first-stage outputs, after another
    uint8_t *bytes;       // a pass's window: the history, then the pass's bytes
    float *first;         // a pass's first-stage outputs, after their history
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

VibeDSDToPCM *VibeDSDToPCMCreate(unsigned channels, unsigned multiple, bool lsbFirst) {
    unsigned taps;
    const double *first = VibeFirstStage(multiple, &taps);
    if (!first || channels == 0 || channels > kMaxChannels || taps % 32 != 0) {
        return NULL; // 32: whole bytes, summed in four lanes
    }
    VibeDSDToPCM *converter = calloc(1, sizeof *converter);
    if (!converter) {
        return NULL;
    }
    converter->channels = channels;
    converter->multiple = multiple;
    converter->tables = taps / 8;
    converter->table = malloc(sizeof(float) * converter->tables * 256);
    converter->byteHistory = malloc((size_t)channels * (converter->tables - 1));
    converter->firstHistory = malloc(sizeof(float) * channels * kSecondHistory);
    converter->bytes = malloc(converter->tables - 1 + (size_t)kPassFrames * 2 * multiple);
    converter->first = malloc(sizeof(float) * (kSecondHistory + 2 * kPassFrames));
    if (!converter->table || !converter->byteHistory || !converter->firstHistory || !converter->bytes || !converter->first) {
        VibeDSDToPCMFree(converter);
        return NULL;
    }
    // Table t is the window's t-th byte, oldest first. Its first sample is its
    // most significant bit, or its least for lsbFirst, so a file's bytes
    // index it as stored. A 1 bit is +1, a 0 bit -1.
    for (unsigned t = 0; t < converter->tables; t++) {
        for (unsigned value = 0; value < 256; value++) {
            double sum = 0;
            for (unsigned bit = 0; bit < 8; bit++) {
                double tap = first[taps - 1 - (8 * t + bit)];
                unsigned shift = lsbFirst ? bit : 7 - bit;
                sum += (value >> shift) & 1 ? tap : -tap;
            }
            converter->table[t * 256 + value] = (float)sum;
        }
    }
    // The second stage is symmetric, so each pair of samples shares a tap.
    for (unsigned i = 0; i <= kSecondHalf; i++) {
        converter->second[i] = (float)kVibeDSDSecondStage[i];
    }
    VibeDSDToPCMReset(converter);
    return converter;
}

void VibeDSDToPCMFree(VibeDSDToPCM *converter) {
    if (!converter) {
        return;
    }
    free(converter->table);
    free(converter->byteHistory);
    free(converter->firstHistory);
    free(converter->bytes);
    free(converter->first);
    free(converter);
}

void VibeDSDToPCMReset(VibeDSDToPCM *converter) {
    memset(converter->byteHistory, 0, (size_t)converter->channels * (converter->tables - 1));
    memset(converter->firstHistory, 0, sizeof(float) * converter->channels * kSecondHistory);
}

unsigned VibeDSDToPCMBytesPerFrame(const VibeDSDToPCM *converter) {
    return 2 * converter->multiple;
}

// The first stage's output for the window of `tables` bytes at `window`, in
// four lanes summed in a fixed order.
static inline float VibeFirstStageSum(const float *table, const uint8_t *window, unsigned tables) {
    float lanes[4] = {0, 0, 0, 0};
    for (unsigned t = 0; t < tables; t += 4) {
        for (unsigned lane = 0; lane < 4; lane++) {
            lanes[lane] += table[(t + lane) * 256 + window[t + lane]];
        }
    }
    return (lanes[0] + lanes[1]) + (lanes[2] + lanes[3]);
}

// The second stage's output for the kSecondTaps samples at `window`, folded
// around its center, in four lanes summed in a fixed order.
static inline float VibeSecondStageSum(const float *second, const float *window) {
    float lanes[4] = {0, 0, 0, 0};
    for (unsigned i = 0; i < kSecondHalf; i += 4) {
        for (unsigned lane = 0; lane < 4; lane++) {
            unsigned at = i + lane;
            lanes[lane] += second[at] * (window[at] + window[kSecondHistory - at]);
        }
    }
    return ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3])) + second[kSecondHalf] * window[kSecondHalf];
}

void VibeDSDToPCMProcess(VibeDSDToPCM *converter, unsigned channel, const uint8_t *bytes, size_t frames,
                         float *out, size_t stride) {
    const unsigned multiple = converter->multiple, tables = converter->tables, history = tables - 1;
    uint8_t *byteHistory = converter->byteHistory + (size_t)channel * history;
    float *firstHistory = converter->firstHistory + (size_t)channel * kSecondHistory;
    while (frames > 0) {
        size_t pass = frames < kPassFrames ? frames : kPassFrames, fed = pass * 2 * multiple;
        memcpy(converter->bytes, byteHistory, history);
        memcpy(converter->bytes + history, bytes, fed);
        memcpy(converter->first, firstHistory, sizeof(float) * kSecondHistory);
        // First-stage output i ends its window at the pass's byte (i + 1) ×
        // multiple - 1, so the window starts there, history counted.
        for (size_t i = 0; i < 2 * pass; i++) {
            converter->first[kSecondHistory + i] = VibeFirstStageSum(converter->table, converter->bytes + (i + 1) * multiple - 1, tables);
        }
        // Output j's window ends at first-stage output 2j + 1.
        for (size_t j = 0; j < pass; j++) {
            out[j * stride] = VibeSecondStageSum(converter->second, converter->first + 2 * j + 1);
        }
        memcpy(byteHistory, converter->bytes + fed, history);
        memcpy(firstHistory, converter->first + 2 * pass, sizeof(float) * kSecondHistory);
        bytes += fed;
        out += pass * stride;
        frames -= pass;
    }
}
