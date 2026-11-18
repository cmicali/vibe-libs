// A play's open of one file: audio/Decode's handle, which takes the file
// from CoreAudio's parser to dr_flac, dr_mp3, dr_wav, or libvorbis. It reads
// a few buffers, then seeks to the middle and reads again, as a scrub does.
// FUZZ_EXTENSION names the file, which picks the parser's hint.

#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"
#import "FuzzInput.h"

#ifndef FUZZ_EXTENSION
#error "Build each decode target with FUZZ_EXTENSION set, such as \"flac\""
#endif

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSURL *url = FuzzInputFile(bytes, size, @"fuzz." FUZZ_EXTENSION);
        if (!url) {
            return 0;
        }
        AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url interleaved:NO
                                                              interrupted:VibeNeverWaitsForAStream error:NULL];
        if (!handle) {
            return 0;
        }
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat
                                                                 frameCapacity:4096];
        if (!buffer) {
            return 0;
        }
        for (int i = 0; i < 16 && [handle readIntoBuffer:buffer error:NULL] && buffer.frameLength > 0; i++) {
        }
        AVAudioFramePosition length = handle.length;
        if (length > 0 && [handle seekToFrame:length / 2 error:NULL]) {
            (void)[handle readIntoBuffer:buffer error:NULL];
        }
    }
    return 0;
}
