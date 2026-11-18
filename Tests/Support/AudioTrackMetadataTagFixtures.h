//
//  AudioTrackMetadataTagFixtures.h
//  The metadata and tag writer tests
//
//  Tagged files for the tag and fuzz tests. The audio comes from
//  AudioFileFixtures.h or a stock Apple encoder. The tags come from TagLib's own
//  writers, except APE, which the vendored TagLib cannot write to MPEG. Ogg
//  has no Apple encoder. So Vorbis and Opus start from the render suite's
//  generated fixtures, and are nil without them. Each fixture carries every
//  tag field its format does (VibeTagFixtureField). C++, so only .mm files import it.
//

#import "AudioFileFixtures.h"
#import "FLACFixtures.h"
#import "ImageFixtures.h"

#include <attachedpictureframe.h>
#include <aifffile.h>
#include <commentsframe.h>
#include <flacfile.h>
#include <flacpicture.h>
#include <id3v1tag.h>
#include <id3v2tag.h>
#include <infotag.h>
#include <mp4file.h>
#include <mpegfile.h>
#include <opusfile.h>
#include <tpropertymap.h>
#include <vorbisfile.h>
#include <wavfile.h>

static NSString *const kVibeTagTitle = @"Tagged Title";
static NSString *const kVibeTagArtist = @"Tagged Artist";
static const float kVibeTagBPM = 128.5f;
// Am, which VibeMusicalKeyFromString reads as pitch class 9, minor.
static NSString *const kVibeTagKey = @"Am";

typedef NS_ENUM(NSInteger, VibeTagFixture) {
    VibeTagFixtureMP3ID3v23,
    VibeTagFixtureMP3ID3v24,
    VibeTagFixtureMP3ID3v1,
    VibeTagFixtureMP3APE,
    VibeTagFixtureM4A,
    VibeTagFixtureFLAC,
    VibeTagFixtureFLACCueSheet,
    VibeTagFixtureVorbis,
    VibeTagFixtureOpus,
    VibeTagFixtureWAVID3,
    VibeTagFixtureWAVInfo,
    VibeTagFixtureAIFF,
    VibeTagFixtureCAF,
    VibeTagFixtureW64,
    VibeTagFixtureCount,
};

static inline NSString *VibeTagFixtureName(VibeTagFixture fixture) {
    static NSString *const names[VibeTagFixtureCount] = {
            @"id3v23.mp3", @"id3v24.mp3", @"id3v1.mp3", @"ape.mp3", @"tagged.m4a", @"tagged.flac",
            @"cuesheet.flac", @"tagged.ogg", @"tagged.opus", @"id3.wav", @"info.wav", @"tagged.aif",
            @"tagged.caf", @"plain.w64"};
    return names[fixture];
}

// The formats whose tag carries a tempo and a key, and the ones carrying art.
static inline BOOL VibeTagFixtureHasBPMAndKey(VibeTagFixture fixture) {
    return fixture != VibeTagFixtureMP3ID3v1 && fixture != VibeTagFixtureWAVInfo
            && fixture != VibeTagFixtureCAF && fixture != VibeTagFixtureW64;
}

static inline BOOL VibeTagFixtureHasArt(VibeTagFixture fixture) {
    return VibeTagFixtureHasBPMAndKey(fixture) && fixture != VibeTagFixtureMP3APE;
}

static inline BOOL VibeTagFixtureIsXiph(VibeTagFixture fixture) {
    return fixture == VibeTagFixtureFLAC || fixture == VibeTagFixtureFLACCueSheet
            || fixture == VibeTagFixtureVorbis || fixture == VibeTagFixtureOpus;
}

static inline BOOL VibeTagFixtureIsID3v2(VibeTagFixture fixture) {
    return fixture == VibeTagFixtureMP3ID3v23 || fixture == VibeTagFixtureMP3ID3v24
            || fixture == VibeTagFixtureWAVID3 || fixture == VibeTagFixtureAIFF;
}

#pragma mark - The tag fields

