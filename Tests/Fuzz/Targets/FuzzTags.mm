// A scan's read of one file: media/Metadata's parse
// (+[AudioTrackMetadata metadataWithURL:displayArtData:]), with its tags, its
// fields, its CoreAudio and dr_flac fallbacks, and its thumbnail encode.
// Inputs whose last byte is odd also take the art loader's own read, which
// opens without properties. FUZZ_EXTENSION names the file, which picks the
// parser before the sniff.

#import <Foundation/Foundation.h>

#import "AudioTrackMetadataInternal.h"
#import "FuzzInput.h"
#import "TagLibAudioFile.h"

#include <tdebuglistener.h>

#ifndef FUZZ_EXTENSION
#error "Build each tag target with FUZZ_EXTENSION set, such as \"flac\""
#endif

namespace {
class Quiet : public TagLib::DebugListener {
    void printMessage(const TagLib::String &) override {}
};
Quiet quiet;
const bool quieted = (TagLib::setDebugListener(&quiet), true);
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSURL *url = FuzzInputFile(bytes, size, @"fuzz." FUZZ_EXTENSION);
        if (!url) {
            return 0;
        }
        NSData *display = nil;
        (void)[AudioTrackMetadata metadataWithURL:url displayArtData:&display];
        if (size && (bytes[size - 1] & 1)) {
            NSData *art = nil;
            // The parse catches what TagLib throws, and so does this read.
            (void)VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art);
        }
    }
    return 0;
}
