//
//  VibeDSFLayout.h
//  vibe-libs
//
//  A DSF's header, read once, as TagLib's DSF read takes it: the DSD chunk
//  of 28 bytes, the fmt chunk of 52, then the data chunk's 12-byte header,
//  92 bytes in all. The writer's check before a save and the audio walk
//  share it (media/Tags/AGENTS.md, Writing). C++.
//

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// The file's size and its ID3v2 tag's offset as the DSD chunk states them,
// the tag's 0 for none, and where the data chunk starts and its size,
// header included.
struct VibeDSFLayout {
    uint64_t fileSize = 0, metadataOffset = 0, dataOffset = 0, dataSize = 0;
};

// The first bytes' layout, which needs kVibeDSFHeaderBytes of them. false
// when they are no DSF TagLib reads.
constexpr size_t kVibeDSFHeaderBytes = 92;

inline bool VibeReadDSFLayout(const uint8_t *bytes, size_t length, VibeDSFLayout *layout) {
    auto le64 = [&](size_t at) {
        uint64_t value = 0;
        for (int i = 7; i >= 0; i--) value = value << 8 | bytes[at + i];
        return value;
    };
    if (length < kVibeDSFHeaderBytes || memcmp(bytes, "DSD ", 4) != 0 || le64(4) != 28 ||
        memcmp(bytes + 28, "fmt ", 4) != 0 || le64(32) != 52 || memcmp(bytes + 80, "data", 4) != 0) {
        return false;
    }
    layout->fileSize = le64(12);
    layout->metadataOffset = le64(20);
    layout->dataOffset = 80;
    layout->dataSize = le64(84);
    return layout->dataSize >= 12;
}
