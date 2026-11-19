//
//  AudioTrackMetadataInternal.h
//  vibe-libs
//
//  Metadata-loader-only construction surface.
//

#import "AudioTrackMetadata.h"
#import "AudioTrackArtwork.h"

NS_ASSUME_NONNULL_BEGIN

// The artwork's read of the file's own art: TagLib's, by range for a remote
// placeholder. Blocking, so never called with the artwork monitor held.
FOUNDATION_EXPORT AudioTrackArtworkExtractor VibeTagLibArtExtractor(void);

@interface AudioTrackMetadata (Internal)

// Encodes the row thumbnail before publication. Original art bytes are
// released when that succeeds. The display-art rendition comes back through
// displayArtData for the cache write; the row never retains that rendition.
+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url
                         displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)displayArtData;
// The same, with the SHA-256 of the picture the file embeds, nil with none.
// The disk cache keeps the picture's thumbnail and rendition under it.
+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url
                         displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)displayArtData
                          pictureDigest:(NSData *_Nullable __autoreleasing *_Nullable)pictureDigest;

// The per-row art state, for the loader's storage round-trips: the archived
// display-art provider it stamps. Display callers use
// the facade's cachedArt/loadArt methods, never this. A method, not a property
// redeclaration — the class extension owns the property.
- (nullable AudioTrackArtwork *)artwork;

// The loader stamps the version it read before it installs or copies the
// metadata.
- (void)setCacheKey:(nullable NSString *)cacheKey;
// A cache-only read's answer from an older format's row.
- (void)setOlderFormat:(BOOL)olderFormat;

@end

// An answer the loader is done with: parsed, and not a cache-only read's
// older row, which the next read that may open the file replaces.
static inline BOOL VibeMetadataIsSettled(AudioTrackMetadata *_Nullable metadata) {
    return metadata.parsedOK && !metadata.olderFormat;
}

NS_ASSUME_NONNULL_END
