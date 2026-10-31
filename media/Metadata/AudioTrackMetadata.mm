//
//  AudioTrackMetadata.mm
//  vibe-libs
//

#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioFileHandle.h"
#import "NSURL+FilenameTitle.h"
#import "AudioTrackArtwork.h"
#import "TagLibAudioFile.h"
#import "CloudFileMaterializer.h"
#import "PlaceholderFiles.h"
#import "PlatformImage.h"
#import "NSString+CPPStrings.h"
#import "MusicalKey.h"
#import "VibeMacros.h"

#import <AudioToolbox/AudioToolbox.h>

#include <exception>
#include <initializer_list>
#include <sys/stat.h>
#include <audioproperties.h>
#include <tpropertymap.h>
#include <flacfile.h>

NSNotificationName const AudioTrackMetadataThumbnailDidLoadNotification =
        @"AudioTrackMetadataThumbnailDidLoadNotification";

// Atomic: built on a worker, read on main.
@interface AudioTrackMetadata ()
@property (copy, nullable, readwrite) NSString *title;
@property (copy, nullable, readwrite) NSString *artist;
@property (copy, nullable, readwrite) VibeAudioFileFormat fileType;
@property (copy, nullable, readwrite) NSNumber *bitrate;
@property (copy, nullable, readwrite) NSNumber *sampleRate;
@property (assign, readwrite) NSTimeInterval duration;
@property (assign, readwrite) float bpm;
@property (assign, readwrite) VibeMusicalKey key;
@property (copy, nullable, readwrite) NSString *album;
@property (copy, nullable, readwrite) NSString *albumArtist;
@property (copy, nullable, readwrite) NSString *genre;
@property (copy, nullable, readwrite) NSString *composer;
@property (assign, readwrite) NSInteger year;
@property (assign, readwrite) NSInteger trackNumber;
@property (assign, readwrite) NSInteger trackCount;
@property (assign, readwrite) NSInteger discNumber;
@property (assign, readwrite) NSInteger discCount;
@property (assign, readwrite) BOOL compilation;
@property (copy, nullable, readwrite) NSString *musicBrainzReleaseID;
@property (copy, nullable, readwrite) NSString *musicBrainzRecordingID;
@property (copy, nullable, readwrite) NSString *isrc;
@property (copy, nullable, readwrite) NSData *audioMD5;
@property (copy, nullable, readwrite) NSNumber *replayGainTrackGain;
@property (copy, nullable, readwrite) NSNumber *replayGainTrackPeak;
@property (copy, nullable, readwrite) NSNumber *replayGainAlbumGain;
@property (copy, nullable, readwrite) NSNumber *replayGainAlbumPeak;
@property (copy, nullable, readwrite) NSNumber *r128TrackGain;
@property (copy, nullable, readwrite) NSNumber *r128AlbumGain;
@property (copy, nullable, readwrite) NSNumber *soundCheckGain;
@property (assign) BOOL parsedOK;
@property (copy, nullable, readwrite) NSString *cacheKey;
// Never nil on a live instance. A property, not a bare ivar: written on a
// worker and read on main, an unlocked pair TSan reports.
@property (strong, nullable) AudioTrackArtwork *artwork;
@end

// The reader for a remote placeholder, which the parse and the art read take
// by range instead of materializing the song (this piece's AGENTS.md, The
// scan). nil reads the file from disk. The root test comes before the stat,
// so a file under no remote root pays none.
static VibeTagByteRangeRead _Nullable VibeTagRangeReadForPath(NSString *path, uint64_t *length) {
    struct stat st;
    if (!VibePathIsUnderRemotePlaceholderRoot(path) || stat(path.UTF8String, &st) != 0
            || !VibeFileModeIsRemotePlaceholder(st.st_mode)) {
        return nil;
    }
    *length = (uint64_t)st.st_size;
    return [CloudFileMaterializer remoteReadForURL:[NSURL fileURLWithPath:path isDirectory:NO]];
}

