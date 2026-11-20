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
//  It reads no file: the caller feeds it each channel's bytes, most
//  significant bit first (VibeDSF.h). Feeding is in frames, a frame being
//  the bytes that make one output sample (VibeDSDToPCMBytesPerFrame).
//

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct VibeDSDToPCM VibeDSDToPCM;

// The output that the frame fed first lands on, after a reset: each output
// is centered on the frame fed kVibeDSDToPCMDelayFrames before it.
enum { kVibeDSDToPCMDelayFrames = 26 };

// The frames to feed before frame k, after a reset, so the output for frame
// k on depends on fed bytes alone: the filters' whole span. Feed from frame
// k - kVibeDSDToPCMLeadFrames, and drop the first
// kVibeDSDToPCMLeadFrames + kVibeDSDToPCMDelayFrames outputs.
enum { kVibeDSDToPCMLeadFrames = 27 };

// NULL for a channel count past 8, a multiple other than 1, 2, 4, or 8, or a
// failed allocation. Reset.
VibeDSDToPCM *VibeDSDToPCMCreate(unsigned channels, unsigned multiple);
void VibeDSDToPCMFree(VibeDSDToPCM *converter);

// As if silence had been fed forever: the state any seek starts from.
void VibeDSDToPCMReset(VibeDSDToPCM *converter);

// A channel's bytes a frame: twice the multiple.
unsigned VibeDSDToPCMBytesPerFrame(const VibeDSDToPCM *converter);

// Feeds `frames` frames of one channel's bytes and writes one sample a
// frame to `out`, `stride` floats apart. Every channel is fed the same frames.
void VibeDSDToPCMProcess(VibeDSDToPCM *converter, unsigned channel, const uint8_t *bytes, size_t frames,
                         float *out, size_t stride);
