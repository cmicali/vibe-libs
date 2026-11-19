//
//  NSURL+Hash.m
//  vibe-libs
//

#import "NSURL+Hash.h"
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

NSString *const VibeCacheKeyPlaceMark = @"cache key place";

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

// A volume a device held when it was last looked up.
@interface VibeVolumeIdentity : NSObject
@property (nonatomic, copy, nullable) NSString *uuid;
@property (nonatomic, copy, nullable) NSString *mountPath;
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
    volume.uuid = uuid;
    volume.mountPath = mountPath;
    volume.checked = now;
    os_unfair_lock_lock(&sVolumesLock);
    if (!sVolumes) {
        sVolumes = [NSMutableDictionary dictionary];
    }
    sVolumes[@(device)] = volume;
    os_unfair_lock_unlock(&sVolumesLock);
    return volume;
}

// The app's home, resolved as a key's path is, so a file under it is keyed
// from it, as pathKey's spelling is. iOS moves the home with each install.
static NSString *VibeResolvedHome(void) {
    static NSString *home;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        home = [NSHomeDirectory().stringByResolvingSymlinksInPath stringByAppendingString:@"/"];
    });
    return home;
}

// CH32: what a key hashes for a resolved path on its stat's device.
static NSString *VibeKeyPlace(NSString *path, dev_t device) {
    NSString *home = VibeResolvedHome();
    if ([path hasPrefix:home]) {
        return [@"~/" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    VibeVolumeIdentity *volume = VibeVolumeOfFile(path, device);
    if (!volume.uuid) {
        return path;
    }
    // A volume mounted at the root, or reached through a firmlink, as the
    // startup disk's data volume is, keeps the whole path.
    NSString *mount = volume.mountPath;
    NSString *within = path;
    if (mount.length > 1 && [path hasPrefix:[mount stringByAppendingString:@"/"]]) {
        within = [path substringFromIndex:mount.length];
    }
    return [NSString stringWithFormat:@"%@:%@", volume.uuid, within];
}

static NSString *VibePlaceHash(NSString *place) {
    return [[place dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
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

// The absolute paths of the places this process keyed last, by their place
// hash, for a caller with a key and no URL. A ring of the newest.
enum { kVibePreviousPathCount = 1024 };
static os_unfair_lock sPreviousLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSString *> *sPreviousPaths;
static NSString *__strong sPreviousOrder[kVibePreviousPathCount];
static NSUInteger sPreviousNext;

static void VibeNotePreviousPath(NSString *hash, NSString *path) {
    os_unfair_lock_lock(&sPreviousLock);
    if (!sPreviousPaths) {
        sPreviousPaths = [NSMutableDictionary dictionaryWithCapacity:kVibePreviousPathCount];
    }
    if (!sPreviousPaths[hash]) {
        NSString *evicted = sPreviousOrder[sPreviousNext];
        if (evicted) {
            [sPreviousPaths removeObjectForKey:evicted];
        }
        sPreviousOrder[sPreviousNext] = hash;
        sPreviousNext = (sPreviousNext + 1) % kVibePreviousPathCount;
    }
    sPreviousPaths[hash] = path;
    os_unfair_lock_unlock(&sPreviousLock);
}

// key with its place hash replaced by the hash of path, as keys were made
// before CH32. nil when they are equal, or key is no cache key.
static NSString *VibePreviousKey(NSString *key, NSString *path) {
    NSRange range = VibeKeyHashRange(key);
    if (range.location == NSNotFound || !path) {
        return nil;
    }
    NSString *previous = VibePlaceHash(path);
    if ([[key substringWithRange:range] isEqualToString:previous]) {
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
    return [[path dataUsingEncoding:NSUTF8StringEncoding] sha1Hex];
}

- (nullable NSString *)cacheKey {
    return [self cacheKeyWithStat:NULL];
}

- (nullable NSString *)previousCacheKeyForKey:(NSString *)key {
    return VibePreviousKey(key, [self.path stringByResolvingSymlinksInPath]);
}

+ (nullable NSString *)previousCacheKeyForKey:(NSString *)key {
    NSRange range = VibeKeyHashRange(key);
    if (range.location == NSNotFound) {
        return nil;
    }
    os_unfair_lock_lock(&sPreviousLock);
    NSString *path = sPreviousPaths[[key substringWithRange:range]];
    os_unfair_lock_unlock(&sPreviousLock);
    return VibePreviousKey(key, path);
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
    NSString *place = VibeKeyPlace(path, st.st_dev);
    NSString *hex = VibePlaceHash(place);
    if (place != path) {
        VibeNotePreviousPath(hex, path);
    }
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
