//
//  VibeDSF.c
//  vibe-libs
//

#include "VibeDSF.h"
#include "VibeDSD.h"

#include <libkern/OSByteOrder.h>
#include <string.h>

uint32_t VibeDSFChannelsOfType(uint32_t channelType) {
    static const uint32_t channels[8] = {0, 1, 2, 3, 4, 4, 5, 6};
    return channelType < 8 ? channels[channelType] : 0;
}

bool VibeDSFParseHeader(const uint8_t *bytes, size_t count, uint64_t fileLength, VibeDSFInfo *info) {
    memset(info, 0, sizeof *info);
    if (count < kVibeDSFHeaderBytes || fileLength < kVibeDSFHeaderBytes || memcmp(bytes, "DSD ", 4) != 0
            || OSReadLittleInt64(bytes, 4) != 28 || memcmp(bytes + 28, "fmt ", 4) != 0
            || OSReadLittleInt64(bytes, 32) != 52 || memcmp(bytes + 80, "data", 4) != 0) {
        return false;
    }
    const uint8_t *fmt = bytes + 40;
    info->channelType = OSReadLittleInt32(fmt, 8);
    info->channels = OSReadLittleInt32(fmt, 12);
    info->sampleRate = OSReadLittleInt32(fmt, 16);
    info->rateMultiple = VibeDSDRateMultiple(info->sampleRate);
    uint32_t bits = OSReadLittleInt32(fmt, 20);
    info->lsbFirst = bits == 1;
    // Version 1, raw DSD (format 0, the only one the spec defines), a type
    // and its count, a bit order, the one block size, and a rate this decodes.
    if (OSReadLittleInt32(fmt, 0) != 1 || OSReadLittleInt32(fmt, 4) != 0 || info->channels == 0
            || info->channels != VibeDSFChannelsOfType(info->channelType) || (bits != 1 && bits != 8)
            || OSReadLittleInt32(fmt, 32) != kVibeDSFBlockBytes || info->rateMultiple == 0) {
        return false;
    }
    // The data chunk's size counts its 12-byte header. A file cut short holds
    // less than it states.
    uint64_t chunk = OSReadLittleInt64(bytes, 84);
    if (chunk < 12) {
        return false;
    }
    uint64_t data = chunk - 12;
    if (data > fileLength - kVibeDSFHeaderBytes) {
        data = fileLength - kVibeDSFHeaderBytes;
    }
    // Each channel's bytes: every whole group of blocks, then the last
    // channel's part of the group the data ends in, which is the least.
    uint64_t group = (uint64_t)info->channels * kVibeDSFBlockBytes;
    uint64_t rest = data % group, last = (uint64_t)(info->channels - 1) * kVibeDSFBlockBytes;
    uint64_t held = data / group * kVibeDSFBlockBytes + (rest > last ? rest - last : 0);
    uint64_t stated = OSReadLittleInt64(fmt, 24);
    info->sampleCount = stated / 8 < held ? stated : held * 8;
    return true;
}

uint64_t VibeDSFByteOffset(const VibeDSFInfo *info, uint32_t channel, uint64_t index) {
    uint64_t block = index / kVibeDSFBlockBytes;
    return kVibeDSFHeaderBytes + (block * info->channels + channel) * kVibeDSFBlockBytes + index % kVibeDSFBlockBytes;
}

bool VibeDSFReadChannels(const VibeDSFInfo *info, VibeDSFRead read, void *user, int64_t first, size_t count,
                         uint8_t *const *out, uint8_t *scratch, size_t scratchBytes) {
    const uint64_t block = kVibeDSFBlockBytes, channels = info->channels;
    uint8_t silence = info->lsbFirst ? __builtin_bitreverse8(kVibeDSDSilence) : kVibeDSDSilence;
    uint64_t whole = info->sampleCount / 8, tailBits = info->sampleCount % 8;
    // The bytes that hold samples, a partial last one included.
    int64_t held = (int64_t)(whole + (tailBits ? 1 : 0));
    int64_t end = first + (int64_t)count;
    int64_t from = first < 0 ? 0 : first;
    int64_t to = end < held ? end : held;
    if (to < from) {
        to = from;
    }
    // Silence where the file holds no samples, before and after.
    for (uint32_t c = 0; c < channels; c++) {
        if (from > first) {
            memset(out[c], silence, (size_t)(from - first));
        }
        if (end > to) {
            memset(out[c] + (to - first), silence, (size_t)(end - to));
        }
    }
    uint64_t groupsFit = scratchBytes / (channels * block);
    if (groupsFit == 0) {
        return from == to;
    }
    while (from < to) {
        // One read covers whole groups: from `from`'s block to as many more as
        // the scratch holds, for every channel.
        uint64_t within = (uint64_t)from % block;
        uint64_t take = groupsFit * block - within;
        if (take > (uint64_t)(to - from)) {
            take = (uint64_t)(to - from);
        }
        uint64_t start = VibeDSFByteOffset(info, 0, (uint64_t)from);
        uint64_t stop = VibeDSFByteOffset(info, (uint32_t)(channels - 1), (uint64_t)from + take - 1) + 1;
        ssize_t got = read(user, start, scratch, (size_t)(stop - start));
        if (got != (ssize_t)(stop - start)) {
            return false;
        }
        for (uint32_t c = 0; c < channels; c++) {
            uint8_t *target = out[c] + (from - first);
            for (uint64_t done = 0; done < take;) {
                uint64_t at = within + done, run = block - at % block;
                if (run > take - done) {
                    run = take - done;
                }
                // The scratch starts at channel 0's byte `from`, `within` into its block.
                memcpy(target + done, scratch + (at / block * channels + c) * block + at % block - within, (size_t)run);
                done += run;
            }
        }
        from += (int64_t)take;
    }
    // The last byte's bits past the sample count are padding, so silence
    // takes their place.
    if (tailBits && (int64_t)whole >= first && (int64_t)whole < to) {
        uint8_t keep = info->lsbFirst ? (uint8_t)((1u << tailBits) - 1) : (uint8_t)(0xFF << (8 - tailBits));
        for (uint32_t c = 0; c < channels; c++) {
            uint8_t *byte = out[c] + ((int64_t)whole - first);
            *byte = (uint8_t)((*byte & keep) | (silence & ~keep));
        }
    }
    return true;
}
