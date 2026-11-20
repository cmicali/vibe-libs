//
//  VibeMetadataStore.m
//  vibe-libs
//

#import "VibeMetadataStore.h"
#import "VibeMetadataImport.h"
#import "NSURL+Hash.h"

#import <pthread.h>
#import <stdlib.h>

const NSInteger VibeMetadataTagsFormat = 11;
const NSInteger VibeMetadataArtFormat = 1;
NSString *const VibeMetadataStoreName = @"Audio Track Metadata";

// The format of an entry a tag edit left with its picture alone. It never
// answers, so the next read parses the new tags.
static const NSInteger VibeMetadataArtOnlyFormat = 0;

static NSString *const VibeMetadataThumbnailPart = @"thumbnail";
static NSString *const VibeMetadataRenditionPart = @"rendition";

// The stores open in this process, by directory, and how many callers hold
// each. Under sRegistryLock, which an open and a close hold, so a store
// never opens while another closes on the same directory.
static pthread_mutex_t sRegistryLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, VibeMetadataStore *> *sStores;

NSData *VibeMetadataArchive(id<NSCoding> tags) {
    return [NSKeyedArchiver archivedDataWithRootObject:tags requiringSecureCoding:NO error:NULL];
}

id VibeMetadataUnarchive(NSData *archive, Class tagsClass) {
    // TRAP: insecure, as PINDiskCache's was, so a wrong root class skips the
    // class's own checks. Hence the class test, and the catch for an archive
    // the disk damaged.
    @try {
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:archive error:NULL];
        unarchiver.requiresSecureCoding = NO;
        id tags = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];
        return [tags isKindOfClass:tagsClass] ? tags : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

@implementation VibeMetadataStore {
    NSString *_directory;
    NSUInteger _checkouts;  // under sRegistryLock
    VibeMetadataImport *_import;
    // The budgets, by VibeMetadataCacheStore, under @synchronized(self).
    unsigned long long _byteLimits[VibeMetadataCacheStoreDisplayArt + 1];
    NSTimeInterval _ageLimits[VibeMetadataCacheStoreDisplayArt + 1];
}

// The registry's key: the root's real path, made first, then the store's
// name. TRAP: stringByStandardizingPath strips /private only from a path that
// exists, so a key made before the store's folder named another store after
// it, whose open then failed on the folder's lock.
static NSString *VibeMetadataStoreDirectory(NSString *root) {
    if (!root) {
        return nil;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    NSString *real = realpath(root.fileSystemRepresentation, resolved) ? @(resolved) : root;
    return [real stringByAppendingPathComponent:VibeMetadataStoreName];
}

+ (VibeMetadataStore *)checkOutStoreUnderRootPath:(NSString *)rootPath {
    NSString *root = rootPath
            ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = VibeMetadataStoreDirectory(root);
    pthread_mutex_lock(&sRegistryLock);
    if (!sStores) {
        sStores = [NSMutableDictionary dictionary];
    }
    VibeMetadataStore *store = directory ? sStores[directory] : nil;
    if (!store) {
        store = [[VibeMetadataStore alloc] initWithRoot:root directory:directory];
        if (directory) {
            sStores[directory] = store;
        }
    }
    store->_checkouts++;
    pthread_mutex_unlock(&sRegistryLock);
    return store;
}

- (instancetype)initWithRoot:(NSString *)root directory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = [directory copy];
        _cacheStore = directory ? [[VibeCacheStore alloc] initWithDirectory:directory] : nil;
        for (int budget = 0; budget <= VibeMetadataCacheStoreDisplayArt; budget++) {
            _byteLimits[budget] = VibeCacheStore.defaultByteLimit;
            _ageLimits[budget] = VibeCacheStore.defaultAgeLimit;
        }
        [self applyLimits];
        if (_cacheStore && root) {
            _import = [VibeMetadataImport importUnderRootPath:root];
            [_import startInto:self];
        }
    }
    return self;
}