AudioTrackArtworkExtractor VibeTagLibArtExtractor(void) {
    return ^VibeEmbeddedArtExtractionResult(NSString *path, NSData *__autoreleasing *artData) {
        if (!path) {
            return VibeEmbeddedArtExtractionReadFailed;
        }
        uint64_t length = 0;
        VibeTagByteRangeRead read = VibeTagRangeReadForPath(path, &length);
        NSData *art = nil;
        if (!VibeTagLibReadEmbeddedArt(path, read, length, &art)) {
            return VibeEmbeddedArtExtractionReadFailed;
        }
        if (!art) {
            return VibeEmbeddedArtExtractionNoArt;
        }
        if (artData) {
            *artData = art;
        }
        return VibeEmbeddedArtExtractionFoundArt;
    };
}

// A tag's text without surrounding whitespace, or nil when that leaves none.
static NSString * _Nullable trimmedTagText(id _Nullable value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed : nil;
}

// The first value of a tag, trimmed, or nil when that leaves none.
static NSString *_Nullable PropertyText(const TagLib::PropertyMap &properties, const char *key) {
    const TagLib::StringList values = properties.value(key);
    return values.isEmpty() ? nil : trimmedTagText([NSString stringWithStdString:values.front().to8Bit(true)]);
}

// The whole number a tag starts with, or 0 when it has none above 0.
static NSInteger LeadingCount(NSString *_Nullable text) {
    NSInteger value = 0;
    return text && [[NSScanner scannerWithString:text] scanInteger:&value] && value > 0 ? value : 0;
}

// A number and its count, from "3/12", or from a count tag of its own.
static void ReadNumberAndCount(const TagLib::PropertyMap &properties, const char *key,
                               std::initializer_list<const char *> countKeys, NSInteger *number, NSInteger *count) {
    NSString *text = PropertyText(properties, key);
    *number = LeadingCount(text);
    NSRange slash = text ? [text rangeOfString:@"/"] : NSMakeRange(NSNotFound, 0);
    *count = slash.location != NSNotFound ? LeadingCount([text substringFromIndex:NSMaxRange(slash)]) : 0;
    for (const char *countKey : countKeys) {
        if (*count == 0) *count = LeadingCount(PropertyText(properties, countKey));
    }
}

// The decimal a loudness tag starts with, as in "-6.54 dB", or nil.
static NSNumber *_Nullable LeadingDecimal(NSString *_Nullable text) {
    double value = 0;
    return text && [[NSScanner scannerWithString:text] scanDouble:&value] && isfinite(value) ? @(value) : nil;
}

// An R128 gain is a Q7.8 whole number of 1/256 dB.
static NSNumber *_Nullable R128Gain(NSString *_Nullable text) {
    NSInteger value = 0;
    if (!text || ![[NSScanner scannerWithString:text] scanInteger:&value] || value < INT16_MIN || value > INT16_MAX) {
        return nil;
    }
    return @(value / 256.0);
}

// iTunNORM is ten hex words. The first two are the left and right channels'
// gain against 1/1000 W. The louder channel sets the gain.
static NSNumber *_Nullable SoundCheckGain(NSString *_Nullable text) {
    unsigned int left = 0, right = 0;
    NSScanner *scanner = text ? [NSScanner scannerWithString:text] : nil;
    if (![scanner scanHexInt:&left] || ![scanner scanHexInt:&right] || MAX(left, right) == 0) {
        return nil;
    }
    return @(-10 * log10(MAX(left, right) / 1000.0));
}

@implementation AudioTrackMetadata

#if !defined(NDEBUG)

// Install the listener before this class starts its first metadata parse.
+ (void)initialize {
    if (self != AudioTrackMetadata.class) {
        return; // +initialize runs for subclasses too
    }
    VibeInstallTagLibDebugListener();
}

#endif

- (VibeImage *)cachedArt {
    return [self.artwork cachedArt];
}

- (BOOL)artNeedsLoad {
    return [self.artwork artNeedsLoad];
}

- (BOOL)isArtLoadPending {
    return self.artwork.isArtLoadPending;
}

- (void)loadArtIfNeededStillWanted:(BOOL (^)(void))stillWanted
                        completion:(void (^)(VibeImage *_Nullable))completion {
    [self.artwork loadArtIfNeededWithLabel:self.title
                               stillWanted:stillWanted completion:completion];
}

- (void)discardDecodedArt {
    [self.artwork discardDecodedArt];
}

- (BOOL)hasEmbeddedArt {
    return self.artwork.hasEmbeddedArt;
}

