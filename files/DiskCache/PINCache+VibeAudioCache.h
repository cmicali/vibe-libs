//
//  PINCache+VibeAudioCache.h
//  vibe-libs
//
//  The disk-cache policy shared by the app's PINDiskCache-backed stores, such
//  as its tag cache and its waveform cache. One home stops the policies
//  drifting: each keys off the same file identity, through NSURL+Hash, and
//  their entries should live and die on the same terms.
//

#import <Foundation/Foundation.h>
#import "PINCache.h"

NS_ASSUME_NONNULL_BEGIN

@interface PINCache (VibeAudioCache)

// A store with the shared byte and age limits applied. Both stores then read
// and write diskCache directly, because on macOS PINMemoryCache never evicts —
// costLimit needs per-entry costs, disk hits repopulate at cost 0, and its
// memory-pressure hooks are iOS-only — so it would pin every entry ever loaded
// for the app's lifetime. Under rootPath, nil for the user's caches.
+ (PINCache *)audioCacheWithName:(NSString *)name rootPath:(nullable NSString *)rootPath;

// Entry count and total bytes on disk. The enumeration blocks, so call it on
// the store's own serial queue; the completion is dispatched to the main thread.
- (void)audioDiskUsageWithCompletion:(void (^)(NSUInteger fileCount,
                                               unsigned long long totalBytes))completion;

// The same counts, summed over several stores, for a piece that keeps more
// than one. The same blocking and the same completion.
+ (void)audioDiskUsageOfCaches:(NSArray<PINCache *> *)caches
                    completion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

// Removes, off the calling thread, every store under rootPath, nil for the
// user's caches, whose name is a current name's apart from its version suffix
// (" v8", "_v7") and is not that name. A name with no suffix is a version too.
// So a version bump needs no edit at the call site. An app calls it once at
// launch with every store name it opens. The completion runs on the queue
// that removed them.
+ (void)removeOtherAudioCacheVersionsKeeping:(NSArray<NSString *> *)currentNames
                                    rootPath:(nullable NSString *)rootPath
                                  completion:(nullable dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END
