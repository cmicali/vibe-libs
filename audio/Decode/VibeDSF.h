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

// The bytes the header takes: the DSD and fmt chunks and the data chunk's header.
enum { kVibeDSFHeaderBytes = 92 };

// DSD's idle pattern, most significant bit first. It averages to zero, as
// silence must. The reads give it outside a channel's samples.
enum { kVibeDSDSilence = 0x69 };

typedef enum {
    VibeDSFVerdictOK,
    VibeDSFVerdictNotDSF,       // no "DSD " chunk at byte 0
    VibeDSFVerdictUnsupported,  // a DSF this reader does not take, such as a rate past DSD512
    VibeDSFVerdictDamaged,      // sizes or counts that cannot hold
} VibeDSFVerdict;

typedef struct {
    uint32_t channelType;   // the fmt chunk's: 1 mono, 2 stereo, 3 L R C, 4 quad, 5 L R C LFE, 6 5.0, 7 5.1
    uint32_t channels;      // 1 to 6, as channelType has
    uint32_t sampleRate;    // DSD samples a second, a channel: 2,822,400 for DSD64
    uint32_t rateMultiple;  // of DSD64's rate, or of 3,072,000 in the 48 kHz family: 1, 2, 4, or 8
    bool lsbFirst;          // the first sample is a byte's least significant bit
    uint64_t sampleCount;   // a channel's, trimmed to the data the file holds
    uint64_t statedSampleCount; // the fmt chunk's, before the trim
    uint32_t blockSize;     // a channel's bytes in a block: 4096
    uint64_t dataOffset;    // where the first block starts
    uint64_t metadataOffset; // the ID3v2 tag's offset, or 0 for none or one past the file
} VibeDSFInfo;

// Reads the header from the file's first `count` bytes, kVibeDSFHeaderBytes
// at least, for a file of `fileLength` bytes. A file cut short keeps the
// samples its data holds.
VibeDSFVerdict VibeDSFParseHeader(const uint8_t *bytes, size_t count, uint64_t fileLength, VibeDSFInfo *info);

// The file offset of channel `channel`'s byte `index`.
uint64_t VibeDSFByteOffset(const VibeDSFInfo *info, uint32_t channel, uint64_t index);

// Reads `count` bytes the file holds at `offset`, into `buffer`. Answers the
// bytes read, short at the file's end, or -1 for a failed read.
typedef ssize_t (*VibeDSFRead)(void *user, uint64_t offset, void *buffer, size_t count);

// Each channel's bytes `first` to `first + count - 1`, most significant bit
// first, into `out[channel]`. A byte before 0 or past the sample count is
// silence, and so are the bits of the last byte past it. One read a block.
// NO for a failed or short read, with `out` partly written.
bool VibeDSFReadChannels(const VibeDSFInfo *info, VibeDSFRead read, void *user, int64_t first, size_t count,
                         uint8_t *const *out);
