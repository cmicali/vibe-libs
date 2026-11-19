//
//  PINCache+VibeAudioCache.m
//  vibe-libs
//

#import "PINCache+VibeAudioCache.h"

const NSTimeInterval VibeAudioCacheDefaultAgeLimit = 180 * 24 * 60 * 60;

NSString *const VibeAudioCacheLegacyPrefix = @"com.pinterest.PINDiskCache";

NSString *VibeAudioCacheLegacyFileName(NSString *key) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:@".:/%"].invertedSet;
    });
    NSString *name = [key stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return name.length ? name : nil;
}

// The name without its version suffix.
static NSString *VibeAudioCacheFamily(NSString *name) {
    NSRange suffix = [name rangeOfString:@"[ _]v[0-9]+$" options:NSRegularExpressionSearch];
    return suffix.location == NSNotFound ? name : [name substringToIndex:suffix.location];
}

@implementation PINCache

+ (void)removeOtherAudioCacheVersionsKeeping:(NSArray<NSString *> *)currentNames
                                    rootPath:(NSString *)rootPath
                                  completion:(dispatch_block_t)completion {
    NSArray<NSString *> *current = [currentNames copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root = rootPath
                ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *prefix = [VibeAudioCacheLegacyPrefix stringByAppendingString:@"."];
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
