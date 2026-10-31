//
//  AudioTrackMetadata.h
//  vibe-libs
//

#import <Foundation/Foundation.h>
#import "AudioFileFormat.h"
#import "PlatformTypes.h"
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on main after an evicted embedded thumbnail has been decoded again.
// The object is the AudioTrackMetadata whose cachedThumbnail is now non-nil.
FOUNDATION_EXPORT NSNotificationName const AudioTrackMetadataThumbnailDidLoadNotification;

@interface AudioTrackMetadata : NSObject <NSSecureCoding, NSCopying>

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Any field can be absent from the file or the cache entry. A failed parse
// keeps the filename title and any facts read before the failure.
@property (copy, nullable, readonly) NSString *title;
@property (copy, nullable, readonly) NSString *artist;
@property (copy, nullable, readonly) VibeAudioFileFormat fileType;
@property (copy, nullable, readonly) NSNumber *bitrate;
@property (copy, nullable, readonly) NSNumber *sampleRate;
@property (assign, readonly) NSTimeInterval duration;
// FLAC, ALAC, AIFF, WAV, W64 or CAF. A lossless bitrate is implied by the
// rate and depth, so the codec line leaves it out.
@property (readonly, getter=isLossless) BOOL lossless;

// The tagged tempo (ID3 TBPM, MP4 tmpo, Vorbis/FLAC BPM); 0 when untagged.
@property (assign, readonly) float bpm;

// The tagged key (ID3 TKEY, Vorbis/FLAC INITIALKEY, the MP4 initialkey atom).
// VibeMusicalKeyNone when untagged or unparseable; every init path must set
// it, since the zero default is C major.
@property (assign, readonly) VibeMusicalKey key;

// The album's tags, as tagged. Every number is 0 when untagged. The year is
// the date tag's leading year. A count comes from "3/12" or from its own tag.
@property (copy, nullable, readonly) NSString *album;
@property (copy, nullable, readonly) NSString *albumArtist;
@property (copy, nullable, readonly) NSString *genre;
@property (copy, nullable, readonly) NSString *composer;
@property (assign, readonly) NSInteger year;
@property (assign, readonly) NSInteger trackNumber;
@property (assign, readonly) NSInteger trackCount;
@property (assign, readonly) NSInteger discNumber;
@property (assign, readonly) NSInteger discCount;
@property (readonly, getter=isCompilation) BOOL compilation;

// The identifiers a file may carry: MusicBrainz's release and recording, and
// the recording's ISRC. nil when untagged.
@property (copy, nullable, readonly) NSString *musicBrainzReleaseID;
@property (copy, nullable, readonly) NSString *musicBrainzRecordingID;
@property (copy, nullable, readonly) NSString *isrc;

// The MD5 of a FLAC's decoded audio, from its STREAMINFO block. nil for
// every other format, and when the encoder wrote none.
@property (copy, nullable, readonly) NSData *audioMD5;

// The loudness tags, nil when untagged. Gains are in dB, and peaks are
// linear, with 1 at full scale. Each gain keeps its own reference level.
// ReplayGain's track and album gain and peak:
@property (copy, nullable, readonly) NSNumber *replayGainTrackGain;
@property (copy, nullable, readonly) NSNumber *replayGainTrackPeak;
@property (copy, nullable, readonly) NSNumber *replayGainAlbumGain;
@property (copy, nullable, readonly) NSNumber *replayGainAlbumPeak;
// Opus's R128 gains, toward -23 LUFS, on top of the header's output gain:
@property (copy, nullable, readonly) NSNumber *r128TrackGain;
@property (copy, nullable, readonly) NSNumber *r128AlbumGain;
// Apple's Sound Check, the gain its iTunNORM tag gives:
@property (copy, nullable, readonly) NSNumber *soundCheckGain;

// YES after a completed TagLib or CoreAudio parse. Never cache a NO instance:
// its fallback or partial facts would shadow real tags until the key changes.
@property (readonly) BOOL parsedOK;

// The item's cacheKey when these facts were read: the version they describe.
// The loader stamps it before installing them. It is not archived, because
// the cache entry is filed under it. nil when the file had no key.
@property (copy, nullable, readonly) NSString *cacheKey;

// Non-blocking: already-decoded art or nil, never a decode.
- (nullable VibeImage *)cachedArt;

// YES when full art still needs background work (a read or a decode).
- (BOOL)artNeedsLoad;

// For a track no longer shown at full size: drops the decoded image and the
// source bytes, keeps the thumbnail bytes, cancels parked work and re-arms the
// load. Without it every played track pins its decoded art. Main thread only.
- (void)discardDecodedArt;

// Tells unresolved work from artlessness. Main thread.
@property (nonatomic, readonly, getter=isArtLoadPending) BOOL artLoadPending;

// Admits one bounded full-art load when needed. stillWanted is checked on main
// at each cancellation edge; completion runs on main only for a current,
// still-wanted request.
- (void)loadArtIfNeededStillWanted:(BOOL (^)(void))stillWanted
                        completion:(void (^)(VibeImage *_Nullable art))completion;

// The file carries art of its own, as its parse found. Non-blocking. Tells
// a thumbnail still decoding from a file with none.
@property (nonatomic, readonly) BOOL hasEmbeddedArt;

// The 128px row thumbnail; safe while drawing. On a miss with compact bytes
// it admits one bounded off-main decode, returns nil, and posts
// AudioTrackMetadataThumbnailDidLoadNotification when the pixels land. Only
// the file's own thumbnail is archived, never a folder cover.
- (nullable VibeImage *)cachedThumbnail;

@end

NS_ASSUME_NONNULL_END
