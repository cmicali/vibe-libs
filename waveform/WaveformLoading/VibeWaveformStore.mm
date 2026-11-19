//
//  VibeWaveformStore.mm
//  vibe-libs
//

#import "VibeWaveformStore.h"
#import "AudioWaveform.h"
#import "PINCache+VibeAudioCache.h"
#import "VibeLegacyCacheNames.h"
#import "VibeMacros.h"

#import <os/lock.h>
#import <stdatomic.h>

// The PINCache store's entries were all of this format: its name carried it.
static const NSInteger VibeWaveformLegacyFormat = 7;

// An open that finds the folder held, when no store under that root is
// closing, tries this many times more, a few ms apart: a store's last user
// can let go just before the registry sees it closing.
static const int VibeWaveformOpenRetries = 3;
static const useconds_t VibeWaveformOpenRetryMicroseconds = 10 * 1000;

#if DEBUG
static atomic_bool VibeWaveformImportsHeld;
#endif

// The open stores by root, and the roots whose store is closing. Under
// VibeWaveformRegistryLock.
static os_unfair_lock VibeWaveformRegistryLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSString *, VibeWaveformStore *> *VibeWaveformOpenStores;
static NSCountedSet<NSString *> *VibeWaveformClosingRoots;

@implementation VibeWaveformStore {
    NSString *_root;
    // The old store's directory, read while _importing is set.
    NSString *_legacyDirectory;
    atomic_bool _importing;
}

+ (NSString *)name {
    // The format is on each row (CH15), so the name never changes with it.
    return @"audio_waveforms";
}

+ (NSString *)legacyName {
    return [NSString stringWithFormat:@"audio_waveform_cache_v%ld", (long)VibeWaveformLegacyFormat];
}

+ (instancetype)storeUnderRoot:(NSString *)rootPath {
    NSString *root = rootPath
            ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    for (int retries = 0;; ) {
        os_unfair_lock_lock(&VibeWaveformRegistryLock);
        if (!VibeWaveformOpenStores) {
            VibeWaveformOpenStores = [NSMapTable strongToWeakObjectsMapTable];
            VibeWaveformClosingRoots = [NSCountedSet set];
        }
        VibeWaveformStore *store = root ? [VibeWaveformOpenStores objectForKey:root] : nil;
        BOOL closing = root && [VibeWaveformClosingRoots countForObject:root] > 0;
        if (!store && !closing) {
            store = [[VibeWaveformStore alloc] initWithRoot:root];
            if (store.entries) {
                [VibeWaveformOpenStores setObject:store forKey:root];
            }
        }
        os_unfair_lock_unlock(&VibeWaveformRegistryLock);
        if (store.entries || (store && retries++ >= VibeWaveformOpenRetries)) {
            if (!store.entries) {
                LogError(@"The waveform store would not open; waveforms are not kept");
            }
            return store;
        }
        // A store under this root is closing, and holds the folder until it has.
        usleep(VibeWaveformOpenRetryMicroseconds);
    }
}

- (instancetype)initWithRoot:(nullable NSString *)root {
    self = [super init];
    if (self) {
        _root = [root copy];
        _entries = root ? [VibeCacheStore storeWithName:VibeWaveformStore.name rootPath:root] : nil;
        if (!_entries) {
            return self;
        }
        NSString *legacy = VibeLegacyCacheFolder(root, VibeWaveformStore.legacyName);
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:legacy isDirectory:&isDirectory] && isDirectory) {
            _legacyDirectory = legacy;
            atomic_store(&_importing, true);
        }
        // In the background, so the open stays a few ms. The PINCache stores
        // of older formats go first: an app's removal of other versions no
        // longer names them, since this store's name is of another family.
        // A quit, or the store's last user letting go, cuts the import short,
        // and the next open carries on from the files still there.
        __weak VibeWaveformStore *weakSelf = self;
        [PINCache removeOtherAudioCacheVersionsKeeping:@[VibeWaveformStore.legacyName] rootPath:root completion:^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                [VibeWaveformStore importInto:weakSelf];
            });
        }];
    }
    return self;
}

- (void)dealloc {
    if (!_entries) {
        return;
    }
    // Closed here, so a new open under the root waits for the folder.
    os_unfair_lock_lock(&VibeWaveformRegistryLock);
    [VibeWaveformClosingRoots addObject:_root];
    os_unfair_lock_unlock(&VibeWaveformRegistryLock);
    [_entries close];
    os_unfair_lock_lock(&VibeWaveformRegistryLock);
    [VibeWaveformClosingRoots removeObject:_root];
    os_unfair_lock_unlock(&VibeWaveformRegistryLock);
}

- (BOOL)isImporting {
    return atomic_load(&_importing);
}

// Ends the import, once: YES for the one caller that then removes the old
// store.
- (BOOL)endImport {
    return atomic_exchange(&_importing, false);
}