// The fields AudioTrackMetadata reads past the title, artist, tempo, and key.
// A number and its count are one field, since one tag can carry both.
typedef NS_ENUM(NSInteger, VibeTagFixtureField) {
    VibeTagFixtureFieldAlbum,
    VibeTagFixtureFieldAlbumArtist,
    VibeTagFixtureFieldGenre,
    VibeTagFixtureFieldComposer,
    VibeTagFixtureFieldYear,
    VibeTagFixtureFieldTrack,
    VibeTagFixtureFieldDisc,
    VibeTagFixtureFieldCompilation,
    VibeTagFixtureFieldReleaseID,
    VibeTagFixtureFieldRecordingID,
    VibeTagFixtureFieldISRC,
    VibeTagFixtureFieldReplayGainTrackGain,
    VibeTagFixtureFieldReplayGainTrackPeak,
    VibeTagFixtureFieldReplayGainAlbumGain,
    VibeTagFixtureFieldReplayGainAlbumPeak,
    VibeTagFixtureFieldR128TrackGain,
    VibeTagFixtureFieldR128AlbumGain,
    VibeTagFixtureFieldSoundCheck,
    VibeTagFixtureFieldComment,
    VibeTagFixtureFieldGrouping,
    VibeTagFixtureFieldLabel,
    VibeTagFixtureFieldCatalogNumber,
    VibeTagFixtureFieldConductor,
    VibeTagFixtureFieldRemixer,
    VibeTagFixtureFieldLyricist,
    VibeTagFixtureFieldMood,
    VibeTagFixtureFieldLanguage,
    VibeTagFixtureFieldCopyright,
    VibeTagFixtureFieldOriginalDate,
    VibeTagFixtureFieldTitleSort,
    VibeTagFixtureFieldArtistSort,
    VibeTagFixtureFieldAlbumSort,
    VibeTagFixtureFieldAlbumArtistSort,
    VibeTagFixtureFieldCount,
};

static NSString *const kVibeTagAlbum = @"Tagged Album";
static NSString *const kVibeTagAlbumArtist = @"Tagged Album Artist";
// A name ID3v1's genre list holds, since ID3v1 stores an index.
static NSString *const kVibeTagGenre = @"Jazz";
static NSString *const kVibeTagComposer = @"Tagged Composer";
static const NSInteger kVibeTagYear = 1999;
static NSString *const kVibeTagReleaseID = @"f5093c06-23e3-404f-aeaa-40f72885ee3a";
static NSString *const kVibeTagRecordingID = @"8f8cc91f-0bca-4351-90d4-ef334ac0a0cf";
static NSString *const kVibeTagISRC = @"USRC17607839";
// iTunNORM's channels against 1/1000 W are 1000 and 2000. The louder one
// gives -10 log10(2) dB.
static NSString *const kVibeTagSoundCheck =
        @" 000003E8 000007D0 00002710 00004E20 00024CA8 00024CA8 00007FFF 00007FFF 00024CA8 00024CA8";
static const double kVibeTagSoundCheckGain = -3.0102999566398120;
// ID3v1 holds 28 bytes of comment.
static NSString *const kVibeTagComment = @"Tagged Comment";
static NSString *const kVibeTagGrouping = @"Tagged Grouping";
static NSString *const kVibeTagLabel = @"Tagged Label";
static NSString *const kVibeTagOriginalDate = @"1972-05-01";
static const NSInteger kVibeTagOriginalYear = 1972;

static inline BOOL VibeTagFixtureFieldIsExtra(VibeTagFixtureField field) {
    return field >= VibeTagFixtureFieldCatalogNumber && field <= VibeTagFixtureFieldAlbumArtistSort;
}

// An extra tag's property name, as the parse files it and TagLib's writer
// takes it.
static inline const char *VibeTagExtraName(VibeTagFixtureField field) {
    static const char *const names[] = {
            "CATALOGNUMBER", "CONDUCTOR", "REMIXER", "LYRICIST", "MOOD", "LANGUAGE", "COPYRIGHT",
            "ORIGINALDATE", "TITLESORT", "ARTISTSORT", "ALBUMSORT", "ALBUMARTISTSORT"};
    return names[field - VibeTagFixtureFieldCatalogNumber];
}

