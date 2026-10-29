//
//  AudioTrackMetadataCache.m
//  vibe-libs
//

#import <stdatomic.h>

#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataLoader.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLoadingConfiguration.h"
#import "PINCache.h"
#import "PINCache+VibeAudioCache.h"
#import "AudioTrackMetadata.h"
#import "MetadataParseCoordinator.h"
#import "AudioTrackMetadataCache+Debug.h"

@interface AudioTrackMetadataCache ()
// Atomic: set on the cache's queue, read per track from the loader's workers.
@property (atomic, strong, nullable) PINCache *store;
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
}

- (uint64_t)cacheGeneration {
    return atomic_load_explicit(&_cacheGeneration, memory_order_relaxed);
}

+ (NSString *)cacheName {
    // The archive-format version: bump it whenever the archived fields, the
    // rendition or their meaning change, or stale entries live until their
    // cache key changes.
    // TRAP: an entry from before the tag fields (v7) must be a miss. It
    // decodes cleanly, with every field it lacks absent. So a hit would say
    // "untagged" for an album or a gain the file carries, until the file
    // changes. A new store name makes every old entry a miss, at the cost of
    // one parse of each file.
    return @"Audio Track Metadata v8";
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
        // Off main: constructing on main boosts PINCache's init-time disk scan
        // to user-initiated, which priority-inverts against the utility
        // workers. A load before this lands builds or waits for it
        // (metadataCache).
        dispatch_async(_cacheQueue, ^{
            [self storeOnQueue];
        });
    }
    return self;
}

// On _cacheQueue. The first block to ask builds the store, so nothing depends
// on which block the queue runs first. A block on the queue calls this, never
// metadataCache, whose dispatch_sync would deadlock there.
- (PINCache *)storeOnQueue {
    PINCache *store = self.store;
    if (!store) {
        store = [PINCache audioCacheWithName:AudioTrackMetadataCache.cacheName rootPath:_rootPath];
        self.store = store;
    }
    return store;
}

- (PINCache *)metadataCache {
    PINCache *store = self.store;
    if (!store) {
        // dispatch_sync lends the reader's QoS to the queue, and so to the
        // build. A group wait lends none. A block wait allows one waiter, and
        // several workers may wait here at once.
        __block PINCache *built = nil;
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
        [[self storeOnQueue] removeAllObjects];
        if (completion) {
            completion();
        }
    });
}

- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    dispatch_async(_cacheQueue, ^{
        [[self storeOnQueue] audioDiskUsageWithCompletion:completion];
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
    if (priorityTrack && !priorityTrack.metadata.parsedOK) {
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
    if (!track || track.metadata.parsedOK) {
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
