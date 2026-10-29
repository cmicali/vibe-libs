//
//  VibeMetadataRead.h
//  vibe-libs
//
//  One file's answer from AudioTrackMetadataCache's readMetadataOfURLs:, and
//  what that read may open.
//

#import <Foundation/Foundation.h>

@class AudioTrackMetadata;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeMetadataReadPolicy) {
    // The disk cache, then a parse of a file on this device. A placeholder,
    // a provider's or a remote one, gets the cache alone. The parse runs with
    // materialization off for its thread, so a file evicted after the check
    // fails to read rather than downloads.
    VibeMetadataReadPolicyLocal,
    // The disk cache alone. The file is never opened.
    VibeMetadataReadPolicyCacheOnly,
};

typedef NS_ENUM(NSInteger, VibeMetadataReadOutcome) {
    // The file's tags, from the cache or a parse.
    VibeMetadataReadOutcomeRead,
    // No file: its stat failed.
    VibeMetadataReadOutcomeMissing,
    // The policy allowed the cache alone, and it had no entry for this
    // version: a placeholder, or any file under CacheOnly.
    VibeMetadataReadOutcomeCacheMiss,
    // The file could not be opened, or is not a regular file. error is the
    // open's, or EFTYPE for a FIFO, a directory, or a device.
    VibeMetadataReadOutcomeUnreadable,
    // Neither TagLib nor CoreAudio read it. metadata is the fallback: the
    // file name's title and any facts read before the failure. Not cached.
    VibeMetadataReadOutcomeNotParsed,
    // The file changed during the parse. Nothing is cached. Read it again.
    VibeMetadataReadOutcomeChanged,
    // The read was cancelled before this file began.
    VibeMetadataReadOutcomeCancelled,
};

@interface VibeMetadataReadResult : NSObject

// As the caller passed it.
@property (nonatomic, readonly, copy) NSURL *url;
@property (nonatomic, readonly) VibeMetadataReadOutcome outcome;
// The version read: the file's NSURL+Hash cacheKey when the read began. nil
// when Missing or Cancelled.
@property (nonatomic, readonly, copy, nullable) NSString *cacheKey;
// Read's tags, or NotParsed's fallback. nil otherwise.
@property (nonatomic, readonly, strong, nullable) AudioTrackMetadata *metadata;
// Read from the disk cache, with no parse.
@property (nonatomic, readonly) BOOL fromCache;
// Unreadable's POSIX error.
@property (nonatomic, readonly, strong, nullable) NSError *error;

// Public, so a client's stand-in reader can answer as this one does.
- (instancetype)initWithURL:(NSURL *)url
                    outcome:(VibeMetadataReadOutcome)outcome
                   cacheKey:(nullable NSString *)cacheKey
                   metadata:(nullable AudioTrackMetadata *)metadata
                  fromCache:(BOOL)fromCache
                      error:(nullable NSError *)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
