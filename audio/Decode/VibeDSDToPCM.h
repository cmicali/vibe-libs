//
//  VibeDSDToPCM.h
//  vibe-libs
//
//  DSD to PCM: two linear-phase FIR stages that decimate a DSD stream by 16
//  times its multiple of DSD64, so DSD64, 128, 256, and 512 all come out at
//  176.4 kHz, or at 192 kHz in the 48 kHz family. docs/dsd-to-pcm.md has the
//  measurements and the choices. The first stage takes a DSD byte at a time
//  through tables, down to 352.8 kHz. The second halves that. A full-scale
//  DSD stream is ±1.0, so 0 dB SACD, half of it, is -6 dBFS.
//
//  It reads no file: the caller feeds it each channel's bytes as the file
//  stores them, in the bit order the converter was made for. Feeding is in
//  frames, a frame being the bytes that make one output sample
//  (VibeDSDToPCMBytesPerFrame). Its sums run in one fixed order, so the same
//  bytes give the same samples however they are split into calls.
//

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeDSDToPCM VibeDSDToPCM;

// Each output is centered on the frame fed kVibeDSDToPCMDelayFrames before it.
enum { kVibeDSDToPCMDelayFrames = 26 };

// The frames to feed before frame k, after a reset, so the output for frame
// k on depends on fed bytes alone: the filters' whole span. Feed from frame
// k - kVibeDSDToPCMLeadFrames, and drop the first
// kVibeDSDToPCMLeadFrames + kVibeDSDToPCMDelayFrames outputs.
enum { kVibeDSDToPCMLeadFrames = 27 };

// NULL for no channels or more than 8, a multiple other than 1, 2, 4, or 8,
// or a failed allocation. `lsbFirst` names the bytes' bit order: the first
// sample in the least significant bit. Reset.
VibeDSDToPCM *VibeDSDToPCMCreate(unsigned channels, unsigned multiple, bool lsbFirst);
void VibeDSDToPCMFree(VibeDSDToPCM *converter);

// Clears the filters' history. The outputs it leaves behind are the ones the
// lead drops, so what follows depends on the bytes fed from then on.
void VibeDSDToPCMReset(VibeDSDToPCM *converter);

// A channel's bytes a frame: twice the multiple.
unsigned VibeDSDToPCMBytesPerFrame(const VibeDSDToPCM *converter);

// Feeds `frames` frames of one channel's bytes and writes one sample a
// frame to `out`, `stride` floats apart. Every channel is fed the same frames.
void VibeDSDToPCMProcess(VibeDSDToPCM *converter, unsigned channel, const uint8_t *bytes, size_t frames,
                         float *out, size_t stride);

#ifdef __cplusplus
}
#endif
