// A CUE sheet beside its audio, as media/Playlists reads one: the bytes
// decoded to text, then the parser, with every FILE resolved without a disk.

#import <Foundation/Foundation.h>

#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        NSString *text = [VibePlaylistFile textFromData:data];
        if (!text) {
            return 0;
        }
        NSURL *sheet = [NSURL fileURLWithPath:@"/nonexistent/Mix.cue"];
        NSArray<VibePlaylistEntry *> *entries =
                [VibePlaylistFile cueEntriesInText:text sheetURL:sheet resolvingFile:^NSURL *(NSString *name, BOOL sole) {
            return name.length ? [NSURL fileURLWithPath:[@"/nonexistent" stringByAppendingPathComponent:name]] : nil;
        }];
        for (VibePlaylistEntry *entry in entries) {
            (void)entry.url;
        }
    }
    return 0;
}
