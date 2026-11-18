//
//  VibeTestFileDates.h
//  vibe-libs
//
//  A file's modified date pushed forward, as a later write leaves it, so its
//  NSURL+Hash cacheKey changes. Header-only, for any test bundle.
//

#import <Foundation/Foundation.h>

// Moves url's modified date `seconds` later. NO when the file's attributes
// can't be read or set.
static inline BOOL VibePushFileDateForward(NSURL *url, NSTimeInterval seconds) {
    NSDate *modified = [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL]
            fileModificationDate];
    return modified && [NSFileManager.defaultManager
            setAttributes:@{NSFileModificationDate: [modified dateByAddingTimeInterval:seconds]}
             ofItemAtPath:url.path error:NULL];
}
