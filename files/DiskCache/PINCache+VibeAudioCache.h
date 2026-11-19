//
//  PINCache+VibeAudioCache.h
//  vibe-libs
//
//  What is left of the PINCache stores the releases before VibeCacheStore
//  kept: their names, and the removal of the ones a format change left. The
//  header keeps its name, and PINCache stays a class with that one method,
//  so an app's launch builds as it did. PINCache itself is no longer here.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 180 days, the age limit an app passes to a cache's setByteLimit:ageLimit:
// when it keeps the default age. VibeCacheStore.defaultAgeLimit is the same.
extern const NSTimeInterval VibeAudioCacheDefaultAgeLimit;

// The prefix of every PINCache store's folder, "<prefix>.<name>", which an
// import reads its old store by.
extern NSString *const VibeAudioCacheLegacyPrefix;

// The file a PINCache store kept key in, as its key encoder named it.
FOUNDATION_EXPORT NSString *_Nullable VibeAudioCacheLegacyFileName(NSString *key);

@interface PINCache : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Removes, off the calling thread, every PINCache store under rootPath, nil
// for the user's caches, whose name is a current name's apart from its
// version suffix (" v8", "_v7") and is not that name. A name with no suffix
// is a version too. An app calls it once at launch with every store name its
// caches give, and a cache whose import reads an old store names that store,
// so it stays until the import ends. The completion runs on the queue that
// removed them.
+ (void)removeOtherAudioCacheVersionsKeeping:(NSArray<NSString *> *)currentNames
                                    rootPath:(nullable NSString *)rootPath
                                  completion:(nullable dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END