// An extra tag's value as written, and as read back from `fixture`.
// ID3v2.3 holds the original date as TORY, its year alone.
static inline NSString *VibeTagExtraValue(VibeTagFixtureField field, VibeTagFixture fixture) {
    static NSString *const values[] = {
            @"CAT-0042", @"Tagged Conductor", @"Tagged Remixer", @"Tagged Lyricist", @"Mellow", @"eng",
            @"2024 Tagged Copyright", kVibeTagOriginalDate, @"Title, Tagged", @"Artist, Tagged",
            @"Album, Tagged", @"Album Artist, Tagged"};
    if (field == VibeTagFixtureFieldOriginalDate && fixture == VibeTagFixtureMP3ID3v23) {
        return @"1972";
    }
    return values[field - VibeTagFixtureFieldCatalogNumber];
}

static inline NSString *VibeTagFixtureFieldName(VibeTagFixtureField field) {
    static NSString *const names[VibeTagFixtureFieldCount] = {
            @"album", @"album artist", @"genre", @"composer", @"year", @"track", @"disc", @"compilation",
            @"release ID", @"recording ID", @"ISRC", @"ReplayGain track gain", @"ReplayGain track peak",
            @"ReplayGain album gain", @"ReplayGain album peak", @"R128 track gain", @"R128 album gain",
            @"Sound Check", @"comment", @"grouping", @"label", @"catalog number", @"conductor", @"remixer",
            @"lyricist", @"mood", @"language", @"copyright", @"original date", @"title sort", @"artist sort",
            @"album sort", @"album artist sort"};
    return names[field];
}

// What each format's tag carries. ID3v1 has an album, a year, a genre, a
// track number, and a comment. RIFF INFO adds a composer, an ISRC, a label,
// a copyright, a language, a lyricist, and a remixer. ID3v2.3 has no TMOO,
// so TagLib's writer drops the mood. R128 gains are read from any Xiph
// comment, though Opus is the format that defines them.
static inline BOOL VibeTagFixtureCarries(VibeTagFixture fixture, VibeTagFixtureField field) {
    switch (fixture) {
        case VibeTagFixtureMP3ID3v1:
            return field == VibeTagFixtureFieldAlbum || field == VibeTagFixtureFieldYear || field == VibeTagFixtureFieldGenre
                    || field == VibeTagFixtureFieldTrack || field == VibeTagFixtureFieldComment;
        case VibeTagFixtureWAVInfo:
            return field == VibeTagFixtureFieldAlbum || field == VibeTagFixtureFieldYear || field == VibeTagFixtureFieldGenre
                    || field == VibeTagFixtureFieldTrack || field == VibeTagFixtureFieldComposer || field == VibeTagFixtureFieldISRC
                    || field == VibeTagFixtureFieldComment || field == VibeTagFixtureFieldLabel
                    || field == VibeTagFixtureFieldCopyright || field == VibeTagFixtureFieldLanguage
                    || field == VibeTagFixtureFieldLyricist || field == VibeTagFixtureFieldRemixer;
        case VibeTagFixtureMP3ID3v23:
            return field != VibeTagFixtureFieldMood && field != VibeTagFixtureFieldR128TrackGain
                    && field != VibeTagFixtureFieldR128AlbumGain;
        case VibeTagFixtureCAF: case VibeTagFixtureW64: case VibeTagFixtureCount:
            return NO;
        default:
            break;
    }
    BOOL r128 = field == VibeTagFixtureFieldR128TrackGain || field == VibeTagFixtureFieldR128AlbumGain;
    if (VibeTagFixtureIsXiph(fixture)) {
        return field != VibeTagFixtureFieldSoundCheck;
    }
    if (fixture == VibeTagFixtureMP3APE) {
        return !r128 && field != VibeTagFixtureFieldSoundCheck;
    }
    return !r128; // ID3v2 and MP4
}

// Whether a format's tag holds a count beside its number: ID3v1 and RIFF
// INFO hold only the number.
static inline BOOL VibeTagFixtureHasCounts(VibeTagFixture fixture) {
    return fixture != VibeTagFixtureMP3ID3v1 && fixture != VibeTagFixtureWAVInfo;
}

static inline TagLib::String VibeTagString(NSString *string) {
    return TagLib::String(string.UTF8String, TagLib::String::UTF8);
}

static inline TagLib::ByteVector VibeTagBytes(NSData *data) {
    return TagLib::ByteVector((const char *)data.bytes, (unsigned int)data.length);
}