- (VibeImage *)cachedThumbnail {
    VibeImage *thumbnail = [self.artwork cachedThumbnail];
    if (thumbnail) {
        return thumbnail;
    }
    if (![self.artwork embeddedThumbnailDecodeHasSource]) {
        // Nothing to decode; a data transition's redraw re-asks.
        return nil;
    }

    __weak AudioTrackMetadata *weakMetadata = self;
    dispatch_block_t request = ^{
        AudioTrackMetadata *metadata = weakMetadata;
        if (!metadata) {
            return;
        }
        [metadata.artwork requestEmbeddedThumbnailDecodeWithCompletion:^(VibeImage *image) {
            AudioTrackMetadata *completedMetadata = weakMetadata;
            if (image && completedMetadata) {
                [NSNotificationCenter.defaultCenter
                        postNotificationName:AudioTrackMetadataThumbnailDidLoadNotification
                                      object:completedMetadata];
            }
        }];
    };
    if (NSThread.isMainThread) {
        request();
    }
    else {
        dispatch_async(dispatch_get_main_queue(), request);
    }
    return nil;
}

- (instancetype)initForCopy {
    self = [super init];
    if (self) {
        self.key = VibeMusicalKeyNone;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    AudioTrackMetadata *copy = [[[self class] allocWithZone:zone] initForCopy];
    copy.title = self.title;
    copy.artist = self.artist;
    copy.fileType = self.fileType;
    copy.bitrate = self.bitrate;
    copy.sampleRate = self.sampleRate;
    copy.duration = self.duration;
    copy.bpm = self.bpm;
    copy.key = self.key;
    copy.album = self.album;
    copy.albumArtist = self.albumArtist;
    copy.genre = self.genre;
    copy.composer = self.composer;
    copy.year = self.year;
    copy.trackNumber = self.trackNumber;
    copy.trackCount = self.trackCount;
    copy.discNumber = self.discNumber;
    copy.discCount = self.discCount;
    copy.compilation = self.compilation;
    copy.musicBrainzReleaseID = self.musicBrainzReleaseID;
    copy.musicBrainzRecordingID = self.musicBrainzRecordingID;
    copy.isrc = self.isrc;
    copy.audioMD5 = self.audioMD5;
    copy.replayGainTrackGain = self.replayGainTrackGain;
    copy.replayGainTrackPeak = self.replayGainTrackPeak;
    copy.replayGainAlbumGain = self.replayGainAlbumGain;
    copy.replayGainAlbumPeak = self.replayGainAlbumPeak;
    copy.r128TrackGain = self.r128TrackGain;
    copy.r128AlbumGain = self.r128AlbumGain;
    copy.soundCheckGain = self.soundCheckGain;
    copy.parsedOK = self.parsedOK;
    copy.cacheKey = self.cacheKey;
    copy.artwork = [self.artwork copy];
    return copy;
}

static void EncodePresent(NSCoder *coder, id _Nullable value, NSString *key) {
    if (value) [coder encodeObject:value forKey:key];
}

static void EncodePresentCount(NSCoder *coder, NSInteger value, NSString *key) {
    if (value) [coder encodeInteger:value forKey:key];
}

// The tags and scalars only. The art lives in stores of its own, with their
// own budgets, so art never pushes tags out (AudioTrackMetadataCache). Only
// whether the file carries art is archived here.
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.title forKey:@"title"];
    [coder encodeObject:self.artist forKey:@"artist"];
    [coder encodeBool:self.artwork.hasEmbeddedArt forKey:@"hasEmbeddedArt"];
    [coder encodeObject:self.artwork.sourceFilePath forKey:@"sourceFilePath"];
    [coder encodeObject:self.fileType forKey:@"fileType"];
    [coder encodeObject:self.bitrate forKey:@"bitrate"];
    [coder encodeObject:self.sampleRate forKey:@"sampleRate"];
    [coder encodeDouble:self.duration forKey:@"duration"];
    [coder encodeFloat:self.bpm forKey:@"bpm"];
    // As an object, not encodeInteger: an absent integer decodes as 0, which
    // as a key means C major, whereas an absent object is unambiguously nil.
    [coder encodeObject:@(self.key) forKey:@"key"];
    // The tag fields only when present, so most entries stay small.
    EncodePresent(coder, self.album, @"album");
    EncodePresent(coder, self.albumArtist, @"albumArtist");
    EncodePresent(coder, self.genre, @"genre");
    EncodePresent(coder, self.composer, @"composer");
    EncodePresentCount(coder, self.year, @"year");
    EncodePresentCount(coder, self.trackNumber, @"trackNumber");
    EncodePresentCount(coder, self.trackCount, @"trackCount");
    EncodePresentCount(coder, self.discNumber, @"discNumber");
    EncodePresentCount(coder, self.discCount, @"discCount");
    EncodePresentCount(coder, self.compilation, @"compilation");
    EncodePresent(coder, self.musicBrainzReleaseID, @"musicBrainzReleaseID");
    EncodePresent(coder, self.musicBrainzRecordingID, @"musicBrainzRecordingID");
    EncodePresent(coder, self.isrc, @"isrc");
    EncodePresent(coder, self.audioMD5, @"audioMD5");
    EncodePresent(coder, self.replayGainTrackGain, @"replayGainTrackGain");
    EncodePresent(coder, self.replayGainTrackPeak, @"replayGainTrackPeak");
    EncodePresent(coder, self.replayGainAlbumGain, @"replayGainAlbumGain");
    EncodePresent(coder, self.replayGainAlbumPeak, @"replayGainAlbumPeak");
    EncodePresent(coder, self.r128TrackGain, @"r128TrackGain");
    EncodePresent(coder, self.r128AlbumGain, @"r128AlbumGain");
    EncodePresent(coder, self.soundCheckGain, @"soundCheckGain");
}

