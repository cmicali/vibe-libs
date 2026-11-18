// A CUE sheet beside its audio, as an app's import and media/FolderScan's
// walk read one (cueEntriesForSheetAtURL:knownFiles:): the text decoding,
// the parser, and every FILE resolved through the rungs. Inputs whose last
// byte is odd resolve against a walk's listing of one file, others against
// the disk.

#import <Foundation/Foundation.h>

#import "FuzzInput.h"
#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSURL *sheet = FuzzInputFile(bytes, size, @"Mix.cue");
        if (!sheet) {
            return 0;
        }
        NSDictionary<NSString *, NSArray<NSURL *> *> *known = nil;
        if (size && (bytes[size - 1] & 1)) {
            NSURL *audio = [sheet.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Mix.flac"];
            known = @{[VibePlaylistFile knownFileKeyForPath:(NSString *)audio.path]: @[audio]};
        }
        for (VibePlaylistEntry *entry in [VibePlaylistFile cueEntriesForSheetAtURL:sheet knownFiles:known]) {
            (void)entry.url;
        }
    }
    return 0;
}
