// An M3U or M3U8 as an app reads a user's playlist: its import, which
// matches the entries itself (m3uItemsInData:relativeToDirectory:), and
// media/FolderScan's walk, which resolves each through the rungs
// (entriesForPlaylistAtURL:).

#import <Foundation/Foundation.h>

#import "FuzzInput.h"
#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        NSURL *list = FuzzInputFile(bytes, size, @"List.m3u8");
        if (!list) {
            return 0;
        }
        for (VibeM3UItem *item in [VibePlaylistFile m3uItemsInData:data
                                               relativeToDirectory:list.URLByDeletingLastPathComponent]) {
            (void)item.entry.url;
        }
        for (VibePlaylistEntry *entry in [VibePlaylistFile entriesForPlaylistAtURL:list]) {
            (void)entry.url;
        }
    }
    return 0;
}
