//
//  LegacyCacheFixtures.h
//  vibe-libs
//
//  A PINCache store of the releases before VibeCacheStore, written as
//  PINDiskCache filed it: a folder "<prefix>.<name>" under the root, and one
//  file for each key, named by its key encoder, holding an insecure keyed
//  archive. The imports' tests lay one out with it. The name's encoding is
//  pinned to PINDiskCache's own by DiskCache's tests.
//

#import <Foundation/Foundation.h>
#import "PINCache+VibeAudioCache.h"

NS_ASSUME_NONNULL_BEGIN

static inline NSString *VibeLegacyCacheFolder(NSString *root, NSString *store) {
    return [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", VibeAudioCacheLegacyPrefix, store]];
}

// The bytes written, or nil when the file could not be.
static inline NSData *_Nullable VibeWriteLegacyCacheEntry(NSString *root, NSString *store, NSString *key,
                                                          id<NSCoding> object) {
    NSString *folder = VibeLegacyCacheFolder(root, store);
    NSString *name = VibeAudioCacheLegacyFileName(key);
    NSData *bytes = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:NULL];
    BOOL made = [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
                                                         attributes:nil error:NULL];
    return made && name && [bytes writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES] ? bytes : nil;
}

NS_ASSUME_NONNULL_END
