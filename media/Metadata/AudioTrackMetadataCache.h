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

// The versioned store name. An app reads it to remove older stores.
+ (NSString *)cacheName;

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

// The completion fires on the cache's internal queue. A parse in flight
// cannot repopulate it, though its UI delivery still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// Enumerated off the calling thread; the completion runs on main.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(id<AudioTrackMetadataHolder>)track;
@end

NS_ASSUME_NONNULL_END
