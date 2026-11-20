//
//  NSURL+Hash.m
//  vibe-libs
//

#import "NSURL+Hash+Testing.h"
#import "FilePaths.h"
#import "VibeMacros.h"
#include <CommonCrypto/CommonDigest.h>
#include <ctype.h>
#include <os/lock.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdatomic.h>
#include <string.h>

static _Atomic uint64_t sCacheKeyGeneration;

@implementation NSData (Hash)

// A stack buffer: this runs once per track on the scan workers.
static NSString *VibeLowercaseHex(const unsigned char *bytes, size_t length) {
    static const char kHexDigits[] = "0123456789abcdef";
    char buffer[128];
    char *hex = length * 2 <= sizeof buffer ? buffer : malloc(length * 2);
    for (size_t i = 0; i < length; i++) {
        hex[i * 2] = kHexDigits[bytes[i] >> 4];
        hex[i * 2 + 1] = kHexDigits[bytes[i] & 0x0F];
    }
    NSString *text = [[NSString alloc] initWithBytes:hex length:length * 2 encoding:NSASCIIStringEncoding];
    if (hex != buffer) {
        free(hex);
    }
    return text;
}

- (NSString *)sha1Hex {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(self.bytes, (CC_LONG)self.length, digest);
    return VibeLowercaseHex(digest, sizeof digest);
}

- (NSString *)lowercaseHex {
    return VibeLowercaseHex(self.bytes, self.length);
}

- (NSData *)sha256Digest {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(self.bytes, (CC_LONG)self.length, digest);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

@end

// MARK: The place

// A volume a device held when it was last looked up: what a key hashes ahead
// of a path on it, and the bytes of the path that name its mount.
@interface VibeVolumeIdentity : NSObject
// "<uuid>:", nil for a volume with no UUID.
@property (nonatomic, nullable) NSData *placePrefix;
// The mount and a slash, for a volume mounted below the root.
@property (nonatomic, nullable) NSData *mountPrefix;
@property (nonatomic) uint64_t checked;
@end

@implementation VibeVolumeIdentity
@end

// How long a device's volume is trusted before it is looked up again.
// TRAP: a device number is reused by the next volume mounted after one goes,
// so a volume trusted for good would lend its UUID to another drive.
static const uint64_t kVibeVolumeTrustNS = 5 * NSEC_PER_SEC;

static os_unfair_lock sVolumesLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, VibeVolumeIdentity *> *sVolumes;
static VibeVolumeLookup sVolumeLookup;

static void VibeLookUpVolume(NSString *path, dev_t device, NSString **uuid, NSString **mountPath) {
    struct statfs fs;
    if (statfs(path.fileSystemRepresentation, &fs) != 0 || (dev_t)fs.f_fsid.val[0] != device) {
        return;
    }
    *mountPath = [NSString stringWithUTF8String:fs.f_mntonname];
    NSURL *mount = [NSURL fileURLWithPath:*mountPath isDirectory:YES];
    NSString *found = nil;
    [mount getResourceValue:&found forKey:NSURLVolumeUUIDStringKey error:NULL];
    *uuid = found.lowercaseString;
}

static NSData *VibeUTF8(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// The volume of the file at path, on its stat's device, looked up once for
// each device a few seconds.
static VibeVolumeIdentity *VibeVolumeOfFile(NSString *path, dev_t device) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&sVolumesLock);
    VibeVolumeIdentity *volume = sVolumes[@(device)];
    VibeVolumeLookup lookup = sVolumeLookup;
    os_unfair_lock_unlock(&sVolumesLock);
    if (volume && now - volume.checked < kVibeVolumeTrustNS) {
        return volume;
    }
    NSString *uuid = nil;
    NSString *mountPath = nil;
    if (lookup) {
        lookup(path, device, &uuid, &mountPath);
    } else {
        VibeLookUpVolume(path, device, &uuid, &mountPath);
    }
    volume = [[VibeVolumeIdentity alloc] init];
    volume.placePrefix = uuid ? VibeUTF8([uuid stringByAppendingString:@":"]) : nil;
    // A volume mounted at the root keeps the whole path.
    volume.mountPrefix = mountPath.length > 1 ? VibeUTF8([mountPath stringByAppendingString:@"/"]) : nil;
    volume.checked = now;
    os_unfair_lock_lock(&sVolumesLock);
    if (!sVolumes) {
        sVolumes = [NSMutableDictionary dictionary];
    }
    sVolumes[@(device)] = volume;
    os_unfair_lock_unlock(&sVolumesLock);
    return volume;
}

