//
//  PINCache+VibeAudioCache.h
//  vibe-libs
//
//  What an app's launch still calls from when PINCache was here: the removal
//  of the PINCache stores a format change left, and the default age. The
//  header keeps its name, and PINCache stays a class with that one method,
//  so the launch builds as it did. PINCache itself is gone.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 180 days, the age limit an app passes to a cache's setByteLimit:ageLimit:
// when it keeps the default age. VibeCacheStore.defaultAgeLimit is the same.
extern const NSTimeInterval VibeAudioCacheDefaultAgeLimit;

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