- (void)checkIn {
    pthread_mutex_lock(&sRegistryLock);
    if (_checkouts > 0 && --_checkouts == 0) {
        [_import cancel];
        [_cacheStore close];
        if (_directory && sStores[_directory] == self) {
            [sStores removeObjectForKey:_directory];
        }
    }
    pthread_mutex_unlock(&sRegistryLock);
}

// MARK: Entries

- (VibeCacheHit *)tagsHitForKey:(NSString *)key acceptingOlder:(BOOL)acceptingOlder {
    VibeCacheHit *hit = [_cacheStore hitForKey:key acceptingFormatsUpTo:VibeMetadataTagsFormat];
    if (!hit && [_import importKey:key into:self]) {
        hit = [_cacheStore hitForKey:key acceptingFormatsUpTo:VibeMetadataTagsFormat];
    }
    if (!hit || hit.format == VibeMetadataArtOnlyFormat || (hit.older && !acceptingOlder)) {
        return nil;
    }
    return hit;
}

// CH34: an entry may be under a previous key during an import, whose entries
// keep the old stores' keys, and until one would have aged out.
- (BOOL)mayHoldPreviousKeys {
    return _import.importing || [_cacheStore mayHoldEntriesFromBeforeMark:VibeCacheKeyPlaceMark];
}

// Moves previous's entry to key, which holds none, from the old stores
// during an import. NO when previous has none.
- (BOOL)moveEntryFromPreviousKey:(nullable NSString *)previous toKey:(NSString *)key {
    if (!previous || (![_cacheStore hasEntryForKey:previous] && ![_import importKey:previous into:self])) {
        return NO;
    }
    return [_cacheStore moveEntryFromKey:previous toKey:key];
}

- (VibeCacheHit *)tagsHitForKey:(NSString *)key url:(NSURL *)url acceptingOlder:(BOOL)acceptingOlder {
    VibeCacheHit *hit = [self tagsHitForKey:key acceptingOlder:acceptingOlder];
    if (hit || !url || ![self mayHoldPreviousKeys]) {
        return hit;
    }
    return [self moveEntryFromPreviousKey:[url previousCacheKeyForKey:key] toKey:key]
            ? [self tagsHitForKey:key acceptingOlder:acceptingOlder] : nil;
}

- (NSString *)fileTags:(id<NSCoding>)tags
             thumbnail:(NSData *)thumbnail
             rendition:(NSData *)rendition
           pictureName:(NSString *)pictureName
                forKey:(NSString *)key {
    NSData *archive = _cacheStore && tags ? VibeMetadataArchive(tags) : nil;
    return archive ? [self fileArchive:archive thumbnail:thumbnail rendition:rendition pictureName:pictureName
                                forKey:key] : nil;
}

- (NSString *)fileArchive:(NSData *)archive
                thumbnail:(NSData *)thumbnail
                rendition:(NSData *)rendition
              pictureName:(NSString *)pictureName
                   forKey:(NSString *)key {
    VibeCacheStore *store = _cacheStore;
    if (!store || !archive || !key) {
        return nil;
    }
    NSString *name = pictureName;
    if (!name && (rendition || thumbnail)) {
        name = [VibeMetadataStore nameOfPictureWithDigest:(rendition ?: thumbnail).sha256Digest];
    }
    if (!name) {
        [store setData:archive forKey:key format:VibeMetadataTagsFormat sharedName:nil];
        return nil;
    }
    NSMutableDictionary<NSString *, NSData *> *parts = [NSMutableDictionary dictionary];
    parts[VibeMetadataThumbnailPart] = thumbnail;
    parts[VibeMetadataRenditionPart] = rendition;
    [store setData:archive forKey:key format:VibeMetadataTagsFormat sharedName:name missingSharedParts:parts
        partFormat:VibeMetadataArtFormat];
    return name;
}

- (void)removeEntryForKey:(NSString *)key {
    [_cacheStore removeEntryForKey:key];
}

