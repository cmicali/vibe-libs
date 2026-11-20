//
//  TagLibAudioFileTests.mm
//  vibe-libs
//
//  TagLibAudioFile's detection over the real TagLib: the extension's parser
//  first, then the content sniff, and FLAC in Ogg refused. The tests write
//  their own files, with AVFoundation's encoders and an MP3's frames. They
//  carry no tags, since detection never reads one, except the INFO tests'.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "TagLibAudioFile.h"
#import "VibeTagFields.h"
#import "VibeTagWriter.h"
#import "AudioFileFixtures.h"
#import "DSFFixtures.h"

#include <audioproperties.h>
#include <dsffile.h>

@interface TagLibAudioFileTests : XCTestCase
@end

@implementation TagLibAudioFileTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                      isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// Half a second of stereo silence at 44.1 kHz in the format `extension`
// names. An MP3 is 38 frames of MPEG-1 Layer III at 320 kbps, since no Apple
// encoder writes MP3. The others go through AVAudioFile: AAC in M4A, FLAC,
// and 16-bit PCM in WAV and AIFF.
- (NSURL *)write:(NSString *)extension {
    NSURL *url = [_dir URLByAppendingPathComponent:[@"audio" stringByAppendingPathExtension:extension]];
    if ([extension isEqualToString:@"mp3"]) {
        NSMutableData *bytes = [NSMutableData dataWithLength:38 * 1044];
        for (NSUInteger frame = 0; frame < 38; frame++) {
            memcpy((uint8_t *)bytes.mutableBytes + frame * 1044, "\xFF\xFB\xE0\x00", 4);
        }
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        return url;
    }
    NSDictionary<NSString *, NSNumber *> *codecs = @{@"m4a": @(kAudioFormatMPEG4AAC), @"flac": @(kAudioFormatFLAC),
                                                     @"wav": @(kAudioFormatLinearPCM), @"aif": @(kAudioFormatLinearPCM)};
    NSMutableDictionary *settings = [@{AVFormatIDKey: codecs[extension], AVSampleRateKey: @44100,
                                       AVNumberOfChannelsKey: @2} mutableCopy];
    if ([extension isEqualToString:@"flac"]) settings[AVEncoderBitDepthHintKey] = @16;
    if (codecs[extension].unsignedIntValue == kAudioFormatLinearPCM) {
        [settings addEntriesFromDictionary:@{AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO,
                                             AVLinearPCMIsBigEndianKey: @([extension isEqualToString:@"aif"])}];
    }
    NSError *error = nil;
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings
                                                   commonFormat:AVAudioPCMFormatInt16 interleaved:YES error:&error];
        AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                   frameCapacity:22050];
        silence.frameLength = 22050;
        memset(silence.int16ChannelData[0], 0, 22050 * 2 * sizeof(int16_t));
        XCTAssertTrue([file writeFromBuffer:silence error:&error], @"%@: %@", extension, error);
    }
    return url;
}

#pragma mark - Detection

static VibeAudioFileFormat Detected(NSURL *url) {
    TagLibAudioFile file(url.fileSystemRepresentation);
    return file.isNull() ? nil : fileTypeForTagLibFile(file.file());
}

- (NSURL *)rename:(NSURL *)url to:(NSString *)name {
    NSURL *renamed = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:url toURL:renamed error:NULL]);
    return renamed;
}

// The extension's parser refuses the file, so the content sniff decides.
- (void)testAWrongExtensionFallsBackToTheContent {
    NSDictionary<NSString *, VibeAudioFileFormat> *cases = @{
            @"m4a-as.flac": VibeAudioFileFormatAAC,
            @"wav-as.m4a": VibeAudioFileFormatWAV,
            @"wav-as.flac": VibeAudioFileFormatWAV,
            @"aiff-as.m4a": VibeAudioFileFormatAIFF,
            @"mp3-as.m4a": VibeAudioFileFormatMP3,
            @"flac-as.m4a": VibeAudioFileFormatFLAC,
    };
    NSDictionary<NSString *, NSString *> *sources = @{
            @"m4a-as.flac": @"m4a", @"wav-as.m4a": @"wav", @"wav-as.flac": @"wav", @"aiff-as.m4a": @"aif",
            @"mp3-as.m4a": @"mp3", @"flac-as.m4a": @"flac",
    };
    for (NSString *name in cases) {
        NSURL *url = [self rename:[self write:sources[name]] to:name];
        XCTAssertEqualObjects(Detected(url), cases[name], @"%@", name);
    }
}