// One field's tags as each format's writer spells them. Xiph comments keep a
// count in a tag of its own. Sound Check is no property: the writer adds it.
static inline void VibeAddTagField(TagLib::PropertyMap &properties, VibeTagFixture fixture, VibeTagFixtureField field) {
    auto set = [&properties](const char *key, NSString *value) {
        properties[key] = TagLib::StringList(VibeTagString(value));
    };
    if (VibeTagFixtureFieldIsExtra(field)) {
        set(VibeTagExtraName(field), VibeTagExtraValue(field, VibeTagFixtureFLAC));
        return;
    }
    BOOL xiph = VibeTagFixtureIsXiph(fixture);
    BOOL counts = VibeTagFixtureHasCounts(fixture);
    switch (field) {
        case VibeTagFixtureFieldAlbum: set("ALBUM", kVibeTagAlbum); break;
        case VibeTagFixtureFieldAlbumArtist: set("ALBUMARTIST", kVibeTagAlbumArtist); break;
        case VibeTagFixtureFieldGenre: set("GENRE", kVibeTagGenre); break;
        case VibeTagFixtureFieldComposer: set("COMPOSER", kVibeTagComposer); break;
        // ID3v1 stores four digits.
        case VibeTagFixtureFieldYear: set("DATE", fixture == VibeTagFixtureMP3ID3v1 ? @"1999" : @"1999-04-01"); break;
        case VibeTagFixtureFieldTrack:
            set("TRACKNUMBER", xiph || !counts ? @"3" : @"3/12");
            if (xiph) set("TRACKTOTAL", @"12");
            break;
        case VibeTagFixtureFieldDisc:
            set("DISCNUMBER", xiph ? @"1" : @"1/2");
            if (xiph) set("DISCTOTAL", @"2");
            break;
        case VibeTagFixtureFieldCompilation: set("COMPILATION", @"1"); break;
        case VibeTagFixtureFieldReleaseID: set("MUSICBRAINZ_ALBUMID", kVibeTagReleaseID); break;
        case VibeTagFixtureFieldRecordingID: set("MUSICBRAINZ_TRACKID", kVibeTagRecordingID); break;
        case VibeTagFixtureFieldISRC: set("ISRC", kVibeTagISRC); break;
        case VibeTagFixtureFieldReplayGainTrackGain: set("REPLAYGAIN_TRACK_GAIN", @"-6.54 dB"); break;
        case VibeTagFixtureFieldReplayGainTrackPeak: set("REPLAYGAIN_TRACK_PEAK", @"0.988547"); break;
        case VibeTagFixtureFieldReplayGainAlbumGain: set("REPLAYGAIN_ALBUM_GAIN", @"+1.25 dB"); break;
        case VibeTagFixtureFieldReplayGainAlbumPeak: set("REPLAYGAIN_ALBUM_PEAK", @"1.000000"); break;
        // Q7.8: -1234/256 and -512/256 dB.
        case VibeTagFixtureFieldR128TrackGain: set("R128_TRACK_GAIN", @"-1234"); break;
        case VibeTagFixtureFieldR128AlbumGain: set("R128_ALBUM_GAIN", @"-512"); break;
        case VibeTagFixtureFieldComment: set("COMMENT", kVibeTagComment); break;
        case VibeTagFixtureFieldGrouping: set("GROUPING", kVibeTagGrouping); break;
        case VibeTagFixtureFieldLabel: set("LABEL", kVibeTagLabel); break;
        case VibeTagFixtureFieldSoundCheck: case VibeTagFixtureFieldCount: break;
        case VibeTagFixtureFieldCatalogNumber: case VibeTagFixtureFieldConductor: case VibeTagFixtureFieldRemixer:
        case VibeTagFixtureFieldLyricist: case VibeTagFixtureFieldMood: case VibeTagFixtureFieldLanguage: case VibeTagFixtureFieldCopyright:
        case VibeTagFixtureFieldOriginalDate: case VibeTagFixtureFieldTitleSort: case VibeTagFixtureFieldArtistSort:
        case VibeTagFixtureFieldAlbumSort: case VibeTagFixtureFieldAlbumArtistSort: break; // above
    }
}