// The object archived under key, or nil. An object of another class sets
// *wrong, which makes the entry a miss.
static id _Nullable DecodedObject(NSCoder *coder, NSString *key, Class kind, BOOL *wrong) {
    id value = [coder decodeObjectForKey:key];
    if (value && ![value isKindOfClass:kind]) {
        *wrong = YES;
        return nil;
    }
    return value;
}

// The parse archives no count below 1, so anything else reads as untagged.
static NSInteger DecodedCount(NSCoder *coder, NSString *key) {
    NSInteger value = [coder decodeIntegerForKey:key];
    return value > 0 ? value : 0;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // PINDiskCache unarchives without secure coding: any wrong class is a
        // miss, or a persistent bad entry crashes every launch.
        BOOL wrong = NO;
        NSString *sourceFilePath = DecodedObject(coder, @"sourceFilePath", NSString.class, &wrong);
        self.title = DecodedObject(coder, @"title", NSString.class, &wrong);
        self.artist = DecodedObject(coder, @"artist", NSString.class, &wrong);
        self.fileType = DecodedObject(coder, @"fileType", NSString.class, &wrong);
        self.bitrate = DecodedObject(coder, @"bitrate", NSNumber.class, &wrong);
        self.sampleRate = DecodedObject(coder, @"sampleRate", NSNumber.class, &wrong);
        self.album = DecodedObject(coder, @"album", NSString.class, &wrong);
        self.albumArtist = DecodedObject(coder, @"albumArtist", NSString.class, &wrong);
        self.genre = DecodedObject(coder, @"genre", NSString.class, &wrong);
        self.composer = DecodedObject(coder, @"composer", NSString.class, &wrong);
        self.musicBrainzReleaseID = DecodedObject(coder, @"musicBrainzReleaseID", NSString.class, &wrong);
        self.musicBrainzRecordingID = DecodedObject(coder, @"musicBrainzRecordingID", NSString.class, &wrong);
        self.isrc = DecodedObject(coder, @"isrc", NSString.class, &wrong);
        self.audioMD5 = DecodedObject(coder, @"audioMD5", NSData.class, &wrong);
        self.replayGainTrackGain = DecodedObject(coder, @"replayGainTrackGain", NSNumber.class, &wrong);
        self.replayGainTrackPeak = DecodedObject(coder, @"replayGainTrackPeak", NSNumber.class, &wrong);
        self.replayGainAlbumGain = DecodedObject(coder, @"replayGainAlbumGain", NSNumber.class, &wrong);
        self.replayGainAlbumPeak = DecodedObject(coder, @"replayGainAlbumPeak", NSNumber.class, &wrong);
        self.r128TrackGain = DecodedObject(coder, @"r128TrackGain", NSNumber.class, &wrong);
        self.r128AlbumGain = DecodedObject(coder, @"r128AlbumGain", NSNumber.class, &wrong);
        self.soundCheckGain = DecodedObject(coder, @"soundCheckGain", NSNumber.class, &wrong);
        if (wrong) {
            return nil;
        }
        self.year = DecodedCount(coder, @"year");
        self.trackNumber = DecodedCount(coder, @"trackNumber");
        self.trackCount = DecodedCount(coder, @"trackCount");
        self.discNumber = DecodedCount(coder, @"discNumber");
        self.discCount = DecodedCount(coder, @"discCount");
        self.compilation = DecodedCount(coder, @"compilation") > 0;
        self.artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:sourceFilePath
                                                               extractor:VibeTagLibArtExtractor()];
        // The thumbnail's bytes are in their own store. The loader stamps
        // the providers that read it and the rendition.
        [self.artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:[coder decodeBoolForKey:@"hasEmbeddedArt"]];
        double duration = [coder decodeDoubleForKey:@"duration"];
        if (!isfinite(duration) || duration < 0) {
            return nil;
        }
        self.duration = duration;
        // The parse path's bounds; absent decodes as 0, untagged.
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = isfinite(bpm) && bpm > 0 && bpm < 1000 ? bpm : 0;
        id keyValue = [coder decodeObjectForKey:@"key"];
        if (keyValue && ![keyValue isKindOfClass:[NSNumber class]]) return nil;
        NSInteger key = keyValue ? [keyValue integerValue] : -1;
        self.key = (key >= 0 && key < 24) ? key : -1;
        // Only successful parses are cached.
        self.parsedOK = YES;
    }
    return self;
}
- (NSData *)encodeThumbnailDataIfNeeded {
    NSData *stored = [self.artwork encodedThumbnailDataForStorage];
    if (stored) {
        return stored;
    }
    // The file's own art only; folder art is never archived.
    VibeImage *thumbnail = [self.artwork decodeThumbnailForArchiving];
    if (!thumbnail) {
        return nil;
    }
    NSData *encoded = VibeEncodedImageData(thumbnail);
    if (!encoded) {
        return nil;
    }
    [self.artwork storeEncodedThumbnailData:encoded];
    return encoded;
}