- (void)testNoExtensionSniffsTheContent {
    NSDictionary<NSString *, VibeAudioFileFormat> *cases = @{
            @"flac": VibeAudioFileFormatFLAC, @"mp3": VibeAudioFileFormatMP3, @"m4a": VibeAudioFileFormatAAC,
            @"wav": VibeAudioFileFormatWAV, @"aif": VibeAudioFileFormatAIFF,
    };
    for (NSString *extension in cases) {
        NSString *name = [@"audio-" stringByAppendingString:extension];
        NSURL *url = [self rename:[self write:extension] to:name];
        XCTAssertEqualObjects(Detected(url), cases[extension], @"%@", name);
    }
}

// TagLib's FLAC reader skips a leading ID3v2 tag, and so does its sniff.
- (void)testAFLACWithAnID3v2PrefixReadsAsFLAC {
    NSURL *flac = [self write:@"flac"];
    NSMutableData *bytes = [NSMutableData dataWithBytes:"ID3\x04\x00\x00\x00\x00\x00\x40" length:10];
    [bytes increaseLengthBy:64];
    [bytes appendData:[NSData dataWithContentsOfURL:flac]];
    for (NSString *name in @[@"prefixed.flac", @"prefixed"]) {
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        XCTAssertEqualObjects(Detected(url), VibeAudioFileFormatFLAC, @"%@", name);
    }
}

// A Monkey's Audio file reads by its extension and by its content, behind an
// ID3v2 tag too, with its APEv2 tag's fields and its depth. The fixtures are
// audio/Decode's, made by the SDK's encoder.
- (void)testMonkeysAudioReadsItsAPETag {
    NSURL *tagged = [_dir URLByAppendingPathComponent:@"tagged.ape"];
    NSURL *prefixed = [_dir URLByAppendingPathComponent:@"id3v2-before.ape"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:VibeAPEFixture(@"tagged.ape")
                                                        toURL:tagged error:NULL]);
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:VibeAPEFixture(@"id3v2-before.ape")
                                                        toURL:prefixed error:NULL]);
    NSURL *bare = [_dir URLByAppendingPathComponent:@"bare"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:tagged toURL:bare error:NULL]);
    for (NSURL *url in @[tagged, prefixed, bare]) {
        NSString *name = url.lastPathComponent;
        TagLibAudioFile file(url.fileSystemRepresentation);
        XCTAssertFalse(file.isNull(), @"%@", name);
        if (file.isNull()) {
            continue;
        }
        XCTAssertEqualObjects(fileTypeForTagLibFile(file.file()), VibeAudioFileFormatMonkeysAudio, @"%@", name);
        XCTAssertEqual(bitsPerSampleFromTagLibFile(file.file()), 16, @"%@", name);
        XCTAssertEqual(file.file()->audioProperties()->sampleRate(), 44100, @"%@", name);
        XCTAssertEqualObjects(@(file.tag()->title().toCString(true)), @"Seed Title", @"%@", name);
        XCTAssertEqualObjects(@(file.tag()->artist().toCString(true)), @"Seed Artist", @"%@", name);
        XCTAssertEqualObjects(@(file.tag()->album().toCString(true)), @"Seed Album", @"%@", name);
        XCTAssertEqual(file.tag()->track(), 3u, @"%@", name);
        XCTAssertEqual(file.tag()->year(), 2026u, @"%@", name);
    }
}

// FLAC in Ogg carries "fLaC" in its first page. Playback refuses it, so the
// parse must too, by extension and by content.
- (void)testFLACInOggIsAFailedParse {
    NSMutableData *bytes = [NSMutableData dataWithBytes:"OggS" length:4];
    [bytes increaseLengthBy:24];
    [bytes appendBytes:"\x7F" "FLAC\x01\x00\x00\x01" "fLaC\x80\x00\x00\x22" length:17];
    [bytes increaseLengthBy:34];
    for (NSString *name in @[@"ogg.flac", @"ogg.oga", @"ogg"]) {
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        XCTAssertNil(Detected(url), @"%@", name);
    }
}