// The fixture's whole tag: the title, the artist, the tempo and key where the
// format carries them, and every field it carries.
static inline TagLib::PropertyMap VibeTagProperties(VibeTagFixture fixture) {
    TagLib::PropertyMap properties;
    properties["TITLE"] = TagLib::StringList(VibeTagString(kVibeTagTitle));
    properties["ARTIST"] = TagLib::StringList(VibeTagString(kVibeTagArtist));
    if (VibeTagFixtureHasBPMAndKey(fixture)) {
        properties["BPM"] = TagLib::StringList(VibeTagString([NSString stringWithFormat:@"%g", kVibeTagBPM]));
        properties["INITIALKEY"] = TagLib::StringList(VibeTagString(kVibeTagKey));
    }
    for (NSInteger field = 0; field < VibeTagFixtureFieldCount; field++) {
        if (VibeTagFixtureCarries(fixture, (VibeTagFixtureField)field)) {
            VibeAddTagField(properties, fixture, (VibeTagFixtureField)field);
        }
    }
    return properties;
}

// A fresh directory under the temporary directory. The test that made it
// removes it.
static inline NSURL *VibeTagFixtureDirectory(void) {
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                            isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return dir;
}

// A JPEG's start-of-image and APP0 marker, then bytes no decoder reads.
static inline NSData *VibeTagUndecodableArt(void) {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFF\xD8\xFF\xE0\x00\x10JFIF\x00" length:11];
    for (uint32_t i = 0; i < 2048; i++) {
        uint8_t byte = (uint8_t)(i * 2654435761u >> 24);
        [data appendBytes:&byte length:1];
    }
    return data;
}

// A 16px JPEG whose frame header declares `side` x `side`. ImageIO refuses
// the header past about 10000px. Below that it decodes, filling what the
// bytes lack, so only the bounded decode keeps the bitmap small.
static inline NSData *VibeTagOversizeArt(uint16_t side) {
    NSMutableData *data = [VibeImageOfColor(16, 0.8, 0.2, 0.3, YES) mutableCopy];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    for (NSUInteger i = 0; i + 9 < data.length; i++) {
        if (bytes[i] == 0xFF && (bytes[i + 1] == 0xC0 || bytes[i + 1] == 0xC2)) {
            bytes[i + 5] = bytes[i + 7] = (uint8_t)(side >> 8);
            bytes[i + 6] = bytes[i + 8] = (uint8_t)side;
            break;
        }
    }
    return data;
}

static inline void VibeAppendLE32(NSMutableData *data, uint32_t value) {
    uint32_t little = CFSwapInt32HostToLittle(value);
    [data appendBytes:&little length:4];
}

// An APEv2 tag of UTF-8 items and a footer, no header, as written at a file's
// end.
static inline NSData *VibeAPETag(NSArray<NSArray<NSString *> *> *items) {
    NSMutableData *tag = [NSMutableData data];
    for (NSArray<NSString *> *item in items) {
        NSData *value = [item[1] dataUsingEncoding:NSUTF8StringEncoding];
        VibeAppendLE32(tag, (uint32_t)value.length);
        VibeAppendLE32(tag, 0);
        [tag appendData:[item[0] dataUsingEncoding:NSASCIIStringEncoding]];
        [tag increaseLengthBy:1];
        [tag appendData:value];
    }
    uint32_t size = (uint32_t)tag.length + 32;
    [tag appendBytes:"APETAGEX" length:8];
    VibeAppendLE32(tag, 2000);
    VibeAppendLE32(tag, size);
    VibeAppendLE32(tag, (uint32_t)items.count);
    VibeAppendLE32(tag, 0);
    [tag increaseLengthBy:8];
    return tag;
}

// A property map as APE items, under the names MP3Gain and foobar2000 write.
static inline NSArray<NSArray<NSString *> *> *VibeAPEItems(const TagLib::PropertyMap &properties) {
    NSDictionary<NSString *, NSString *> *names = @{@"TITLE": @"Title", @"ARTIST": @"Artist", @"ALBUM": @"Album",
                                                    @"ALBUMARTIST": @"Album Artist", @"DATE": @"Year",
                                                    @"TRACKNUMBER": @"Track", @"DISCNUMBER": @"Disc",
                                                    @"GENRE": @"Genre", @"COMPOSER": @"Composer",
                                                    @"COMPILATION": @"Compilation", @"COMMENT": @"Comment",
                                                    @"GROUPING": @"Grouping", @"LABEL": @"Label",
                                                    @"REMIXER": @"MixArtist"};
    NSMutableArray<NSArray<NSString *> *> *items = [NSMutableArray array];
    for (const auto &[key, values] : properties) {
        NSString *name = @(key.toCString(true));
        [items addObject:@[names[name] ?: name, @(values.front().toCString(true))]];
    }
    return items;
}