// The app's home and a slash, resolved as a key's path is, so a file under it
// is keyed from it, as pathKey's spelling is. iOS moves the home with each
// install.
static NSData *VibeResolvedHome(void) {
    static NSData *home;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        home = VibeUTF8([NSHomeDirectory().stringByResolvingSymlinksInPath stringByAppendingString:@"/"]);
    });
    return home;
}

static BOOL VibeHasPrefix(const char *bytes, size_t length, NSData *_Nullable prefix) {
    return prefix && length > prefix.length && memcmp(bytes, prefix.bytes, prefix.length) == 0;
}

static NSString *VibeSHA1HexOfString(NSString *text) {
    return [VibeUTF8(text) sha1Hex];
}

// CH32: the hash of a resolved path's place, on its stat's device. The place
// is "~/" and the path from the home, or "<uuid>:" and the path within the
// volume, which keeps its leading slash, or the path itself. The pieces are
// hashed where they lie, with no string built.
static NSString *VibePlaceHash(NSString *path, dev_t device) {
    const char *bytes = path.UTF8String;
    size_t length = strlen(bytes);
    const void *prefix = NULL;
    size_t prefixLength = 0;
    size_t skip = 0;
    NSData *home = VibeResolvedHome();
    if (VibeHasPrefix(bytes, length, home)) {
        prefix = "~/";
        prefixLength = 2;
        skip = home.length;
    } else {
        VibeVolumeIdentity *volume = VibeVolumeOfFile(path, device);
        if (volume.placePrefix) {
            prefix = volume.placePrefix.bytes;
            prefixLength = volume.placePrefix.length;
            // A volume reached through a firmlink, as the startup disk's data
            // volume is, keeps the whole path.
            skip = VibeHasPrefix(bytes, length, volume.mountPrefix) ? volume.mountPrefix.length - 1 : 0;
        }
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    CC_SHA1_Update(&context, prefix, (CC_LONG)prefixLength);
    CC_SHA1_Update(&context, bytes + skip, (CC_LONG)(length - skip));
    CC_SHA1_Final(digest, &context);
    return VibeLowercaseHex(digest, sizeof digest);
}

// The hash's range in a key, "<size>-<mtime_us>-<hash>" and any suffix. The
// time may be negative, before 1970. NSNotFound when key is no cache key.
static NSRange VibeKeyHashRange(NSString *key) {
    static const NSUInteger kHashLength = CC_SHA1_DIGEST_LENGTH * 2;
    NSUInteger length = key.length;
    NSUInteger i = 0;
    while (i < length && isdigit([key characterAtIndex:i])) {
        i++;
    }
    if (i == 0 || i >= length || [key characterAtIndex:i] != '-') {
        return NSMakeRange(NSNotFound, 0);
    }
    i++;
    if (i < length && [key characterAtIndex:i] == '-') {
        i++;
    }
    NSUInteger digits = i;
    while (i < length && isdigit([key characterAtIndex:i])) {
        i++;
    }
    if (i == digits || i >= length || [key characterAtIndex:i] != '-' || length - i - 1 < kHashLength) {
        return NSMakeRange(NSNotFound, 0);
    }
    return NSMakeRange(i + 1, kHashLength);
}

// The resolved paths this process keyed last, by their place hash, for a
// caller with a key and no URL, and so a miss need not resolve links again.
static NSCache<NSString *, NSString *> *VibeRecentPaths(void) {
    static NSCache *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = [[NSCache alloc] init];
        paths.countLimit = 1024;
    });
    return paths;
}