// The MPEG, AIFF, and WAV parsers take another format's bytes as valid, so
// the extension's parser alone would read a misnamed file with no tags and
// no audio properties (TagLib #1490).
- (void)testAnMPEGOrRIFFExtensionChecksTheHeaderFirst {
    NSDictionary<NSString *, VibeAudioFileFormat> *cases = @{
            @"flac-as.mp3": VibeAudioFileFormatFLAC,
            @"m4a-as.mp3": VibeAudioFileFormatAAC,
            @"wav-as.mp3": VibeAudioFileFormatWAV,
            @"aiff-as.wav": VibeAudioFileFormatAIFF,
            @"flac-as.wav": VibeAudioFileFormatFLAC,
            @"mp3-as.wav": VibeAudioFileFormatMP3,
            @"wav-as.aif": VibeAudioFileFormatWAV,
            @"m4a-as.aif": VibeAudioFileFormatAAC,
    };
    NSDictionary<NSString *, NSString *> *sources = @{
            @"flac-as.mp3": @"flac", @"m4a-as.mp3": @"m4a", @"wav-as.mp3": @"wav", @"aiff-as.wav": @"aif",
            @"flac-as.wav": @"flac", @"mp3-as.wav": @"mp3", @"wav-as.aif": @"wav", @"m4a-as.aif": @"m4a",
    };
    for (NSString *name in cases) {
        NSURL *url = [self rename:[self write:sources[name]] to:name];
        XCTAssertEqualObjects(Detected(url), cases[name], @"%@", name);
    }
}

// A WAVE whose format is MPEG audio (0x0055) stays MPEG when named .mp3, as
// FileRef keeps it.
- (void)testAWAVEOfMPEGAudioNamedMP3StaysMPEG {
    NSData *frames = [NSData dataWithContentsOfURL:[self write:@"mp3"]];
    NSMutableData *bytes = [NSMutableData data];
    uint32_t riffSize = CFSwapInt32HostToLittle((uint32_t)(4 + 8 + 16 + 8 + frames.length));
    uint32_t fmtSize = CFSwapInt32HostToLittle(16);
    uint32_t dataSize = CFSwapInt32HostToLittle((uint32_t)frames.length);
    [bytes appendBytes:"RIFF" length:4];
    [bytes appendBytes:&riffSize length:4];
    [bytes appendBytes:"WAVEfmt " length:8];
    [bytes appendBytes:&fmtSize length:4];
    [bytes appendBytes:"\x55\x00\x02\x00\x44\xAC\x00\x00\x00\xE2\x04\x00\x01\x00\x00\x00" length:16];
    [bytes appendBytes:"data" length:4];
    [bytes appendBytes:&dataSize length:4];
    [bytes appendData:frames];
    NSURL *url = [_dir URLByAppendingPathComponent:@"mpeg-wave.mp3"];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    XCTAssertEqualObjects(Detected(url), VibeAudioFileFormatMP3);
}

#pragma mark - INFO text

