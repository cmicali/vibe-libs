//
//  AudioTrackMetadataCacheInternal.h
//  vibe-libs
//
//  What AudioTrackMetadataLoader needs from the cache that owns it, and the
//  loader the debug seam reads (AudioTrackMetadataCache+Debug.m).
//

#import "AudioTrackMetadataCache.h"
// Imported: a generic argument needs the real @interface.
#import "MetadataParseCoordinator.h"

@class PINCache;
@class AudioTrackMetadata;
@class AudioTrackMetadataLoader;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataCache () {
    AudioTrackMetadataLoader*   _currentLoader;
}
// The store, built on the cache's queue after init. A read before it exists
// builds it or waits for it there, so every lookup and write reaches it.
@property (nonatomic, readonly) PINCache *metadataCache;
// Bumped by invalidation. A parse captures it at start, skips its write if it
// moved and rechecks after, or a parse in flight during Clear Cache would
// repopulate the emptied cache.
- (uint64_t)cacheGeneration;
// One parse per standardized path, shared by every loader: duplicate rows and
// the scan and priority slots would otherwise each parse the same file.
@property (nonatomic, readonly) MetadataParseCoordinator<id<AudioTrackMetadataHolder>> *parseCoordinator;
// The reads' parser, nil for the real one. Debug's seam sets it before the
// first read builds the reading loader.
@property (atomic, copy, nullable) AudioTrackMetadata *_Nonnull (^readingFileParser)(NSURL *_Nonnull url);
@end

NS_ASSUME_NONNULL_END
