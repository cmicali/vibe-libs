// Each input as a file of this process's own, since the app reads a user's
// file through its path: TagLib's FileStream, the CoreAudio parser, the
// sheet reader's FILE, and the resolution rungs' stats. The folder goes at
// exit.

#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <unistd.h>

static NSString *FuzzFolder(void) {
    static NSString *folder;
    if (!folder) {
        NSString *name = [NSString stringWithFormat:@"vibe-libs-fuzz-%d", getpid()];
        folder = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                      error:NULL];
        atexit_b(^{
            [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
        });
    }
    return folder;
}

// The file named `name` in this process's folder, holding the input.
static NSURL *_Nullable FuzzInputFile(const uint8_t *bytes, size_t size, NSString *name) {
    NSURL *url = [NSURL fileURLWithPath:[FuzzFolder() stringByAppendingPathComponent:name] isDirectory:NO];
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
    return [data writeToURL:url atomically:NO] ? url : nil;
}
