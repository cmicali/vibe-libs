//
//  VibeDSF.c
//  vibe-libs
//

#include "VibeDSF.h"

#include <string.h>

static uint32_t VibeLE32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint64_t VibeLE64(const uint8_t *bytes) {
    return (uint64_t)VibeLE32(bytes) | (uint64_t)VibeLE32(bytes + 4) << 32;
}

VibeDSFVerdict VibeDSFParseHeader(const uint8_t *bytes, size_t count, uint64_t fileLength, VibeDSFInfo *info) {
    // The channels each channel type names.
    static const uint32_t kTypeChannels[8] = {0, 1, 2, 3, 4, 4, 5, 6};
    memset(info, 0, sizeof *info);
    if (count < 4 || memcmp(bytes, "DSD ", 4) != 0) {
        return VibeDSFVerdictNotDSF;
    }
    if (count < kVibeDSFHeaderBytes || fileLength < kVibeDSFHeaderBytes || VibeLE64(bytes + 4) != 28
            || memcmp(bytes + 28, "fmt ", 4) != 0 || VibeLE64(bytes + 32) != 52 || memcmp(bytes + 80, "data", 4) != 0) {
        return VibeDSFVerdictDamaged;
    }
    const uint8_t *fmt = bytes + 40;
    uint32_t version = VibeLE32(fmt), formatID = VibeLE32(fmt + 4);
    info->channelType = VibeLE32(fmt + 8);
    info->channels = VibeLE32(fmt + 12);
    info->sampleRate = VibeLE32(fmt + 16);
    uint32_t bits = VibeLE32(fmt + 20);
    info->statedSampleCount = VibeLE64(fmt + 24);
    info->blockSize = VibeLE32(fmt + 32);
    if (version != 1 || formatID != 0) {
        return VibeDSFVerdictUnsupported; // formatID 0 is raw DSD, the only one the spec defines
    }
    if (info->channelType == 0 || info->channelType > 7 || info->channels != kTypeChannels[info->channelType]
            || (bits != 1 && bits != 8) || info->blockSize != 4096) {
        return VibeDSFVerdictDamaged;
    }
    info->lsbFirst = bits == 1;
    for (uint32_t multiple = 1; multiple <= 8; multiple *= 2) {
        if (info->sampleRate == 2822400u * multiple || info->sampleRate == 3072000u * multiple) {
            info->rateMultiple = multiple;
        }
    }
    if (info->rateMultiple == 0) {
        return VibeDSFVerdictUnsupported;
    }
    // The data chunk's size counts its 12-byte header. A file cut short holds
    // less than it states.
    uint64_t chunk = VibeLE64(bytes + 84);
    if (chunk < 12) {
        return VibeDSFVerdictDamaged;
    }
    info->dataOffset = kVibeDSFHeaderBytes;
    uint64_t data = chunk - 12;
    if (data > fileLength - kVibeDSFHeaderBytes) {
        data = fileLength - kVibeDSFHeaderBytes;
    }
    // Each channel's bytes: every whole group of blocks, then the last
    // channel's part of the group the data ends in, which is the least.
    uint64_t group = (uint64_t)info->channels * info->blockSize;
    uint64_t rest = data % group, last = (uint64_t)(info->channels - 1) * info->blockSize;
    uint64_t held = data / group * info->blockSize + (rest > last ? rest - last : 0);
    uint64_t heldSamples = held > UINT64_MAX / 8 ? UINT64_MAX : held * 8;
    info->sampleCount = info->statedSampleCount < heldSamples ? info->statedSampleCount : heldSamples;
    uint64_t metadata = VibeLE64(bytes + 20);
    info->metadataOffset = metadata >= kVibeDSFHeaderBytes && metadata < fileLength ? metadata : 0;
    return VibeDSFVerdictOK;
}

uint64_t VibeDSFByteOffset(const VibeDSFInfo *info, uint32_t channel, uint64_t index) {
    uint64_t block = index / info->blockSize;
    return info->dataOffset + (block * info->channels + channel) * info->blockSize + index % info->blockSize;
}

bool VibeDSFReadChannels(const VibeDSFInfo *info, VibeDSFRead read, void *user, int64_t first, size_t count,
                         uint8_t *const *out) {
    uint64_t bytes = info->sampleCount / 8, tailBits = info->sampleCount % 8;
    // The bytes that hold samples, a partial last one included.
    uint64_t held = bytes + (tailBits ? 1 : 0);
    for (uint32_t c = 0; c < info->channels; c++) {
        memset(out[c], kVibeDSDSilence, count);
    }
    int64_t end = first + (int64_t)count;
    int64_t from = first < 0 ? 0 : first;
    int64_t to = end < 0 ? 0 : (uint64_t)end > held ? (int64_t)held : end;
    uint8_t span[6 * 4096];
    while (from < to) {
        // One read covers this block of every channel.
        uint64_t within = (uint64_t)from % info->blockSize;
        uint64_t take = info->blockSize - within;
        if (take > (uint64_t)(to - from)) {
            take = (uint64_t)(to - from);
        }
        uint64_t start = VibeDSFByteOffset(info, 0, (uint64_t)from);
        size_t length = (size_t)((info->channels - 1) * info->blockSize + take);
        ssize_t got = read(user, start, span, length);
        if (got != (ssize_t)length) {
            return false;
        }
        for (uint32_t c = 0; c < info->channels; c++) {
            const uint8_t *source = span + c * info->blockSize;
            uint8_t *target = out[c] + (from - first);
            if (info->lsbFirst) {
                for (uint64_t i = 0; i < take; i++) {
                    target[i] = __builtin_bitreverse8(source[i]);
                }
            } else {
                memcpy(target, source, (size_t)take);
            }
        }
        from += (int64_t)take;
    }
    // The last byte's bits past the sample count are padding, so silence
    // takes their place.
    if (tailBits && (int64_t)bytes >= first && (int64_t)bytes < end && (int64_t)bytes < to) {
        uint8_t keep = (uint8_t)(0xFF << (8 - tailBits));
        for (uint32_t c = 0; c < info->channels; c++) {
            uint8_t *byte = out[c] + ((int64_t)bytes - first);
            *byte = (uint8_t)((*byte & keep) | (kVibeDSDSilence & ~keep));
        }
    }
    return true;
}
