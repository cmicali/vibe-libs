//
//  VibeMetadataImport.h
//  vibe-libs
//
//  Brings the PINDiskCache stores of the releases before VibeMetadataStore
//  into it, then removes them (CH19): the tags, the row thumbnails, and the
//  renditions, each a folder of one file per entry under the cache's root.
//  The files are read where they are, with no PINDiskCache, so the old
//  stores' count at launch never runs.
//
//  The import runs in the background, a while after the store opens. A miss
//  looks in the old stores before it parses, from the open on, so the change
//  costs no parse. An import cut short by a quit goes on at the next open,
//  past the entries it brought over already.
//

#import <Foundation/Foundation.h>

@class VibeMetadataStore;

NS_ASSUME_NONNULL_BEGIN

@interface VibeMetadataImport : NSObject

// The old stores' names, which an app's launch removal must keep until the
// import removes them.
@property (class, nonatomic, readonly) NSArray<NSString *> *oldStoreNames;

// Nil when none of the old stores is under root.
+ (nullable instancetype)importUnderRootPath:(NSString *)root;
- (instancetype)init NS_UNAVAILABLE;

// Starts the bulk import into store, which it holds weakly.
- (void)startInto:(VibeMetadataStore *)store;

// A miss's lookup: brings key's entry over, if an old store has it. NO when
// none does, or the import has ended. Any thread.
- (BOOL)importKey:(NSString *)key into:(VibeMetadataStore *)store;

// Stops, and keeps the old stores for the next open.
- (void)cancel;
// Stops, and removes the old stores, for a Clear. Blocks while it removes.
- (void)cancelAndRemoveOldStores;

// Test seams, empty outside DEBUG. The delay before the bulk import, 10 s
// unless set. A negative delay never starts it.
+ (void)setStartDelayForTesting:(NSTimeInterval)delay;
// Runs block once the bulk import has ended.
- (void)performWhenFinishedForTesting:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