// AAC in M4A or FLAC through AVAudioFile, so the container is Apple's own.
static inline NSURL *VibeTagFixtureEncode(NSURL *url, AudioFormatID codec) {
    NSError *error = nil;
    @autoreleasepool {
        NSMutableDictionary *settings = [@{AVFormatIDKey: @(codec), AVSampleRateKey: @44100,
                                           AVNumberOfChannelsKey: @2} mutableCopy];
        if (codec == kAudioFormatFLAC) settings[AVEncoderBitDepthHintKey] = @16;
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings
                                                   commonFormat:AVAudioPCMFormatInt16
                                                    interleaved:YES error:&error];
        if (![file writeFromBuffer:VibeToneBuffer(22050, 44100, 2, AVAudioPCMFormatInt16) error:&error]) {
            return nil;
        }
    }
    return url;
}

// Inserts a metadata block right after STREAMINFO.
static inline BOOL VibeInsertFLACBlock(NSURL *url, uint8_t type, NSData *block) {
    NSMutableData *file = [NSMutableData dataWithContentsOfURL:url];
    if (file.length < 8 || memcmp(file.bytes, "fLaC", 4) != 0) {
        return NO;
    }
    uint8_t *bytes = (uint8_t *)file.mutableBytes;
    BOOL wasLast = (bytes[4] & 0x80) != 0;
    bytes[4] &= 0x7F;
    NSUInteger after = 8 + ((NSUInteger)bytes[5] << 16 | (NSUInteger)bytes[6] << 8 | bytes[7]);
    NSUInteger length = block.length;
    uint8_t header[4] = {(uint8_t)(type | (wasLast ? 0x80 : 0)), (uint8_t)(length >> 16),
                         (uint8_t)(length >> 8), (uint8_t)length};
    NSMutableData *insert = [NSMutableData dataWithBytes:header length:4];
    [insert appendData:block];
    [file replaceBytesInRange:NSMakeRange(after, 0) withBytes:insert.bytes length:insert.length];
    return [file writeToURL:url atomically:YES];
}

static inline void VibeAddAPIC(TagLib::ID3v2::Tag *tag, NSData *art,
                               TagLib::ID3v2::AttachedPictureFrame::Type type =
                                       TagLib::ID3v2::AttachedPictureFrame::FrontCover) {
    if (!art) return;
    auto frame = new TagLib::ID3v2::AttachedPictureFrame();
    frame->setMimeType("image/png");
    frame->setType(type);
    frame->setPicture(VibeTagBytes(art));
    tag->addFrame(frame);
}

// Sound Check as iTunes writes it in ID3v2: a comment described iTunNORM.
static inline void VibeAddSoundCheck(TagLib::ID3v2::Tag *tag) {
    auto frame = new TagLib::ID3v2::CommentsFrame(TagLib::String::Latin1);
    frame->setLanguage("eng");
    frame->setDescription("iTunNORM");
    frame->setText(VibeTagString(kVibeTagSoundCheck));
    tag->addFrame(frame);
}

static inline TagLib::FLAC::Picture *VibeFLACPicture(NSData *art,
                                                    TagLib::FLAC::Picture::Type type = TagLib::FLAC::Picture::FrontCover) {
    auto picture = new TagLib::FLAC::Picture();
    picture->setType(type);
    picture->setMimeType("image/png");
    picture->setData(VibeTagBytes(art));
    return picture;
}