// Bytes within kVibeArchivedDisplayArtDimension verbatim, larger ones
// downscaled with aspect kept (the square crop is display-time policy). Must
// run while the original bytes exist.
- (nullable NSData *)archivedDisplayArtDataForStorage {
    NSData *original = [self.artwork artDataForArchivedDisplayArt];
    if (!original) {
        return nil;
    }
    CGSize pixels = VibeEncodedImagePixelSize(original);
    CGFloat maxDimension = MAX(pixels.width, pixels.height);
    if (maxDimension <= 0) {
        return nil;
    }
    if (maxDimension <= kVibeArchivedDisplayArtDimension) {
        return original;
    }
    VibeImage *scaled = VibeDecodedImageWithData(original, kVibeArchivedDisplayArtDimension);
    return scaled ? VibeEncodedImageData(scaled) : nil;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        self.key = VibeMusicalKeyNone; // the zero-filled default is C major
        [self loadFromURL:url];
    }
    return self;
}

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url
                          displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)displayArtData {
    AudioTrackMetadata *metadata = [[AudioTrackMetadata alloc] initWithURL:url];
    // Encoding must not populate the display cache during a playlist scan.
    NSData *encodedThumbnail = [metadata encodeThumbnailDataIfNeeded];
    if (!encodedThumbnail && metadata.artwork.hasEmbeddedArt) {
        // The fresh row keeps its originals. Cache hits use the rendition.
        LogWarn(@"Thumbnail encode produced nothing for art-bearing %@",
                url.path.lastPathComponent);
    }
    // Before the discard. An out-param, never row state: a skipped cache
    // write must not leave the rendition pinned on the row.
    if (displayArtData) {
        *displayArtData = [metadata archivedDisplayArtDataForStorage];
    }
    [metadata.artwork discardArtData];
    return metadata;
}