// CH19: each file is listed where it lands, by a rename, dated by its last
// use as PINDiskCache recorded it. A file whose key is already filed here is
// older than that entry, and goes with the folder. The store is held only
// for each file, so its last user letting go stops the import.
+ (void)importInto:(__weak VibeWaveformStore *)weakStore {
    NSString *legacy = nil;
    @autoreleasepool {
        VibeWaveformStore *store = weakStore;
        legacy = store.importing ? store->_legacyDirectory : nil;
    }
    if (!legacy) {
        return;
    }
    NSDirectoryEnumerator<NSURL *> *files = [NSFileManager.defaultManager
            enumeratorAtURL:[NSURL fileURLWithPath:legacy isDirectory:YES]
            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
            options:NSDirectoryEnumerationSkipsSubdirectoryDescendants | NSDirectoryEnumerationSkipsHiddenFiles
            errorHandler:nil];
    NSUInteger imported = 0;
    for (NSURL *url in files) {
        @autoreleasepool {
#if DEBUG
            while (atomic_load(&VibeWaveformImportsHeld) && weakStore) {
                usleep(1000);
            }
#endif
            VibeWaveformStore *store = weakStore;
            // A Clear ended the import, or the store closed.
            if (!store.importing) {
                return;
            }
            NSString *key = url.lastPathComponent.stringByRemovingPercentEncoding;
            NSDate *used = nil;
            [url getResourceValue:&used forKey:NSURLContentModificationDateKey error:nil];
            if (key.length && [store.entries adoptFileAtPath:url.path forKey:key
                                                      format:VibeWaveformLegacyFormat lastUse:used]) {
                imported++;
            }
        }
    }
    VibeWaveformStore *store = weakStore;
    if ([store endImport]) {
        [store.entries removeFolderAtPath:legacy];
        LogInfo(@"Waveform store: imported %lu entries from %@", (unsigned long)imported, VibeWaveformStore.legacyName);
    }
}

// The old store's file for key during the import.
- (nullable NSString *)legacyPathForKey:(NSString *)key {
    NSString *name = self.importing ? VibeLegacyCacheFileName(key) : nil;
    return name ? [_legacyDirectory stringByAppendingPathComponent:name] : nil;
}

// Lists the old store's entry for key under storedKey, now. NO when the old
// store has none.
- (BOOL)adoptLegacyEntryForKey:(NSString *)key as:(NSString *)storedKey {
    NSString *path = [self legacyPathForKey:key];
    return path && [self.entries adoptFileAtPath:path forKey:storedKey format:VibeWaveformLegacyFormat lastUse:nil];
}

- (NSData *)dataForKey:(NSString *)key {
    VibeCacheHit *hit = [self.entries hitForKey:key format:kCodableAudioWaveformVersion];
    if (!hit && [self adoptLegacyEntryForKey:key as:key]) {
        hit = [self.entries hitForKey:key format:kCodableAudioWaveformVersion];
    }
    return hit.data;
}

- (void)setData:(NSData *)data forKey:(NSString *)key {
    [self.entries setData:data forKey:key format:kCodableAudioWaveformVersion sharedName:nil];
}

- (BOOL)hasEntryForKey:(NSString *)key {
    if ([self.entries hasEntryForKey:key]) {
        return YES;
    }
    NSString *path = [self legacyPathForKey:key];
    return path && [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (void)removeEntryForKey:(NSString *)key {
    [self.entries removeEntryForKey:key];
    NSString *path = [self legacyPathForKey:key];
    if (path) {
        unlink(path.fileSystemRepresentation);
    }
}

- (BOOL)moveEntryFromKey:(NSString *)oldKey toKey:(NSString *)newKey {
    // The store's move replaces an entry under newKey, which this keeps.
    if ([self hasEntryForKey:newKey]) {
        return NO;
    }
    return [self.entries moveEntryFromKey:oldKey toKey:newKey] || [self adoptLegacyEntryForKey:oldKey as:newKey];
}

- (void)setByteLimit:(unsigned long long)byteLimit ageLimit:(NSTimeInterval)ageLimit {
    self.entries.byteLimit = byteLimit;
    self.entries.ageLimit = ageLimit;
}

- (VibeCacheUsage)usage {
    return self.entries ? self.entries.usage : (VibeCacheUsage){};
}

- (void)removeAll {
    VibeCacheStore *entries = self.entries;
    if (!entries) {
        return;
    }
    if ([self endImport]) {
        [entries removeFolderAtPath:_legacyDirectory];
    }
    dispatch_semaphore_t emptied = dispatch_semaphore_create(0);
    [entries removeAllWithCompletion:^{
        dispatch_semaphore_signal(emptied);
    }];
    dispatch_semaphore_wait(emptied, DISPATCH_TIME_FOREVER);
}

+ (void)holdImportsForTesting:(BOOL)held {
#if DEBUG
    atomic_store(&VibeWaveformImportsHeld, held);
#endif
}

@end