// key with its place hash, at range, replaced by the hash of path, as keys
// were made before CH32. nil when they are equal.
static NSString *VibePreviousKey(NSString *key, NSRange range, NSString *path) {
    NSString *previous = VibeSHA1HexOfString(path);
    if ([key compare:previous options:NSLiteralSearch range:range] == NSOrderedSame) {
        return nil;
    }
    return [key stringByReplacingCharactersInRange:range withString:previous];
}

@implementation NSURL (Hash)

+ (uint64_t)cacheKeyGeneration {
    return atomic_load(&sCacheKeyGeneration);
}

+ (void)invalidateMemoizedCacheKeys {
    atomic_fetch_add(&sCacheKeyGeneration, 1);
}

- (nullable NSString *)pathKey {
    NSString *path = VibeComparablePath(self.path);
    if (!path) {
        return nil;
    }
    NSString *home = VibeComparablePath(NSHomeDirectory());
    if ([path hasPrefix:[home stringByAppendingString:@"/"]]) {
        path = [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return VibeSHA1HexOfString(path);
}

- (nullable NSString *)cacheKey {
    return [self cacheKeyWithStat:NULL];
}

- (nullable NSString *)previousCacheKeyForKey:(NSString *)key {
    NSRange range = VibeKeyHashRange(key);
    if (range.location == NSNotFound) {
        return nil;
    }
    // Resolving the links again costs a few lstats, so a key made lately
    // takes the path it was made from.
    NSString *path = [VibeRecentPaths() objectForKey:[key substringWithRange:range]]
            ?: [self.path stringByResolvingSymlinksInPath];
    return path ? VibePreviousKey(key, range, path) : nil;
}

+ (nullable NSString *)previousCacheKeyForKey:(NSString *)key {
    NSRange range = VibeKeyHashRange(key);
    NSString *path = range.location == NSNotFound ? nil
            : [VibeRecentPaths() objectForKey:[key substringWithRange:range]];
    return path ? VibePreviousKey(key, range, path) : nil;
}

- (nullable NSString *)cacheKeyWithStat:(struct stat *_Nullable)info {
    // A link and its target share one entry, so retagging the target
    // invalidates it.
    NSString *path = [self.path stringByResolvingSymlinksInPath];
    // stat(2), not attributesOfItemAtPath:, whose attribute fetch was the
    // scan's largest cost.
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        // Not "0-0-<sha1>": a transiently unstattable file would persist
        // entries under that identity forever.
        LogWarn(@"Could not stat %@ for cache key: %s", path, strerror(errno));
        return nil;
    }
    // TRAP: round exactly as Foundation's NSDate for this timespec does —
    // reference-date seconds BEFORE the nanoseconds — or persisted keys
    // change: direct 1970 arithmetic lands 1µs off on ~6% of real files.
    NSTimeInterval sinceReference = ((NSTimeInterval)st.st_mtimespec.tv_sec - NSTimeIntervalSince1970)
            + (NSTimeInterval)st.st_mtimespec.tv_nsec / 1e9;
    NSDate *modified = [NSDate dateWithTimeIntervalSinceReferenceDate:sinceReference];
    long long mtimeUs = (long long)llround(modified.timeIntervalSince1970 * 1e6);

    if (info) {
        *info = st;
    }
    NSString *hex = VibePlaceHash(path, st.st_dev);
    [VibeRecentPaths() setObject:path forKey:hex];
    return [NSString stringWithFormat:@"%llu-%lld-%@", (unsigned long long)st.st_size, mtimeUs, hex];
}

@end

@implementation NSURL (HashTesting)

+ (void)setVolumeLookupForTesting:(VibeVolumeLookup)lookup {
#if DEBUG
    os_unfair_lock_lock(&sVolumesLock);
    sVolumeLookup = [lookup copy];
    [sVolumes removeAllObjects];
    os_unfair_lock_unlock(&sVolumesLock);
#endif
}

@end
