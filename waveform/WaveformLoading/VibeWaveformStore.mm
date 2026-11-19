//
//  VibeWaveformStore.mm
//  vibe-libs
//

#import "VibeWaveformStore.h"
#import "AudioWaveform.h"
#import "VibeMacros.h"

#import <os/lock.h>
#import <stdatomic.h>

// The PINCache store's entries were all of this format: its name carried it.
static const NSInteger VibeWaveformLegacyFormat = 7;
// PINDiskCache names a store's directory "<prefix>.<name>".
static NSString *const VibeWaveformLegacyPrefix = @"com.pinterest.PINDiskCache.";
static NSString *const VibeWaveformLegacyFamily = @"audio_waveform_cache";
static NSString *const VibeWaveformRemovedMark = @" removed ";

// An open that finds the folder still held waits this long for the store
// that holds it to finish closing.
static const int VibeWaveformOpenAttempts = 20;
static const useconds_t VibeWaveformOpenRetryMicroseconds = 50 * 1000;

#if DEBUG
static atomic_bool VibeWaveformImportsHeld;
#endif

@interface VibeWaveformStore ()
// The old store's directory until the import ends. Any thread.
@property (nonatomic, copy, nullable) NSString *legacyDirectory;
@end

@implementation VibeWaveformStore {
    // Guards _legacyDirectory. A lock of the store's own, which the thread
    // sanitizer sees, rather than an atomic property's.
    os_unfair_lock _legacyLock;
    NSString *_legacyDirectory;
}

- (nullable NSString *)legacyDirectory {
    os_unfair_lock_lock(&_legacyLock);
    NSString *directory = _legacyDirectory;
    os_unfair_lock_unlock(&_legacyLock);
    return directory;
}

- (void)setLegacyDirectory:(nullable NSString *)directory {
    directory = [directory copy];
    os_unfair_lock_lock(&_legacyLock);
    _legacyDirectory = directory;
    os_unfair_lock_unlock(&_legacyLock);
}

// The old store's directory, and no more import: the one caller that gets it
// removes it.
- (nullable NSString *)takeLegacyDirectory {
    os_unfair_lock_lock(&_legacyLock);
    NSString *directory = _legacyDirectory;
    _legacyDirectory = nil;
    os_unfair_lock_unlock(&_legacyLock);
    return directory;
}

+ (NSString *)name {
    // The format is on each row (CH15), so the name never changes with it.
    return @"audio_waveforms";
}

+ (NSString *)legacyName {
    return [NSString stringWithFormat:@"%@_v%ld", VibeWaveformLegacyFamily, (long)VibeWaveformLegacyFormat];
}

+ (instancetype)storeUnderRoot:(NSString *)rootPath {
    NSString *root = rootPath
            ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMapTable<NSString *, VibeWaveformStore *> *open;
    os_unfair_lock_lock(&lock);
    if (!open) {
        open = [NSMapTable strongToWeakObjectsMapTable];
    }
    VibeWaveformStore *store = root ? [open objectForKey:root] : nil;
    if (!store) {
        store = [[VibeWaveformStore alloc] initWithRoot:root];
        if (store.entries) {
            [open setObject:store forKey:root];
        }
    }
    os_unfair_lock_unlock(&lock);
    return store;
}

- (instancetype)initWithRoot:(nullable NSString *)root {
    self = [super init];
    if (self) {
        _legacyLock = OS_UNFAIR_LOCK_INIT;
        // A store that just let go of its last user may still be closing.
        for (int attempt = 0; root && !_entries && attempt < VibeWaveformOpenAttempts; attempt++) {
            if (attempt > 0) {
                usleep(VibeWaveformOpenRetryMicroseconds);
            }
            _entries = [VibeCacheStore storeWithName:VibeWaveformStore.name rootPath:root];
        }
        if (!_entries) {
            LogError(@"The waveform store would not open; waveforms are not kept");
            return self;
        }
        NSString *legacy = [root stringByAppendingPathComponent:
                [VibeWaveformLegacyPrefix stringByAppendingString:VibeWaveformStore.legacyName]];
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:legacy isDirectory:&isDirectory] && isDirectory) {
            self.legacyDirectory = legacy;
        }
        // In the background, so the open stays a few ms. A quit, or the
        // store's last user letting go, cuts it short, and the next open
        // carries on from the files still there.
        __weak VibeWaveformStore *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            [VibeWaveformStore removeOlderStoresUnder:root];
            [VibeWaveformStore importFrom:legacy into:weakSelf];
        });
    }
    return self;
}

