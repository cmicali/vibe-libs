// The sheet a FLAC carries, as media/FolderScan's walk reads it
// (cueEntriesEmbeddedInFLACAtURL:): the CUESHEET comment or the binary
// CUESHEET block.

#import <Foundation/Foundation.h>

#import "FuzzInput.h"
#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSURL *url = FuzzInputFile(bytes, size, @"Mix.flac");
        if (!url) {
            return 0;
        }
        for (VibePlaylistEntry *entry in [VibePlaylistFile cueEntriesEmbeddedInFLACAtURL:url]) {
            (void)entry.url;
        }
    }
    return 0;
}
