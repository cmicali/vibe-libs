//
//  FolderArtEntry.h
//  vibe-libs
//
//  Everything the resolver knows about one directory, so eviction and both
//  invalidations are one pass over one dictionary. The resolver owns every
//  transition, under its lock.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FolderArtEntry : NSObject

// The cover's full path, kNoArtMarker for "settled, it has none", or nil for
// "not looked at yet".
@property (nonatomic, copy, nullable) NSString *artPath;
// Unique for the resolver's life, 0 for none. Fences discovery and decode.
@property (nonatomic) uint64_t answerGeneration;
// The answerGeneration of the resolve claim currently held, or 0 for none.
@property (nonatomic) uint64_t resolving;
// Decodes in flight without a resolve claim (displayImageForAudioFilePath:).
@property (nonatomic) NSUInteger decoding;
// Dispatched but not yet on the queue.
@property (nonatomic) BOOL scheduled;
@property (nonatomic) uint64_t lastAccess;
// Settled artless for want of a grant; the only answers a grant change clears.
@property (nonatomic) BOOL settledWithoutGrant;
// A known cover whose scope ended: the path is kept for a later grant, and
// redraws stop retrying the read.
@property (nonatomic) BOOL readBlockedWithoutGrant;
// A known cover its provider holds in the cloud: the path is kept, nothing
// downloads it, and redraws stop retrying the read until an app says it
// arrived (artDidArriveInDirectories:). Cleared with readBlockedWithoutGrant,
// since a new answer is a new cover.
@property (nonatomic) BOOL inCloud;
// From a bulk open: resolve by one listing. A fact about the open, not an
// answer, so forgetSettledAnswer keeps it.
@property (nonatomic) BOOL preferListing;
@property (nonatomic) uint8_t readFailures;

@property (nonatomic, readonly) BOOL settled;
@property (nonatomic, readonly) BOOL settledEmpty;
// A known cover that no read may open now: no grant, or in the cloud.
@property (nonatomic, readonly) BOOL readsHeld;
// Work in flight fences on this entry, so eviction leaves it alone.
@property (nonatomic, readonly) BOOL busy;

- (void)forgetSettledAnswer;

@end

NS_ASSUME_NONNULL_END
