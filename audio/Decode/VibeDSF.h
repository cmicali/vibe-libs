//
//  VibeDSF.h
//  vibe-libs
//
//  Sony's DSF container: its header, and the raw DSD bytes of each channel.
//  It reads through the caller's reads and converts nothing, so a PCM
//  conversion (VibeDSDToPCM.h) and a DoP read can share it. Every size and
//  offset in a file is taken as hostile.
//
//  A DSF file is a 28-byte DSD chunk, a 52-byte fmt chunk, and a data chunk,
//  then an optional ID3v2 tag where the DSD chunk points. The data holds each
//  channel's bytes in blocks of 4096, one block of each channel in turn. Each
//  byte holds eight 1-bit samples, the first in its least or its most
//  significant bit, as the fmt chunk says. The sample count trims the last
//  block's padding.
//

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    // The DSD and fmt chunks and the data chunk's header. The data starts here.
    kVibeDSFHeaderBytes = 92,
    // A channel's bytes in a block, the only size the spec allows.
    kVibeDSFBlockBytes = 4096,
    // The most channels a channel type names: 5.1.
    kVibeDSFMaxChannels = 6,
};

// The channels the fmt chunk's channel type names: 1 mono, 2 stereo, 3 L R C,
// 4 quad, 5 L R C LFE, 6 5.0, and 7 5.1. 0 for any other type.
uint32_t VibeDSFChannelsOfType(uint32_t channelType);

typedef struct {
    uint32_t channelType;   // 1 to 7 (VibeDSFChannelsOfType)
    uint32_t channels;      // 1 to kVibeDSFMaxChannels, as channelType names
    uint32_t sampleRate;    // DSD samples a second, a channel: 2,822,400 for DSD64
    uint32_t rateMultiple;  // of DSD64's rate in its family (VibeDSDRateMultiple): 1, 2, 4, or 8
    bool lsbFirst;          // the first sample is a byte's least significant bit
    uint64_t sampleCount;   // a channel's, trimmed to the data the file holds
} VibeDSFInfo;

// Reads the header from the file's first `count` bytes, kVibeDSFHeaderBytes
// at least, for a file of `fileLength` bytes. NO for a file that is no DSF,
// one this reader does not take, such as a rate past DSD512, or one whose
// sizes or counts cannot hold. A file cut short keeps the samples its data
// holds.
bool VibeDSFParseHeader(const uint8_t *bytes, size_t count, uint64_t fileLength, VibeDSFInfo *info);

// The file offset of channel `channel`'s byte `index`.
uint64_t VibeDSFByteOffset(const VibeDSFInfo *info, uint32_t channel, uint64_t index);

// Reads `count` bytes the file holds at `offset`, into `buffer`. Answers the
// bytes read, short at the file's end, or -1 for a failed read.
typedef ssize_t (*VibeDSFRead)(void *user, uint64_t offset, void *buffer, size_t count);

// Each channel's bytes `first` to `first + count - 1`, as the file stores
// them, into `out[channel]`. A byte before 0 or past the sample count is DSD
// silence in the file's bit order, and so are the bits of the last byte past
// it. `scratch` holds what one read takes: as many whole groups of blocks as
// fit in `scratchBytes`, which must hold one group of every channel's block
// at least. NO for a failed or short read, with `out` partly written.
bool VibeDSFReadChannels(const VibeDSFInfo *info, VibeDSFRead read, void *user, int64_t first, size_t count,
                         uint8_t *const *out, uint8_t *scratch, size_t scratchBytes);

#ifdef __cplusplus
}
#endif