- (BOOL)isImporting {
    return self.legacyDirectory != nil;
}

// The PINCache stores of formats before the legacy one, which an app's
// removal of other versions no longer names, since this store's name is of
// another family, and an old store renamed aside that a quit left.
+ (void)removeOlderStoresUnder:(NSString *)root {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *family = [VibeWaveformLegacyPrefix stringByAppendingString:VibeWaveformLegacyFamily];
    NSString *legacy = [VibeWaveformLegacyPrefix stringByAppendingString:VibeWaveformStore.legacyName];
    for (NSString *name in [fileManager contentsOfDirectoryAtPath:root error:nil]) {
        NSString *suffix = [name hasPrefix:family] ? [name substringFromIndex:family.length] : nil;
        BOOL version = suffix && (suffix.length == 0
                || [suffix rangeOfString:@"^[ _]v[0-9]+$" options:NSRegularExpressionSearch].location != NSNotFound);
        // A folder renamed aside for removal, which a quit left.
        BOOL aside = suffix && [suffix containsString:VibeWaveformRemovedMark];
        if ((version || aside) && ![name isEqualToString:legacy]) {
            [fileManager removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];
        }
    }
}

// CH19: each file is listed where it lands, by a rename, dated by its last
// use as PINDiskCache recorded it. A file whose key is already filed here is
// older than that entry, and goes with the folder.
+ (void)importFrom:(NSString *)legacy into:(__weak VibeWaveformStore *)weakStore {
    if (!weakStore.legacyDirectory) {
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
            if (!store.legacyDirectory) {
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
    if ([weakStore takeLegacyDirectory]) {
        [VibeWaveformStore removeLegacyDirectory:legacy];
        LogInfo(@"Waveform store: imported %lu entries from %@", (unsigned long)imported, VibeWaveformStore.legacyName);
    }
}

// Renamed aside first, so a lookup or the import that still holds the path
// finds nothing there.
+ (void)removeLegacyDirectory:(NSString *)legacy {
    NSString *aside = [legacy stringByAppendingFormat:@"%@%@", VibeWaveformRemovedMark, NSUUID.UUID.UUIDString];
    NSString *doomed = rename(legacy.fileSystemRepresentation, aside.fileSystemRepresentation) == 0 ? aside : legacy;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        [NSFileManager.defaultManager removeItemAtPath:doomed error:nil];
    });
}

// The old store's file for key, as PINDiskCache encodes a key.
- (nullable NSString *)legacyPathForKey:(NSString *)key {
    NSString *legacy = self.legacyDirectory;
    if (!legacy) {
        return nil;
    }
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [[NSCharacterSet characterSetWithCharactersInString:@".:/%"] invertedSet];
    });
    NSString *name = [key stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return name.length ? [legacy stringByAppendingPathComponent:name] : nil;
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
    if ([self hasEntryForKey:newKey]) {
        return NO;
    }
    return [self.entries moveEntryFromKey:oldKey toKey:newKey] || [self adoptLegacyEntryForKey:oldKey as:newKey];
}

- (void)removeAll {
    NSString *legacy = [self takeLegacyDirectory];
    if (legacy) {
        [VibeWaveformStore removeLegacyDirectory:legacy];
    }
    VibeCacheStore *entries = self.entries;
    if (!entries) {
        return;
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