// A WAV of silence whose one LIST INFO chunk holds `title` as its INAM.
// Written by hand: TagLib reads only a file's first INFO list.
- (NSURL *)writeWAVTitled:(NSData *)title {
    NSMutableData *name = [title mutableCopy];
    [name increaseLengthBy:1 + (title.length + 1) % 2];
    uint32_t nameSize = CFSwapInt32HostToLittle((uint32_t)title.length + 1);
    uint32_t listSize = CFSwapInt32HostToLittle((uint32_t)(4 + 8 + name.length));
    uint32_t fmtSize = CFSwapInt32HostToLittle(16);
    uint32_t dataSize = CFSwapInt32HostToLittle(4410 * 4);
    uint32_t riffSize = CFSwapInt32HostToLittle((uint32_t)(4 + 8 + 16 + 8 + 4 + 8 + name.length + 8 + 4410 * 4));
    NSMutableData *bytes = [NSMutableData data];
    [bytes appendBytes:"RIFF" length:4];
    [bytes appendBytes:&riffSize length:4];
    [bytes appendBytes:"WAVEfmt " length:8];
    [bytes appendBytes:&fmtSize length:4];
    [bytes appendBytes:"\x01\x00\x02\x00\x44\xAC\x00\x00\x10\xB1\x02\x00\x04\x00\x10\x00" length:16];
    [bytes appendBytes:"LIST" length:4];
    [bytes appendBytes:&listSize length:4];
    [bytes appendBytes:"INFOINAM" length:8];
    [bytes appendBytes:&nameSize length:4];
    [bytes appendData:name];
    [bytes appendBytes:"data" length:4];
    [bytes appendBytes:&dataSize length:4];
    [bytes increaseLengthBy:4410 * 4];
    NSURL *url = [_dir URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    return url;
}

static NSString *Title(NSURL *url) {
    TagLibAudioFile file(url.fileSystemRepresentation);
    return file.tag() ? @(file.tag()->title().toCString(true)) : nil;
}

// INFO text declares no charset. TagLib 2.3.2 decodes it as UTF-8 and
// answers "" for anything else, so Windows tools' Latin-1 read as nothing.
- (void)testINFOTextReadsAsUTF8OrElseLatin1 {
    XCTAssertEqualObjects(Title([self writeWAVTitled:[NSData dataWithBytes:"Caf\xE9 Cr\xE8me" length:10]]),
                          @"Café Crème");
    XCTAssertEqualObjects(Title([self writeWAVTitled:[@"Café" dataUsingEncoding:NSUTF8StringEncoding]]),
                          @"Café");
    XCTAssertEqualObjects(Title([self writeWAVTitled:[@"Plain" dataUsingEncoding:NSUTF8StringEncoding]]),
                          @"Plain");
}

#pragma mark - WavPack

// A WavPack file reads its APE tag, its kind, its depth, and its cover, by
// its extension or by its content.
- (void)testWavPackReadsItsAPETagDepthAndCover {
    NSURL *named = VibeWavPackFixture(@"s16.wv");
    NSURL *unnamed = [_dir URLByAppendingPathComponent:@"s16-as.m4a"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:named toURL:unnamed error:NULL]);
    for (NSURL *url in @[named, unnamed]) {
        TagLibAudioFile file(url.fileSystemRepresentation);
        XCTAssertFalse(file.isNull(), @"%@", url.lastPathComponent);
        if (file.isNull()) continue;
        XCTAssertEqualObjects(fileTypeForTagLibFile(file.file()), VibeAudioFileFormatWavPack, @"%@", url.lastPathComponent);
        XCTAssertEqual(bitsPerSampleFromTagLibFile(file.file()), 16, @"%@", url.lastPathComponent);
        XCTAssertTrue(file.file()->tag()->title() == "Triangle", @"%@", url.lastPathComponent);
        XCTAssertTrue(file.file()->tag()->artist() == "Vibe Tests", @"%@", url.lastPathComponent);
        XCTAssertEqual(file.file()->tag()->track(), 3u, @"%@", url.lastPathComponent);
        const std::vector<VibeEmbeddedPicture> pictures = VibeEmbeddedPictures(file.file());
        XCTAssertEqual(pictures.size(), 1u, @"%@", url.lastPathComponent);
        if (pictures.empty()) continue;
        XCTAssertEqual(pictures[0].type, 3, @"the front cover");
        XCTAssertTrue(pictures[0].data.startsWith(TagLib::ByteVector("\x89PNG", 4)), @"the picture's bytes, after its name");
        NSData *art = albumArtDataFromTagLibFile(file.file());
        XCTAssertEqual(art.length, (NSUInteger)pictures[0].data.size());
    }
}

// A hybrid file is lossless only with its correction file, another file, so
// it states no PCM depth. It states its source's apart. A lossless float file
// states 32. DSD states 1 bit, as a DSF does.
- (void)testWavPackStatesADepthOnlyForLosslessPCM {
    NSDictionary<NSString *, NSNumber *> *depths = @{@"hybrid.wv": @0, @"dsd.wv": @1, @"f32.wv": @32, @"s24.wv": @24, @"u8.wv": @8};
    for (NSString *name in depths) {
        TagLibAudioFile file(VibeWavPackFixture(name).fileSystemRepresentation);
        XCTAssertFalse(file.isNull(), @"%@", name);
        if (file.isNull()) continue;
        XCTAssertEqualObjects(fileTypeForTagLibFile(file.file()), VibeAudioFileFormatWavPack, @"%@", name);
        XCTAssertEqual(bitsPerSampleFromTagLibFile(file.file()), depths[name].intValue, @"%@", name);
        XCTAssertEqual(VibeWavPackHybridBitsFromTagLibFile(file.file()), [name isEqualToString:@"hybrid.wv"] ? 16 : 0, @"%@", name);
    }
}

