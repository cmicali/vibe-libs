//
//  AudioTrackMetadataCache.m
//  vibe-libs
//

#import <os/lock.h>
#import <stdatomic.h>

#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataLoader.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLoadingConfiguration.h"
#import "VibeMetadataStore.h"
#import "VibeMetadataImport.h"
#import "AudioTrackMetadataInternal.h"
#import "MetadataParseCoordinator.h"
#import "AudioTrackMetadataCache+Debug.h"

@interface AudioTrackMetadataCache ()
// Set on the cache's queue, read per track from the loader's workers. Its
// accessors take _storeLock, not an atomic property's lock, which is
// libobjc's own, and which Thread Sanitizer can't see.
@property (nonatomic, strong, nullable) VibeMetadataStore *store;
@property (nonatomic, readonly) AudioLoadingConfiguration *loadingConfiguration;
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
@end

@implementation AudioTrackMetadataCache {
    // loadCachedMetadata:'s, never cancelled: a miss is not asked again.
    AudioTrackMetadataLoader*   _cacheOnlyLoader;
    // readMetadataOfURLs:'s, built on the first read and never cancelled.
    // Guarded by @synchronized(self), since reads come from any thread.
    AudioTrackMetadataLoader*   _readingLoader;
    // Serializes construction, invalidation and disk usage at utility QoS.
    dispatch_queue_t            _cacheQueue;
    // The store's root, for whichever block on _cacheQueue builds it.
    NSString                    *_rootPath;
    atomic_uint_fast64_t        _cacheGeneration;
    // Kept here, not only on the loader, so a replacement loader inherits them.
    NSArray<NSURL *>            *_neighborhood;
    // Weak: never pins a departed playlist's track.
    __weak id<AudioTrackMetadataHolder> _lastPrioritizedTrack;
    AudioLoadingConfiguration   *_loadingConfiguration;
    os_unfair_lock              _storeLock;
    VibeMetadataStore           *_store;
}

- (nullable VibeMetadataStore *)store {
    os_unfair_lock_lock(&_storeLock);
    VibeMetadataStore *store = _store;
    os_unfair_lock_unlock(&_storeLock);
    return store;
}

- (void)setStore:(nullable VibeMetadataStore *)store {
    os_unfair_lock_lock(&_storeLock);
    _store = store;
    os_unfair_lock_unlock(&_storeLock);
}

- (uint64_t)cacheGeneration {
    return atomic_load_explicit(&_cacheGeneration, memory_order_relaxed);
}

+ (NSString *)cacheName {
    // One store holds the tags, the thumbnails, and the renditions. Each row
    // carries its format (VibeMetadataTagsFormat), so a format change keeps
    // the store's name and every entry in it.
    return VibeMetadataStoreName;
}

+ (NSString *)thumbnailCacheName {
    return VibeMetadataStoreName;
}

+ (NSString *)displayArtCacheName {
    return VibeMetadataStoreName;
}

+ (NSArray<NSString *> *)cacheNames {
    // With the PINCache stores the store imports, so an app's launch removal
    // keeps them until the import removes them itself, and still removes the
    // versions before them.
    return [@[self.cacheName] arrayByAddingObjectsFromArray:VibeMetadataImport.oldStoreNames];
}

- (instancetype)init {
    return [self initWithRootPath:nil];
}

- (instancetype)initWithRootPath:(NSString *)rootPath {
    self = [super init];
    if (self) {
        _loadingConfiguration = [[AudioLoadingConfiguration productionConfiguration] copy];
        _currentLoader = nil;
        _parseCoordinator = [[MetadataParseCoordinator alloc] init];
        _rootPath = [rootPath copy];
        _cacheQueue = dispatch_queue_create("vibe-libs.metadata.cache",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // Off main: the store's open takes a few milliseconds of disk work.
        // A load before this lands builds or waits for it (metadataCache).
        dispatch_async(_cacheQueue, ^{
            [self storeOnQueue];
        });
    }
    return self;
}

- (void)dealloc {
    [_store checkIn];
}

// On _cacheQueue. The first block to ask builds the store, so nothing
// depends on which block the queue runs first. A block on the queue calls
// this, never metadataCache, whose dispatch_sync would deadlock there.
- (VibeMetadataStore *)storeOnQueue {
    VibeMetadataStore *store = self.store;
    if (!store) {
        store = [VibeMetadataStore checkOutStoreUnderRootPath:_rootPath];
        self.store = store;
    }
    return store;
}

// The store, built or waited for. dispatch_sync lends the reader's QoS to
// the queue, and so to the build. A group wait lends none. A block wait
// allows one waiter, and several workers may wait here at once.
- (VibeMetadataStore *)metadataCache {
    VibeMetadataStore *store = self.store;
    if (!store) {
        __block VibeMetadataStore *built = nil;
        dispatch_sync(_cacheQueue, ^{
            built = [self storeOnQueue];
        });
        store = built;
    }
    return store;
}

- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    if (_loadingConfiguration == loadingConfiguration) {
        return;
    }
    // A loader snapshots its configuration; the next one built uses this.
    _loadingConfiguration = [loadingConfiguration copy];
}

- (void)invalidateWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_cacheQueue, ^{
        atomic_fetch_add_explicit(&self->_cacheGeneration, 1, memory_order_relaxed);
        [[self storeOnQueue] removeAll];
        if (completion) {
            completion();
        }
    });
}

