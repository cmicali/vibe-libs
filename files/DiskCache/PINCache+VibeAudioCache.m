//
//  PINCache+VibeAudioCache.m
//  vibe-libs
//

#import "PINCache+VibeAudioCache.h"
#import "VibeLegacyCacheNames.h"

const NSTimeInterval VibeAudioCacheDefaultAgeLimit = 180 * 24 * 60 * 60;

// VibeLegacyCacheNames.h's, defined here rather than in a file of their own:
// an app's test target lists this file by its path beside the waveform
// store, and a new file would leave it unable to link.
NSString *const VibeLegacyCacheFolderPrefix = @"com.pinterest.PINDiskCache.";

NSString *VibeLegacyCacheFolder(NSString *root, NSString *name) {
    return [root stringByAppendingPathComponent:[VibeLegacyCacheFolderPrefix stringByAppendingString:name]];
}

NSString *VibeLegacyCacheFileName(NSString *key) {
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
    NSSet<NSString *> *current = [NSSet setWithArray:currentNames];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *root = rootPath
                ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *prefix = VibeLegacyCacheFolderPrefix;
        NSMutableSet<NSString *> *families = [NSMutableSet set];
        for (NSString *keep in current) {
            [families addObject:VibeAudioCacheFamily(keep)];
        }
        if (root) {
            for (NSString *entry in [fileManager contentsOfDirectoryAtPath:root error:nil]) {
                if (![entry hasPrefix:prefix]) {
                    continue;
                }
                NSString *name = [entry substringFromIndex:prefix.length];
                // A name the list keeps stays, though another kept name
                // shares its family, as a store and the older one it imports
                // do.
                if (![current containsObject:name] && [families containsObject:VibeAudioCacheFamily(name)]) {
                    [fileManager removeItemAtPath:[root stringByAppendingPathComponent:entry] error:nil];
                }
            }
        }
        if (completion) {
            completion();
        }
    });
}

@end
