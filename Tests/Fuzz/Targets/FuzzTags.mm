// A tag read of one file, as media/Metadata's parse makes it: the factory,
// the tag, the audio properties, the property map, the wrapper's facts, and
// the art. Then the art loader's own read, which opens without properties.
// The bytes are served through the ranged read, so nothing touches the disk.
// FUZZ_EXTENSION names the file, which picks the parser before the sniff.

#import <Foundation/Foundation.h>

#import "NSString+CPPStrings.h"
#import "TagLibAudioFile.h"

#include <audioproperties.h>
#include <tdebuglistener.h>
#include <tpropertymap.h>

#ifndef FUZZ_EXTENSION
#error "Build each tag target with FUZZ_EXTENSION set, such as \"flac\""
#endif

namespace {
class Quiet : public TagLib::DebugListener {
    void printMessage(const TagLib::String &) override {}
};
Quiet quiet;
}

static void Touch(const TagLib::String &text) {
    (void)[NSString stringWithStdString:text.to8Bit(true)];
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    TagLib::setDebugListener(&quiet);
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        VibeTagByteRangeRead read = ^NSData *(NSURL *, uint64_t offset, uint64_t length, NSError **) {
            if (offset >= data.length) {
                return [NSData data];
            }
            uint64_t end = MIN(offset + length, (uint64_t)data.length);
            return [data subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)(end - offset))];
        };
        const char *path = "/nonexistent/fuzz." FUZZ_EXTENSION;
        // The app catches what TagLib throws (AudioTrackMetadata.mm), so a
        // throw is a failed parse, never a finding.
        try {
            TagLibAudioFile fileRef(path, true, read, size);
            if (TagLib::File *file = fileRef.file()) {
                if (TagLib::Tag *tag = fileRef.tag()) {
                    Touch(tag->artist());
                    Touch(tag->title());
                }
                if (auto props = file->audioProperties()) {
                    (void)props->lengthInMilliseconds();
                    (void)props->bitrate();
                    (void)props->sampleRate();
                }
                const TagLib::PropertyMap properties = file->properties();
                for (const auto &entry : properties) {
                    for (const auto &value : entry.second) {
                        Touch(value);
                    }
                }
                (void)fileTypeForTagLibFile(file);
                (void)audioMD5FromTagLibFile(file);
                (void)bitsPerSampleFromTagLibFile(file);
                (void)albumArtDataFromTagLibFile(file);
            }
        }
        catch (...) {
        }
        try {
            NSData *art = nil;
            (void)VibeTagLibReadEmbeddedArt(@(path), read, size, &art);
        }
        catch (...) {
        }
    }
    return 0;
}
