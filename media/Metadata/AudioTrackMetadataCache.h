//
//  AudioTrackMetadataCache.h
//  vibe-libs
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataHolder.h"
#import "VibeMetadataRead.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AudioTrackMetadataCacheDelegate;

// The three budgets an app sets. One store holds them all: the tags and the
// thumbnails share one limit, their sum, and the renditions have their own
// (setByteLimit:...).
typedef NS_ENUM(NSInteger, VibeMetadataCacheStore) {
    VibeMetadataCacheStoreTags,
    VibeMetadataCacheStoreThumbnails,
    VibeMetadataCacheStoreDisplayArt,
};

@interface AudioTrackMetadataCache : NSObject

@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

// The store's name. One store holds the tags, the 128 px row thumbnails, and
// the display-art renditions, so all three name it. Each row carries its
// format, so a format change keeps the name.
+ (NSString *)cacheName;
+ (NSString *)thumbnailCacheName;
+ (NSString *)displayArtCacheName;
// The store's name and the PINCache stores it imports, which an app passes
// to remove older stores. The import removes those itself once it is done.
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

// Empties the store, and removes the old stores an import has not reached.
// The completion fires on the cache's internal queue. A parse in flight
// cannot repopulate it, though its UI delivery still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// After a rewrite of a file's tags that kept its audio, as a tag edit's safe
// write does. oldKey is the file's cacheKey (NSURL+Hash) from before the
// write, and newKey from after it. Moves the file's entry to newKey with its
// tags dropped, so the next read parses the new tags. The entry names the
// same picture, so the row thumbnail and the rendition stay where they are,
// unless artChanged, when the entry goes, and the picture with it if no other
// entry names it. An entry newKey already holds is kept, and the old one
// goes. An absent entry is no work. Equal keys, from a writer that kept the size and the date, also
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

// One budget's limits, over files/DiskCache's defaults, which a budget keeps
// until its app sets others. The tags and the thumbnails share one byte
// limit, their sum, and the renditions have their own, so art never pushes
// out tags. Each trims by least recent use. Every row ages by the longest age
// limit, so an app that sets nothing gets 2 GiB for the tags and thumbnails,
// 1 GiB for the renditions, and 180 days. A budget of 0 is none: for the tags
// or the thumbnails, it lifts their shared limit.
// Calls run in the order made, on the cache's internal queue, once the store
// is built. The store then trims to them in the background. Any thread.
- (void)setByteLimit:(NSUInteger)byteLimit
            ageLimit:(NSTimeInterval)ageLimit
            forStore:(VibeMetadataCacheStore)store;

// The store's entries and picture parts, and their bytes, a sum the store
// keeps, so it reads one row. The completion runs on main.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(id<AudioTrackMetadataHolder>)track;
@end

NS_ASSUME_NONNULL_END
