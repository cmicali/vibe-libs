// The sheet a FLAC carries, as media/FolderScan's walk reads it: the
// CUESHEET comment or the binary CUESHEET block. The reader takes a path, so
// each input is written to a file of this process's own first.

#import <Foundation/Foundation.h>

#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

#include <unistd.h>

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    static NSURL *url;
    if (!url) {
        NSString *name = [NSString stringWithFormat:@"vibe-libs-fuzz-%d.flac", getpid()];
        url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    }
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        if (![data writeToURL:url atomically:NO]) {
            return 0;
        }
        for (VibePlaylistEntry *entry in [VibePlaylistFile cueEntriesEmbeddedInFLACAtURL:url]) {
            (void)entry.url;
        }
    }
    return 0;
}
