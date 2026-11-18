// An M3U or M3U8, as media/Playlists reads one: an app's import of a user's
// playlist (m3uItemsInData:relativeToDirectory:), the list reader, and the
// reader of a list this writer wrote. None of them stats a file.

#import <Foundation/Foundation.h>

#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        NSURL *directory = [NSURL fileURLWithPath:@"/nonexistent/Playlists" isDirectory:YES];
        for (VibeM3UItem *item in [VibePlaylistFile m3uItemsInData:data relativeToDirectory:directory]) {
            (void)item.entry.url;
        }
        NSString *text = [VibePlaylistFile textFromData:data];
        if (text) {
            (void)[VibePlaylistFile m3uEntriesInText:text];
        }
        (void)[VibePlaylistFile entriesInM3UData:data];
    }
    return 0;
}