#pragma mark - DSF

// A DSF's ID3v2 tag: two text frames and a JPEG front cover, ID3v2.3.
static NSData *VibeDSFTag(NSData *jpeg) {
    NSMutableData *frames = [NSMutableData data];
    NSMutableData *title = [NSMutableData dataWithBytes:"\0Tone" length:5];
    [frames appendData:VibeID3v2Frame("TIT2", 3, (uint32_t)title.length, 0, title)];
    NSMutableData *artist = [NSMutableData dataWithBytes:"\0Modulator" length:10];
    [frames appendData:VibeID3v2Frame("TPE1", 3, (uint32_t)artist.length, 0, artist)];
    NSMutableData *picture = [NSMutableData dataWithBytes:"\0image/jpeg\0\x03\0" length:14];
    [picture appendData:jpeg];
    [frames appendData:VibeID3v2Frame("APIC", 3, (uint32_t)picture.length, 0, picture)];
    return VibeID3v2Tag(3, 0, frames);
}

- (NSURL *)writeDSF:(NSString *)name tag:(NSData *)tag {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([VibeDSFFile(2, 1, YES, 100000, VibeDSFSine(1000, 0.5), tag) writeToURL:url atomically:YES]);
    return url;
}

- (void)testADSFReadsItsTagCoverAndProperties {
    NSData *jpeg = [NSData dataWithBytes:"\xFF\xD8\xFF\xE0 not a real picture \xFF\xD9" length:26];
    NSURL *url = [self writeDSF:@"tone.dsf" tag:VibeDSFTag(jpeg)];
    TagLibAudioFile file(url.fileSystemRepresentation);
    XCTAssertFalse(file.isNull());
    XCTAssertEqualObjects(fileTypeForTagLibFile(file.file()), VibeAudioFileFormatDSD);
    XCTAssertTrue(tagLibFileCarriesID3v2(file.file()));
    XCTAssertEqual(bitsPerSampleFromTagLibFile(file.file()), 1);
    XCTAssertEqual(file.tag()->title(), TagLib::String("Tone"));
    XCTAssertEqual(file.tag()->artist(), TagLib::String("Modulator"));
    XCTAssertEqualObjects(albumArtDataFromTagLibFile(file.file()), jpeg);
    TagLib::AudioProperties *properties = file.file()->audioProperties();
    XCTAssertEqual(properties ? properties->sampleRate() : 0, 2822400);
    XCTAssertEqual(properties ? properties->channels() : 0, 2);
}

- (void)testADSFWithNoTagParsesWithAnEmptyOne {
    TagLibAudioFile file([self writeDSF:@"untagged.dsf" tag:nil].fileSystemRepresentation);
    XCTAssertFalse(file.isNull());
    XCTAssertEqualObjects(fileTypeForTagLibFile(file.file()), VibeAudioFileFormatDSD);
    XCTAssertTrue(file.tag() == nullptr || file.tag()->isEmpty());
    XCTAssertNil(albumArtDataFromTagLibFile(file.file()));
}

- (void)testADSFMisnamedOrUnnamedSniffsAsDSF {
    NSURL *dsf = [self writeDSF:@"sniffed.dsf" tag:nil];
    XCTAssertEqualObjects(Detected([self rename:dsf to:@"misnamed.mp3"]), VibeAudioFileFormatDSD);
    dsf = [self writeDSF:@"sniffed.dsf" tag:nil];
    XCTAssertEqualObjects(Detected([self rename:dsf to:@"noextension"]), VibeAudioFileFormatDSD);
}

// DSF tags are read-only for now: the writer takes no DSF.
- (void)testTheWriterRefusesADSF {
    NSURL *url = [self writeDSF:@"readonly.dsf" tag:VibeDSFTag([NSData dataWithBytes:"\xFF\xD8\xFF\xD9" length:4])];
    NSData *before = [NSData dataWithContentsOfURL:url];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibWriteTags(url.path, @{VibeTagFieldTitle: @[@"New"]}, NO, nil, nil, VibeTagWriteSyncFull, NULL, &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorNoParser);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before);
}

@end
