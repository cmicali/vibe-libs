//
//  AudioTrackMetadataCache.h
//  vibe-libs
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataHolder.h"
#import "VibeMetadataRead.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioTrackMetadataCacheDelegate;

@interface AudioTrackMetadataCache : NSObject

@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

// The versioned store names. The tags, the 128 px row thumbnails, and the
// display-art renditions each have a store, and each store its own budget.
+ (NSString *)cacheName;
+ (NSString *)thumbnailCacheName;
+ (NSString *)displayArtCacheName;
// All three, which an app passes to remove older stores.
+ (NSArray<NSString *> *)cacheNames;

// The disk cache under rootPath. Nil is the user's Caches directory, which
// init uses. Another app passes its own path, or an app group's to share it.
- (instancetype)initWithRootPath:(nullable NSString *)rootPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

- (void)loadMetadata:(NSArray<id<AudioTrackMetadataHolder>> *)tracks;

// Rows whose audio is not on the device: the disk cache alone, so a hit
// delivers as loadMetadata:'s do and a miss reads nothing and downloads
// nothing. Apart from the scan, so loadMetadata: and cancelScan never drop
// it. Main thread only.
- (void)loadCachedMetadata:(NSArray<id<AudioTrackMetadataHolder>> *)tracks;

// Tags for files a client tracks itself, such as a library's index, by URL
// and with no holder. Apart from the sweep: loadMetadata: and cancelScan
// never touch it, and it joins no sweep's parse. Each URL is answered once,
// in any order, on deliveryQueue, which must be serial. completion runs there
// after the last answer. Each file is read from the disk cache, then parsed
// under policy, and a successful parse is filed in the cache. The parses run
// at the configured local parse concurrency, at utility QoS. A URL given
// twice is read twice. Cancelling the progress answers each file not begun
// as Cancelled. A parse already begun finishes. Nothing is held once
// completion has run. Any thread.
- (NSProgress *)readMetadataOfURLs:(NSArray<NSURL *> *)urls
                            policy:(VibeMetadataReadPolicy)policy
                     deliveryQueue:(dispatch_queue_t)deliveryQueue
                            result:(void (^)(VibeMetadataReadResult *result))result
                        completion:(dispatch_block_t)completion;

// Cancels the scan and releases its loader, which holds every queued track.
// For a playlist that is closed or replaced. Main thread only.
- (void)cancelScan;

// The track the user just started, ahead of the scan: a cache hit publishes
// at user-initiated QoS. A miss takes a MetadataPriority claim or reads a
// remote placeholder by range. A claim can join a same-path foreground open.
// A no-op once parsed, so cheap on every start.
// Main thread only.
- (void)loadMetadataNow:(id<AudioTrackMetadataHolder>)track;

// A removed row's queued scan work, so it spends no transfer; an undo
// re-requests through loadMetadataNow:. In-flight work settles and the
// receivers drop its delivery. Main thread only.
- (void)abandonQueuedTrack:(id<AudioTrackMetadataHolder>)track;

// Ranks the pending scan by these tracks, first first: the playlist's
// neighborhoodTracks, which follow shuffle. An app calls it when its current
// track changes. Main thread only.
- (void)setNeighborhoodTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks;

// Empties all three stores. The completion fires on the cache's internal
// queue. A parse in flight cannot repopulate them, though its UI delivery
// still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// After a rewrite of a file's tags that kept its audio, as a tag edit's safe
// write does. oldKey is the file's cacheKey (NSURL+Hash) from before the
// write, and newKey from after it. Drops the tags filed under oldKey, so the
// next read parses the new tags. Moves the row thumbnail and the rendition to
// newKey, each as one rename of its file, or drops them when artChanged. An
// entry newKey already holds is kept, and the old one goes. An absent entry
// is no work. Equal keys, from a writer that kept the size and the date, also
// keep a parse in flight from filing the old tags under them. Calls run in
// the order made, on the cache's internal queue, and completion runs there.
// TRAP: this retires no memoized key. The app calls NSURL
// invalidateMemoizedCacheKeys once per batch, from the last completion,
// after every cache's moves, so a held row's next lookup stats the file.
// Safe while loads run. Any thread.
- (void)moveEntriesOfRetaggedFileFromKey:(NSString *)oldKey
                                   toKey:(NSString *)newKey
                              artChanged:(BOOL)artChanged
                              completion:(nullable dispatch_block_t)completion;

// All three stores', enumerated off the calling thread; the completion runs
// on main.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(id<AudioTrackMetadataHolder>)track;
@end

NS_ASSUME_NONNULL_END