- (void)moveEntriesOfRetaggedFileFromKey:(NSString *)oldKey
                                   toKey:(NSString *)newKey
                              artChanged:(BOOL)artChanged
                              completion:(dispatch_block_t)completion {
    NSParameterAssert(oldKey && newKey);
    oldKey = [oldKey copy];
    newKey = [newKey copy];
    // On the queue that invalidates, so an invalidation and a move never
    // interleave. A parse of the old version that files after this lands
    // files under a key no stat gives again.
    dispatch_async(_cacheQueue, ^{
        if ([oldKey isEqualToString:newKey]) {
            // TRAP: the key names the new tags as well as the old, so a parse
            // begun before the write would file the old ones under it for
            // good. The bump keeps every parse in flight from filing.
            atomic_fetch_add_explicit(&self->_cacheGeneration, 1, memory_order_relaxed);
        }
        [[self storeOnQueue] moveEntryOfRetaggedFileFromKey:oldKey toKey:newKey artChanged:artChanged];
        if (completion) {
            completion();
        }
    });
}

- (void)setByteLimit:(NSUInteger)byteLimit
            ageLimit:(NSTimeInterval)ageLimit
            forStore:(VibeMetadataCacheStore)store {
    dispatch_async(_cacheQueue, ^{
        [[self storeOnQueue] setByteLimit:byteLimit ageLimit:ageLimit forBudget:store];
    });
}

- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    dispatch_async(_cacheQueue, ^{
        // A sum the store keeps, so it reads one row.
        VibeCacheUsage usage = [[self storeOnQueue] usage];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(usage.entries + usage.sharedItems, usage.bytes);
        });
    });
}

- (void)cancelScan {
    // Release, not just cancel: the loader holds every queued track.
    [_currentLoader cancel];
    _currentLoader = nil;
}

-(void)loadMetadata:(NSArray<id<AudioTrackMetadataHolder>>*)tracks {
    [self cancelScan];
    if (!tracks.count) {
        return;
    }
    AudioTrackMetadataLoader* loader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                              delegate:self.delegate
                                                                   loadingConfiguration:_loadingConfiguration];
    _currentLoader = loader;
    [loader setNeighborhoodURLs:_neighborhood];
    // Carry the current track's priority across the replacement, which often
    // replaces a pre-sweep single-track loader. Before load:, so stage 1
    // dedupes against it.
    id<AudioTrackMetadataHolder> priorityTrack = _lastPrioritizedTrack;
    if (priorityTrack && !VibeMetadataIsSettled(priorityTrack.metadata)) {
        [loader prioritizeTrack:priorityTrack];
    }
    [loader load:tracks];
}

- (void)loadCachedMetadata:(NSArray<id<AudioTrackMetadataHolder>> *)tracks {
    if (!tracks.count) {
        return;
    }
    if (!_cacheOnlyLoader) {
        _cacheOnlyLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                   delegate:self.delegate
                                                       loadingConfiguration:_loadingConfiguration];
    }
    _cacheOnlyLoader.delegate = self.delegate;
    [_cacheOnlyLoader loadFromCacheOnly:[tracks copy]];
}

- (NSProgress *)readMetadataOfURLs:(NSArray<NSURL *> *)urls
                            policy:(VibeMetadataReadPolicy)policy
                     deliveryQueue:(dispatch_queue_t)deliveryQueue
                            result:(void (^)(VibeMetadataReadResult *result))result
                        completion:(dispatch_block_t)completion {
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:(int64_t)urls.count];
    AudioTrackMetadataLoader *loader;
    @synchronized (self) {
        if (!_readingLoader) {
            _readingLoader = [[AudioTrackMetadataLoader alloc]
                     initWithOwner:self
                          delegate:nil
              loadingConfiguration:_loadingConfiguration
        materializationCoordinator:[AudioFileMaterializationCoordinator sharedCoordinator]
                       cacheReader:nil
                        fileParser:self.readingFileParser];
        }
        loader = _readingLoader;
    }
    [loader readURLs:[urls copy] policy:policy progress:progress deliveryQueue:deliveryQueue
              result:result completion:completion];
    return progress;
}

- (void)abandonQueuedTrack:(id<AudioTrackMetadataHolder>)track {
    [_currentLoader abandonQueuedTrack:track];
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    _neighborhood = [urls copy];
    [_currentLoader setNeighborhoodURLs:_neighborhood];
}

- (void)setNeighborhoodTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id<AudioTrackMetadataHolder> track in tracks) {
        if (track.url) {
            [urls addObject:track.url];
        }
    }
    [self setNeighborhoodURLs:urls];
}

- (void)loadMetadataNow:(id<AudioTrackMetadataHolder>)track {
    if (!track || VibeMetadataIsSettled(track.metadata)) {
        return;
    }
    _lastPrioritizedTrack = track;
    if (!_currentLoader) {
        // No sweep yet: a loader over this one track, which the sweep
        // replaces wholesale (D10), re-prioritizing the track.
        _currentLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                 delegate:self.delegate
                                                     loadingConfiguration:_loadingConfiguration];
        [_currentLoader setNeighborhoodURLs:_neighborhood];
    }
    // The delegate may have been wired after the loader was built.
    _currentLoader.delegate = self.delegate;
    [_currentLoader prioritizeTrack:track];
}

@end
