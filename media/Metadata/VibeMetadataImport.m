//
//  VibeMetadataImport.m
//  vibe-libs
//

#import "VibeMetadataImport.h"
#import "VibeMetadataStore.h"
#import "PINCache+VibeAudioCache.h"

#import <pthread.h>
#import <stdatomic.h>

// After an open, so a launch does none of it.
static const NSTimeInterval VibeMetadataImportDefaultDelay = 10;
static NSTimeInterval sStartDelay = VibeMetadataImportDefaultDelay;

// The bytes PINDiskCache archived in one of the art's stores.
static NSData *_Nullable VibeUnarchivedArt(NSString *path) {
    NSData *archive = [NSData dataWithContentsOfFile:path];
    return archive ? VibeMetadataUnarchive(archive, NSData.class) : nil;
}

@implementation VibeMetadataImport {
    NSString *_tags;
    NSString *_thumbnails;
    NSString *_renditions;
    dispatch_queue_t _queue;
    dispatch_group_t _running;
    // Held across one key's write, so a stop never lands inside one.
    pthread_mutex_t _lock;
    // Set under _lock. Read without it first, so a miss pays nothing once
    // the import has ended.
    atomic_bool _stopped;
}

+ (NSArray<NSString *> *)oldStoreNames {
    return @[@"Audio Track Metadata v11", @"Audio Track Thumbnails v1", @"Audio Track Display Art v1"];
}

// PINDiskCache named a store's folder "<prefix>.<name>".
+ (NSString *)folderOf:(NSString *)name under:(NSString *)root {
    return [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", VibeAudioCacheLegacyPrefix, name]];
}

+ (instancetype)importUnderRootPath:(NSString *)root {
    for (NSString *name in self.oldStoreNames) {
        if ([NSFileManager.defaultManager fileExistsAtPath:[self folderOf:name under:root]]) {
            return [[self alloc] initWithRoot:root];
        }
    }
    return nil;
}

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super init])) {
        NSArray<NSString *> *names = VibeMetadataImport.oldStoreNames;
        _tags = [VibeMetadataImport folderOf:names[0] under:root];
        _thumbnails = [VibeMetadataImport folderOf:names[1] under:root];
        _renditions = [VibeMetadataImport folderOf:names[2] under:root];
        _queue = dispatch_queue_create("vibe-libs.metadata.import",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_BACKGROUND, 0));
        _running = dispatch_group_create();
        pthread_mutex_init(&_lock, NULL);
    }
    return self;
}

- (void)dealloc {
    pthread_mutex_destroy(&_lock);
}

- (void)startInto:(VibeMetadataStore *)store {
    NSTimeInterval delay = sStartDelay;
    if (delay < 0) {
        return;
    }
    __weak VibeMetadataStore *weakStore = store;
    dispatch_group_enter(_running);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        VibeMetadataStore *strongStore = weakStore;
        if (strongStore) {
            [self runInto:strongStore];
        }
        dispatch_group_leave(self->_running);
    });
}

// Every entry the tag store holds that the new store doesn't, in the order
// the folder lists them. Art with no tags is left, since no read reaches it.
- (void)runInto:(VibeMetadataStore *)store {
    NSDirectoryEnumerator<NSURL *> *files =
            [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:_tags isDirectory:YES]
                               includingPropertiesForKeys:@[]
                                                  options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                                          | NSDirectoryEnumerationSkipsHiddenFiles
                                             errorHandler:nil];
    for (NSURL *file in files) {
        if (atomic_load(&_stopped)) {
            return;
        }
        @autoreleasepool {
            NSString *key = file.lastPathComponent.stringByRemovingPercentEncoding;
            if (key.length && ![store.cacheStore hasEntryForKey:key]) {
                [self importKey:key into:store];
            }
        }
    }
    [self stopRemovingOldStores:YES];
}

- (BOOL)importKey:(NSString *)key into:(VibeMetadataStore *)store {
    if (!key.length || atomic_load(&_stopped)) {
        return NO;
    }
    NSString *name = VibeAudioCacheLegacyFileName(key);
    NSData *tags = name ? [NSData dataWithContentsOfFile:[_tags stringByAppendingPathComponent:name]] : nil;
    if (!tags) {
        return NO;
    }
    NSData *thumbnail = VibeUnarchivedArt([_thumbnails stringByAppendingPathComponent:name]);
    NSData *rendition = VibeUnarchivedArt([_renditions stringByAppendingPathComponent:name]);
    // Two imports of one key, a miss's and the bulk's, write the same bytes.
    BOOL imported = NO;
    pthread_mutex_lock(&_lock);
    if (!atomic_load(&_stopped)) {
        // The tags' bytes are the same archive the new store keeps, so they
        // are copied as they are, and decoded only when read.
        [store fileArchive:tags thumbnail:thumbnail rendition:rendition pictureName:nil forKey:key];
        imported = YES;
    }
    pthread_mutex_unlock(&_lock);
    return imported;
}

- (void)cancel {
    [self stopRemovingOldStores:NO];
}

- (void)cancelAndRemoveOldStores {
    [self stopRemovingOldStores:YES];
}

- (void)stopRemovingOldStores:(BOOL)remove {
    pthread_mutex_lock(&_lock);
    atomic_store(&_stopped, true);
    pthread_mutex_unlock(&_lock);
    if (!remove) {
        return;
    }
    for (NSString *folder in @[_tags, _thumbnails, _renditions]) {
        [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
    }
}

+ (void)setStartDelayForTesting:(NSTimeInterval)delay {
#if DEBUG
    sStartDelay = delay;
#endif
}

- (void)performWhenFinishedForTesting:(dispatch_block_t)block {
#if DEBUG
    dispatch_group_notify(_running, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), block);
#endif
}

@end