// The fixture's untagged audio at url. NO when the format's source is
// unavailable, as Ogg's is without the render fixtures.
static inline BOOL VibeWriteTagFixtureAudio(NSURL *url, VibeTagFixture fixture) {
    NSError *error = nil;
    switch (fixture) {
        case VibeTagFixtureMP3ID3v23: case VibeTagFixtureMP3ID3v24:
        case VibeTagFixtureMP3ID3v1: case VibeTagFixtureMP3APE:
            return [VibeMP3WithInfoFrame(38, NO) writeToURL:url atomically:YES];
        case VibeTagFixtureM4A:
            return VibeTagFixtureEncode(url, kAudioFormatMPEG4AAC) != nil;
        case VibeTagFixtureFLAC: case VibeTagFixtureFLACCueSheet:
            if (!VibeTagFixtureEncode(url, kAudioFormatFLAC)) return NO;
            if (fixture == VibeTagFixtureFLACCueSheet) {
                NSData *sheet = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(11025), @0, @NO]], 22050);
                return VibeInsertFLACBlock(url, 5, sheet);
            }
            return YES;
        case VibeTagFixtureVorbis: case VibeTagFixtureOpus: {
            NSString *root = NSProcessInfo.processInfo.environment[@"VIBE_AUDIO_FIXTURES"];
            NSString *source = [root stringByAppendingPathComponent:
                    fixture == VibeTagFixtureVorbis ? @"lossy.ogg" : @"lossy.opus"];
            return root && [NSFileManager.defaultManager copyItemAtPath:source toPath:url.path error:NULL];
        }
        case VibeTagFixtureWAVID3: case VibeTagFixtureWAVInfo: case VibeTagFixtureAIFF:
        case VibeTagFixtureCAF: case VibeTagFixtureW64:
            return VibeWriteFixture(url, VibeToneBuffer(22050, 44100, 2, AVAudioPCMFormatInt16), &error) != nil;
        case VibeTagFixtureCount:
            return NO;
    }
}

// Writes `properties` into the fixture's file at url with its format's writer,
// with `art` as its picture and Sound Check where the format carries them.
static inline BOOL VibeSaveTagFixtureTags(NSURL *url, VibeTagFixture fixture, const TagLib::PropertyMap &properties,
                                          NSData *art, BOOL soundCheck) {
    const char *path = url.fileSystemRepresentation;
    switch (fixture) {
        case VibeTagFixtureMP3ID3v23: case VibeTagFixtureMP3ID3v24: {
            TagLib::MPEG::File file(path);
            file.ID3v2Tag(true)->setProperties(properties);
            VibeAddAPIC(file.ID3v2Tag(), art);
            if (soundCheck) VibeAddSoundCheck(file.ID3v2Tag());
            return file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripOthers,
                             fixture == VibeTagFixtureMP3ID3v23 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4,
                             TagLib::File::DoNotDuplicate);
        }
        case VibeTagFixtureMP3ID3v1: {
            TagLib::MPEG::File file(path);
            file.ID3v1Tag(true)->setProperties(properties);
            return file.save(TagLib::MPEG::File::ID3v1, TagLib::File::StripOthers,
                             TagLib::ID3v2::v4, TagLib::File::DoNotDuplicate);
        }
        case VibeTagFixtureMP3APE: {
            // Written by hand: the vendored TagLib has no APE writer for MPEG.
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:NULL];
            [handle seekToEndReturningOffset:NULL error:NULL];
            return [handle writeData:VibeAPETag(VibeAPEItems(properties)) error:NULL]
                    && [handle closeAndReturnError:NULL];
        }
        case VibeTagFixtureM4A: {
            TagLib::MP4::File file(path);
            file.setProperties(properties);
            // No property maps a key in MP4: iTunes' freeform atom carries it.
            if (properties.contains("INITIALKEY")) {
                file.tag()->setItem("----:com.apple.iTunes:initialkey",
                                    TagLib::MP4::Item(TagLib::StringList(VibeTagString(kVibeTagKey))));
            }
            if (soundCheck) {
                file.tag()->setItem("----:com.apple.iTunes:iTunNORM",
                                    TagLib::MP4::Item(TagLib::StringList(VibeTagString(kVibeTagSoundCheck))));
            }
            if (art) {
                TagLib::MP4::CoverArtList covers;
                covers.append(TagLib::MP4::CoverArt(TagLib::MP4::CoverArt::PNG, VibeTagBytes(art)));
                file.tag()->setItem("covr", TagLib::MP4::Item(covers));
            }
            return file.save();
        }
        case VibeTagFixtureFLAC: case VibeTagFixtureFLACCueSheet: {
            TagLib::FLAC::File file(path);
            file.setProperties(properties);
            if (art) file.addPicture(VibeFLACPicture(art));
            return file.save();
        }
        case VibeTagFixtureVorbis: {
            TagLib::Ogg::Vorbis::File file(path);
            file.setProperties(properties);
            if (art) file.tag()->addPicture(VibeFLACPicture(art));
            return file.save();
        }
        case VibeTagFixtureOpus: {
            TagLib::Ogg::Opus::File file(path);
            file.setProperties(properties);
            if (art) file.tag()->addPicture(VibeFLACPicture(art));
            return file.save();
        }
        case VibeTagFixtureWAVID3: {
            TagLib::RIFF::WAV::File file(path);
            file.ID3v2Tag()->setProperties(properties);
            VibeAddAPIC(file.ID3v2Tag(), art);
            if (soundCheck) VibeAddSoundCheck(file.ID3v2Tag());
            return file.save(TagLib::RIFF::WAV::File::ID3v2);
        }
        case VibeTagFixtureWAVInfo: {
            TagLib::RIFF::WAV::File file(path);
            file.InfoTag()->setProperties(properties);
            return file.save(TagLib::RIFF::WAV::File::Info);
        }
        case VibeTagFixtureAIFF: {
            TagLib::RIFF::AIFF::File file(path);
            file.tag()->setProperties(properties);
            VibeAddAPIC(file.tag(), art);
            if (soundCheck) VibeAddSoundCheck(file.tag());
            return file.save();
        }
        case VibeTagFixtureCAF: {
            // CoreAudio's own info chunk: TagLib has no CAF writer.
            AudioFileID file = NULL;
            if (AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadWritePermission, kAudioFileCAFType,
                                 &file) != noErr) {
                return NO;
            }
            CFDictionaryRef info = (__bridge CFDictionaryRef)@{@kAFInfoDictionary_Title: kVibeTagTitle,
                                                               @kAFInfoDictionary_Artist: kVibeTagArtist};
            BOOL saved = AudioFileSetProperty(file, kAudioFilePropertyInfoDictionary, sizeof info, &info) == noErr;
            AudioFileClose(file);
            return saved;
        }
        case VibeTagFixtureW64: case VibeTagFixtureCount:
            return YES;
    }
}

