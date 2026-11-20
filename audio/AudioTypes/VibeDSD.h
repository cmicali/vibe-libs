//
//  VibeDSD.h
//  vibe-libs
//
//  The DSD rates the toolbox plays, and DSD's idle pattern. Plain C, so the
//  DSF parser and the converter in audio/Decode include it, and an app names
//  a rate from it ("DSD64") as the decode would take it.
//

#pragma once

#include <stdint.h>

// DSD64's rate in each family, a channel's samples a second: 64 times 44.1
// kHz, and 64 times 48 kHz.
#define kVibeDSD64Rate 2822400.0
#define kVibeDSD64Rate48k 3072000.0

// DSD's idle pattern, most significant bit first. It averages to zero, as
// silence must. A file stored least significant bit first holds it reversed.
enum { kVibeDSDSilence = 0x69 };

// The multiple of DSD64 that `hertz` is, in either family: 1, 2, 4, or 8, for
// DSD64 to DSD512. 0 for any other rate, which the decode refuses.
static inline uint32_t VibeDSDRateMultiple(double hertz) {
    for (uint32_t multiple = 1; multiple <= 8; multiple *= 2) {
        if (hertz == kVibeDSD64Rate * multiple || hertz == kVibeDSD64Rate48k * multiple) {
            return multiple;
        }
    }
    return 0;
}