- (void)moveEntryOfRetaggedFileFromKey:(NSString *)oldKey toKey:(NSString *)newKey artChanged:(BOOL)artChanged {
    VibeCacheStore *store = _cacheStore;
    // An entry only the old stores hold moves as one the store holds, and
    // one under the old version's previous key moves to its key first. The
    // app made oldKey just before its write, so this process knows its
    // previous key.
    if (![store hasEntryForKey:oldKey] && ![_import importKey:oldKey into:self] && [self mayHoldPreviousKeys]) {
        [self moveEntryFromPreviousKey:[NSURL previousCacheKeyForKey:oldKey] toKey:oldKey];
    }
    BOOL sameKey = [oldKey isEqualToString:newKey];
    if (!sameKey && [store hasEntryForKey:newKey]) {
        [store removeEntryForKey:oldKey];
        return;
    }
    NSString *name = artChanged ? nil : [store hitForKey:oldKey acceptingFormatsUpTo:VibeMetadataTagsFormat].sharedName;
    if (name) {
        // Written while the old entry still names the picture, so it stays.
        [store setData:[NSData data] forKey:newKey format:VibeMetadataArtOnlyFormat sharedName:name];
    }
    if (!name || !sameKey) {
        [store removeEntryForKey:oldKey];
    }
}

// MARK: Pictures

- (NSData *)thumbnailOfPicture:(NSString *)name {
    return [_cacheStore sharedHitForName:name part:VibeMetadataThumbnailPart
                    acceptingFormatsUpTo:VibeMetadataArtFormat].data;
}

- (NSData *)renditionOfPicture:(NSString *)name {
    return [_cacheStore sharedHitForName:name part:VibeMetadataRenditionPart
                    acceptingFormatsUpTo:VibeMetadataArtFormat].data;
}

+ (NSString *)nameOfPictureWithDigest:(NSData *)digest {
    return digest.lowercaseHex;
}

// MARK: The whole store

- (void)setByteLimit:(unsigned long long)byteLimit
            ageLimit:(NSTimeInterval)ageLimit
           forBudget:(VibeMetadataCacheStore)budget {
    if (budget < VibeMetadataCacheStoreTags || budget > VibeMetadataCacheStoreDisplayArt) {
        return;
    }
    @synchronized (self) {
        _byteLimits[budget] = byteLimit;
        _ageLimits[budget] = ageLimit;
        [self applyLimits];
    }
}

// The tags and the thumbnails share the store's byte limit, and the
// renditions have their own, so art never pushes out an entry (CH7). Every
// row ages by the longest age limit.
- (void)applyLimits {
    unsigned long long tags = _byteLimits[VibeMetadataCacheStoreTags];
    unsigned long long thumbnails = _byteLimits[VibeMetadataCacheStoreThumbnails];
    NSTimeInterval age = 0;
    BOOL anyAge = YES;
    for (int budget = 0; budget <= VibeMetadataCacheStoreDisplayArt; budget++) {
        anyAge = anyAge && _ageLimits[budget] > 0;
        age = MAX(age, _ageLimits[budget]);
    }
    _cacheStore.byteLimit = tags > 0 && thumbnails > 0 ? tags + thumbnails : 0;
    [_cacheStore setByteLimit:_byteLimits[VibeMetadataCacheStoreDisplayArt] ofSharedPart:VibeMetadataRenditionPart];
    _cacheStore.ageLimit = anyAge ? age : 0;
}

- (VibeCacheUsage)usage {
    VibeCacheStore *store = _cacheStore;
    return store ? store.usage : (VibeCacheUsage){0, 0, 0};
}

+ (NSString *)thumbnailPart {
    return VibeMetadataThumbnailPart;
}

+ (NSString *)renditionPart {
    return VibeMetadataRenditionPart;
}

- (void)performAfterImportForTesting:(dispatch_block_t)block {
#if DEBUG
    if (_import) {
        [_import performWhenFinishedForTesting:block];
    } else {
        block();
    }
#endif
}

- (void)removeAll {
    [_import cancelAndRemoveOldStores];
    VibeCacheStore *store = _cacheStore;
    if (!store) {
        return;
    }
    dispatch_semaphore_t emptied = dispatch_semaphore_create(0);
    [store removeAllWithCompletion:^{
        dispatch_semaphore_signal(emptied);
    }];
    dispatch_semaphore_wait(emptied, DISPATCH_TIME_FOREVER);
}

@end