// Writes `fixture` into `dir`, its audio first and then its whole tag, with
// `art` as its picture where the format carries one. `untagged` receives a
// copy from before the tags, which the fuzz diffs to find the tag's bytes.
// nil when the format's source is unavailable.
static inline NSURL *VibeWriteTagFixture(NSURL *dir, VibeTagFixture fixture, NSData *art,
                                         NSURL *__autoreleasing *untagged) {
    NSString *name = VibeTagFixtureName(fixture);
    NSURL *url = [dir URLByAppendingPathComponent:name];
    if (!VibeWriteTagFixtureAudio(url, fixture)) {
        return nil;
    }
    if (untagged) {
        NSURL *copy = [dir URLByAppendingPathComponent:[@"untagged-" stringByAppendingString:name]];
        [NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:NULL];
        *untagged = copy;
    }
    BOOL saved = VibeSaveTagFixtureTags(url, fixture, VibeTagProperties(fixture),
                                        VibeTagFixtureHasArt(fixture) ? art : nil,
                                        VibeTagFixtureCarries(fixture, VibeTagFixtureFieldSoundCheck));
    return saved ? url : nil;
}

// The fixture's audio in `dir`, tagged with `field` alone. nil when the
// format's source is unavailable.
static inline NSURL *VibeWriteTagFieldFixture(NSURL *dir, VibeTagFixture fixture, VibeTagFixtureField field) {
    NSURL *url = [dir URLByAppendingPathComponent:VibeTagFixtureName(fixture)];
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    if (!VibeWriteTagFixtureAudio(url, fixture)) {
        return nil;
    }
    TagLib::PropertyMap properties;
    VibeAddTagField(properties, fixture, field);
    return VibeSaveTagFixtureTags(url, fixture, properties, nil, field == VibeTagFixtureFieldSoundCheck) ? url : nil;
}