- (void)loadFromURL:(NSURL*)url {

    self.artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:url.path
                                                           extractor:VibeTagLibArtExtractor()];
    self.title = url.filenameTitle;

    // A corrupt tag can make TagLib throw, and uncaught on a worker that is
    // std::terminate. A malformed file degrades to a failed parse instead.
    try {
        uint64_t length = 0;
        VibeTagByteRangeRead read = VibeTagRangeReadForPath(url.path, &length);
        TagLibAudioFile fileRef(url.path.UTF8String, true, read, length);
        if (fileRef.isNull()) {
            [self loadCoreAudioFactsFromURL:url];
            return;
        }

        TagLib::File *file = fileRef.file();

        // A valid file without tags still supplies audio properties.
        if (TagLib::Tag *tag = fileRef.tag()) {
            NSString *tagArtist = [[NSString stringWithStdString:tag->artist().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *tagTitle = [[NSString stringWithStdString:tag->title().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (tagArtist.length > 0) self.artist = tagArtist;
            if (tagTitle.length > 0) self.title = tagTitle;
        }

        if (auto props = file->audioProperties()) {
            self.duration = static_cast<NSTimeInterval>(props->lengthInMilliseconds()) / 1000;
            // 0 is unknown; the codec line drops nil, not zero.
            if (props->bitrate() > 0) self.bitrate = @(props->bitrate());
            if (props->sampleRate() > 0) self.sampleRate = @(props->sampleRate());
        }
        // TagLib takes a FLAC's length from STREAMINFO alone, which may leave it
        // unknown (0); the handle's dr_flac finds it from the stream's last frames.
        if (self.duration == 0 && dynamic_cast<TagLib::FLAC::File *>(file)) {
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url interleaved:NO
                                                                   interrupted:VibeNeverWaitsForAStream error:NULL];
            if (handle.length > 0) {
                self.duration = handle.length / handle.processingFormat.sampleRate;
            }
        }

        // Built once: properties() converts every frame of every tag. It
        // normalizes each format's tempo tag to "BPM", and its keys are
        // case-insensitive.
        const TagLib::PropertyMap properties = file->properties();
        TagLib::StringList bpmValues = properties.value("BPM");
        if (!bpmValues.isEmpty()) {
            float tagBPM = [NSString stringWithStdString:bpmValues.front().to8Bit(true)].floatValue;
            if (isfinite(tagBPM) && tagBPM > 0 && tagBPM < 1000) {
                self.bpm = tagBPM;
            }
        }

        // ID3 TKEY and Vorbis/FLAC INITIALKEY arrive as "INITIALKEY"; MP4 has
        // no mapping, so its iTunes freeform atom arrives as "initialkey",
        // which the same lookup finds. An unparseable value stays None, so
        // analysis fills in.
        TagLib::StringList keyValues = properties.value("INITIALKEY");
        if (!keyValues.isEmpty()) {
            self.key = VibeMusicalKeyFromString(
                    [NSString stringWithStdString:keyValues.front().to8Bit(true)]);
        }
        [self readFieldsFromProperties:properties];
        self.audioMD5 = audioMD5FromTagLibFile(file);

        self.fileType = fileTypeForTagLibFile(file);
        [self.artwork adoptParsedArtData:albumArtDataFromTagLibFile(file)];
        self.parsedOK = YES;
    }
    catch (const std::exception &e) {
        LogError(@"TagLib parse failed for %@: %s", url.path, e.what());
    }
    catch (...) {
        LogError(@"TagLib parse failed for %@", url.path);
    }
}

// The fields from the same map, where each format's frame or atom arrives
// under one key (this piece's AGENTS.md, The tag fields). Sound Check is an
// ID3v2 comment's, or an MP4 freeform atom's.
- (void)readFieldsFromProperties:(const TagLib::PropertyMap &)properties {
    self.album = PropertyText(properties, "ALBUM");
    self.albumArtist = PropertyText(properties, "ALBUMARTIST");
    self.genre = PropertyText(properties, "GENRE");
    self.composer = PropertyText(properties, "COMPOSER");
    NSInteger year = LeadingCount(PropertyText(properties, "DATE"));
    self.year = year <= 9999 ? year : 0;
    NSInteger number = 0, count = 0;
    ReadNumberAndCount(properties, "TRACKNUMBER", {"TRACKTOTAL", "TOTALTRACKS"}, &number, &count);
    self.trackNumber = number;
    self.trackCount = count;
    ReadNumberAndCount(properties, "DISCNUMBER", {"DISCTOTAL", "TOTALDISCS"}, &number, &count);
    self.discNumber = number;
    self.discCount = count;
    self.compilation = LeadingCount(PropertyText(properties, "COMPILATION")) > 0;
    self.musicBrainzReleaseID = PropertyText(properties, "MUSICBRAINZ_ALBUMID");
    self.musicBrainzRecordingID = PropertyText(properties, "MUSICBRAINZ_TRACKID");
    self.isrc = PropertyText(properties, "ISRC");
    self.replayGainTrackGain = LeadingDecimal(PropertyText(properties, "REPLAYGAIN_TRACK_GAIN"));
    self.replayGainTrackPeak = LeadingDecimal(PropertyText(properties, "REPLAYGAIN_TRACK_PEAK"));
    self.replayGainAlbumGain = LeadingDecimal(PropertyText(properties, "REPLAYGAIN_ALBUM_GAIN"));
    self.replayGainAlbumPeak = LeadingDecimal(PropertyText(properties, "REPLAYGAIN_ALBUM_PEAK"));
    self.r128TrackGain = R128Gain(PropertyText(properties, "R128_TRACK_GAIN"));
    self.r128AlbumGain = R128Gain(PropertyText(properties, "R128_ALBUM_GAIN"));
    self.soundCheckGain = SoundCheckGain(PropertyText(properties, "COMMENT:ITUNNORM")
                                         ?: PropertyText(properties, "ITUNNORM"));
}

// CoreAudio's facts for a file TagLib cannot read (this piece's AGENTS.md).
- (void)loadCoreAudioFactsFromURL:(NSURL *)url {
    // The parser open playback makes for a file its own decoders refuse.
    // TRAP: the handle closes the parser when released, which ARC may do
    // right after its last message unless its lifetime is pinned to the scope.
    NS_VALID_UNTIL_END_OF_SCOPE AudioFileHandle *handle = [[AudioFileHandle alloc] initParserForReading:url
                                                                                            interrupted:VibeNeverWaitsForAStream error:NULL];
    AudioFileID file = handle.parser;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    if (!file || AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) != noErr || format.mSampleRate <= 0) {
        return;
    }
    AudioFileTypeID container = 0;
    size = sizeof(container);
    AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &container);
    Float64 duration = 0;
    size = sizeof(duration);
    if (AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr
            && isfinite(duration) && duration > 0) {
        self.duration = duration;
    }
    UInt32 bitsPerSecond = 0;
    size = sizeof(bitsPerSecond);
    if (AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitsPerSecond) == noErr && bitsPerSecond >= 1000) {
        self.bitrate = @(bitsPerSecond / 1000); // TagLib's unit
    }
    self.sampleRate = @((int)format.mSampleRate);
    CFDictionaryRef infoDictionary = NULL;
    size = sizeof(infoDictionary);
    if (handle.infoDictionaryReadable
            && AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &infoDictionary) == noErr
            && infoDictionary) {
        NSDictionary *tags = CFBridgingRelease(infoDictionary);
        NSString *artist = trimmedTagText(tags[@kAFInfoDictionary_Artist]);
        NSString *title = trimmedTagText(tags[@kAFInfoDictionary_Title]);
        if (artist) self.artist = artist;
        if (title) self.title = title;
    }
    // PCM is never named WAV or AIFF here. A caller that copies tags by
    // format would then open a container its tag copy cannot read.
    if (format.mFormatID != kAudioFormatLinearPCM) self.fileType = VibeAudioFileFormatForCodec(format.mFormatID);
    else if (container == kAudioFileWave64Type) self.fileType = VibeAudioFileFormatW64;
    else if (container == kAudioFileCAFType) self.fileType = VibeAudioFileFormatCAF;
    [self.artwork adoptParsedArtData:nil];
    self.parsedOK = YES;
}

- (BOOL)isLossless {
    if ([VibeAudioFileFormatFLAC isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatALAC isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatAIFF isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatWAV isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatW64 isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatCAF isEqualToString:self.fileType]) return YES;
    return NO;
}

@end
