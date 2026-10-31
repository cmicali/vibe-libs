//
//  PINCache+VibeAudioCache.m
//  vibe-libs
//

#import "PINCache+VibeAudioCache.h"
#import "HelperMacros.h"

// Each store has its own budget. A waveform entry grows with its track, about
// 50 KiB a minute and double that with bands. Metadata and display-art sizes
// depend on the file.
static const NSUInteger kAudioCacheByteLimit = 1024 * 1024 * 1024;

// Changed file identities can orphan entries. Untouched entries age out
// instead of holding the byte budget forever.
static const NSTimeInterval kAudioCacheAgeLimit = 6 * (30 * (24 * 60 * 60)); // 180 days

// The name without its version suffix.
static NSString *VibeAudioCacheFamily(NSString *name) {
    NSRange suffix = [name rangeOfString:@"[ _]v[0-9]+$" options:NSRegularExpressionSearch];
    return suffix.location == NSNotFound ? name : [name substringToIndex:suffix.location];
}

@implementation PINCache (VibeAudioCache)

+ (PINCache *)audioCacheWithName:(NSString *)name rootPath:(NSString *)rootPath {
    PINCache *cache = rootPath ? [[PINCache alloc] initWithName:name rootPath:rootPath] : [[PINCache alloc] initWithName:name];
    cache.diskCache.byteLimit = kAudioCacheByteLimit;
    cache.diskCache.ageLimit = kAudioCacheAgeLimit;
    return cache;
}

- (void)audioDiskUsageWithCompletion:(void (^)(NSUInteger fileCount,
                                               unsigned long long totalBytes))completion {
    [PINCache audioDiskUsageOfCaches:@[self] completion:completion];
}

+ (void)audioDiskUsageOfCaches:(NSArray<PINCache *> *)caches
                    completion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    __block NSUInteger count = 0;
    __block unsigned long long bytes = 0;
    for (PINCache *cache in caches) {
        [cache.diskCache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
            count++;
            NSNumber *size = nil;
            if ([fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) {
                bytes += size.unsignedLongLongValue;
            }
        }];
    }
    run_on_main_thread({
        completion(count, bytes);
    });
}

+ (void)removeOtherAudioCacheVersionsKeeping:(NSArray<NSString *> *)currentNames
                                    rootPath:(NSString *)rootPath
                                  completion:(dispatch_block_t)completion {
    NSArray<NSString *> *current = [currentNames copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root = rootPath
                ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        // PINDiskCache names each store's directory "<prefix>.<name>".
        NSString *prefix = [PINDiskCachePrefix stringByAppendingString:@"."];
        if (root) {
            for (NSString *entry in [fileManager contentsOfDirectoryAtPath:root error:nil]) {
                if (![entry hasPrefix:prefix]) {
                    continue;
                }
                NSString *name = [entry substringFromIndex:prefix.length];
                for (NSString *keep in current) {
                    if (![name isEqualToString:keep]
                            && [VibeAudioCacheFamily(name) isEqualToString:VibeAudioCacheFamily(keep)]) {
                        [fileManager removeItemAtPath:[root stringByAppendingPathComponent:entry] error:nil];
                        break;
                    }
                }
            }
        }
        if (completion) {
            completion();
        }
    });
}

@end
