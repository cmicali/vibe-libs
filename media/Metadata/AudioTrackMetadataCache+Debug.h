//
//  AudioTrackMetadataCache+Debug.h
//  vibe-libs
//
//  What the health oracle reads from background metadata materialization.
//  The Debug category is declaration-only: the shipping class implements it.
//  DebugMaterialization is implemented in AudioTrackMetadataCache+Debug.m.
//

#import "AudioTrackMetadataCache.h"

@class AudioLoadingConfiguration;
@class AudioTrackMetadata;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataCache (Debug)

@property (nonatomic, readonly) AudioLoadingConfiguration *loadingConfiguration;

// Applies only to loaders constructed after this call. Existing work keeps
// its configuration snapshot.
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

@end

@interface AudioTrackMetadataCache (DebugMaterialization)

// Stage-2 file acquisitions queued, delayed or in flight. Zero at rest, so the
// stress driver scores it as a pending counter. Main thread, like the rest of
// the cache's surface.
- (NSUInteger)debugPendingBackgroundMaterializationCount;

// The coordinator's isForegroundTransferActive, which suspends background
// materialization. Stopped and settled must read NO.
- (BOOL)debugBackgroundMaterializationHeld;

// The priority lane's bookkeeping, rows by file name. Main thread.
- (NSDictionary *)debugPriorityLaneState;

// The scan lane apart from priority rows, so a scenario can prove stage-1
// completion and scan demand without subtracting aggregates.
- (NSDictionary *)debugScanLaneState;

// Replaces readMetadataOfURLs:'s parse, so a test can count parses or stand
// in for one. Before the first read only: the reading loader keeps the parser
// it was built with.
- (void)debugSetReadingFileParser:(nullable AudioTrackMetadata *_Nonnull (^)(NSURL *url))parser;

@end

NS_ASSUME_NONNULL_END
