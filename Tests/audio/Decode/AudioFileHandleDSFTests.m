//
//  AudioFileHandleDSFTests.m
//  vibe-libs
//
//  A DSF file's DSD read as PCM: the open, the facts, the tone's frequency and
//  level, both bit orders, every rate and channel type, the trimmed length,
//  the seeks, and damaged and hostile files. The fixtures are modulated here
//  (DSFFixtures.h).
//

#import <XCTest/XCTest.h>

#import "AudioFileHandle.h"
#import "AudioFileFixtures.h"
#import "DSFFixtures.h"
#import "ToneFit.h"
#import "VibeDSF.h"

@interface AudioFileHandleDSFTests : XCTestCase
@property (strong) NSURL *directory;
@end

@implementation AudioFileHandleDSFTests

- (void)setUp {
    [super setUp];
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:NULL];
    [super tearDown];
}

- (NSURL *)write:(NSData *)data named:(NSString *)name {
    NSURL *url = [self.directory URLByAppendingPathComponent:name];
    XCTAssertTrue([data writeToURL:url atomically:NO], @"%@", name);
    return url;
}

- (AudioFileHandle *)open:(NSURL *)url {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(handle, @"%@: %@", url.lastPathComponent, error);
    return handle;
}

// Every frame, interleaved.
- (NSData *)decode:(AudioFileHandle *)handle {
    NSMutableData *capture = [NSMutableData data];
    NSError *error = nil;
    XCTAssertTrue(VibeReadToEnd(handle, capture, &error), @"%@", error);
    return capture;
}

// The fit of a sine at `frequency` to one channel, over `frames` frames from
// `start`, its time counted from the file's start (ToneFit.h).
static VibeToneFit VibeFitChannel(const float *samples, uint32_t channels, uint32_t channel, double rate,
                                  double frequency, size_t start, size_t frames) {
    double *x = malloc(frames * sizeof(double));
    for (size_t i = 0; i < frames; i++) {
        x[i] = samples[(start + i) * channels + channel];
    }
    VibeToneFit fit = VibeFitTone(x, frames, frequency, rate, (double)start, 0);
    free(x);
    return fit;
}

// The fitted tone's level, in dB of full scale.
static double VibeFittedLevel(const float *samples, uint32_t channels, uint32_t channel, double rate,
                              double frequency, size_t start, size_t frames) {
    return 20 * log10(VibeFitChannel(samples, channels, channel, rate, frequency, start, frames).amplitude);
}

#pragma mark - The facts and the tone

- (void)testAStereoDSD64OpensAsPCMAt176kAndKeepsItsDSDRate {
    VibeDSFSignal tones = ^double(uint32_t channel, double t) { return 0.5 * sin(2 * M_PI * (channel ? 3000 : 1000) * t); };
    AudioFileHandle *handle = [self open:[self write:VibeDSFFile(2, 1, YES, 2822400 / 4, tones, nil) named:@"tone.dsf"]];
    XCTAssertEqualObjects(handle.decoderName, @"dsd");
    XCTAssertEqual(handle.dsdSampleRate, 2822400);
    XCTAssertEqual(handle.processingFormat.sampleRate, 176400);
    XCTAssertEqual(handle.processingFormat.channelCount, 2u);
    XCTAssertEqual(handle.fileFormat.sampleRate, 176400);
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, kAudioFormatLinearPCM);
    XCTAssertEqual(handle.length, 2822400 / 4 / 16);
    NSData *pcm = [self decode:handle];
    XCTAssertEqual(pcm.length, (NSUInteger)handle.length * 2 * sizeof(float));
    const float *samples = pcm.bytes;
    // 0 dB SACD, half of full scale, is -6.02 dBFS. The fit spans 200 ms, whole
    // periods of both tones, so neither leaks into the other's fit.
    XCTAssertEqualWithAccuracy(VibeFittedLevel(samples, 2, 0, 176400, 1000, 4410, 35280), -6.02, 0.05);
    XCTAssertEqualWithAccuracy(VibeFittedLevel(samples, 2, 1, 176400, 3000, 4410, 35280), -6.02, 0.05);
    // Each channel holds its own tone and nothing of the other's.
    XCTAssertLessThan(VibeFittedLevel(samples, 2, 0, 176400, 3000, 4410, 35280), -90);
    XCTAssertLessThan(VibeFittedLevel(samples, 2, 1, 176400, 1000, 4410, 35280), -90);
    // The tone is clean: what is left is the modulator's ultrasonic noise,
    // most of it above 20 kHz.
    XCTAssertLessThan(VibeDB(VibeFitChannel(samples, 2, 0, 176400, 1000, 4410, 35280).residualPower), -50);
}

- (void)testTheToneIsInPhaseWithTheDSD {
    // A frame of output is the DSD at its time, so a sine's zero crossing
    // lands where the modulated one's does.
    AudioFileHandle *handle = [self open:[self write:VibeDSFFile(1, 1, NO, 2822400 / 8, VibeDSFSine(1000, 0.5), nil)
                                              named:@"phase.dsf"]];
    NSData *pcm = [self decode:handle];
    VibeToneFit fit = VibeFitChannel(pcm.bytes, 1, 0, 176400, 1000, 4410, 17640);
    // The modulated sine is b·sin, so its cos term, a, is the phase error.
    // Under a microsecond: well inside one 176.4 kHz frame (5.7 µs).
    XCTAssertLessThan(fabs(atan2(fit.a, fit.b)) / (2 * M_PI * 1000), 1e-6);
}

- (void)testBothBitOrdersDecodeTheSame {
    VibeDSFSignal sine = VibeDSFSine(440, 0.4);
    NSData *lsb = [self decode:[self open:[self write:VibeDSFFile(2, 1, YES, 300000, sine, nil) named:@"lsb.dsf"]]];
    NSData *msb = [self decode:[self open:[self write:VibeDSFFile(2, 1, NO, 300000, sine, nil) named:@"msb.dsf"]]];
    XCTAssertGreaterThan(lsb.length, 0u);
    XCTAssertEqualObjects(lsb, msb);
}

- (void)testEveryRateComesOutAt176kOr192k {
    struct { double base; uint32_t multiple; double output; } rates[] = {
        {2822400, 1, 176400}, {2822400, 2, 176400}, {2822400, 4, 176400}, {2822400, 8, 176400}, {3072000, 1, 192000},
    };
    for (size_t r = 0; r < sizeof rates / sizeof rates[0]; r++) {
        double dsdRate = rates[r].base * rates[r].multiple;
        uint64_t samples = (uint64_t)(dsdRate / 8);
        NSString *name = [NSString stringWithFormat:@"rate-%.0f.dsf", dsdRate];
        AudioFileHandle *handle = [self open:[self write:VibeDSFFileAtRate(1, rates[r].base, rates[r].multiple, YES, samples,
                                                                           VibeDSFSine(1000, 0.5), nil) named:name]];
        XCTAssertEqual(handle.dsdSampleRate, dsdRate, @"%@", name);
        XCTAssertEqual(handle.processingFormat.sampleRate, rates[r].output, @"%@", name);
        XCTAssertEqual(handle.length, (AVAudioFramePosition)(samples / (16 * rates[r].multiple)), @"%@", name);
        NSData *pcm = [self decode:handle];
        size_t start = (size_t)(rates[r].output / 40);
        XCTAssertEqualWithAccuracy(VibeFittedLevel(pcm.bytes, 1, 0, rates[r].output, 1000, start, start * 3), -6.02, 0.05, @"%@", name);
    }
}

- (void)testEveryChannelTypeOpensWithItsLayout {
    struct { uint32_t type; AudioChannelLabel labels[6]; } types[] = {
        {3, {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center}},
        {4, {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround}},
        {5, {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen}},
        {6, {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LeftSurround,
             kAudioChannelLabel_RightSurround}},
        {7, {kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
             kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround}},
    };
    // Each channel its own tone, so a channel read from another's block shows.
    VibeDSFSignal tones = ^double(uint32_t channel, double t) { return 0.5 * sin(2 * M_PI * 1000 * (channel + 1) * t); };
    for (size_t i = 0; i < sizeof types / sizeof types[0]; i++) {
        uint32_t channels = VibeDSFChannelsOfType(types[i].type);
        NSString *name = [NSString stringWithFormat:@"type-%u.dsf", types[i].type];
        AudioFileHandle *handle = [self open:[self write:VibeDSFFile(types[i].type, 1, YES, 120000, tones, nil) named:name]];
        XCTAssertEqual(handle.processingFormat.channelCount, channels, @"%@", name);
        const AudioChannelLayout *layout = handle.processingFormat.channelLayout.layout;
        XCTAssertEqual(layout ? layout->mNumberChannelDescriptions : 0, channels, @"%@", name);
        for (uint32_t c = 0; layout && c < MIN(channels, layout->mNumberChannelDescriptions); c++) {
            XCTAssertEqual(layout->mChannelDescriptions[c].mChannelLabel, types[i].labels[c], @"%@ channel %u", name, c);
        }
        NSData *pcm = [self decode:handle];
        for (uint32_t c = 0; c < channels; c++) {
            XCTAssertEqualWithAccuracy(VibeFittedLevel(pcm.bytes, channels, c, 176400, 1000.0 * (c + 1), 1000, 4000), -6.02, 0.1,
                                       @"%@ channel %u", name, c);
        }
    }
}

// Mono and stereo carry no layout, as every decoder's do: their order is plain.
- (void)testMonoAndStereoCarryNoLayout {
    AudioFileHandle *mono = [self open:[self write:VibeDSFFile(1, 1, YES, 40000, VibeDSFSine(1000, 0.5), nil) named:@"mono.dsf"]];
    XCTAssertEqual(mono.processingFormat.channelCount, 1u);
    XCTAssertNil(mono.processingFormat.channelLayout);
    AudioFileHandle *stereo = [self open:[self write:VibeDSFFile(2, 1, YES, 40000, VibeDSFSine(1000, 0.5), nil) named:@"stereo.dsf"]];
    XCTAssertEqual(stereo.processingFormat.channelCount, 2u);
    XCTAssertNil(stereo.processingFormat.channelLayout);
}

#pragma mark - The length and the seeks

- (void)testTheSampleCountTrimsTheLastBlocksPadding {
    // Not a whole byte, block, or frame: 5 blocks and some, and 3 bits.
    uint64_t samples = 5 * 4096 * 8 + 1234 * 8 + 3;
    AudioFileHandle *handle = [self open:[self write:VibeDSFFile(2, 1, YES, samples, VibeDSFSine(1000, 0.5), nil)
                                              named:@"trim.dsf"]];
    XCTAssertEqual(handle.length, (AVAudioFramePosition)(samples / 16));
    NSData *pcm = [self decode:handle];
    XCTAssertEqual(pcm.length, (NSUInteger)handle.length * 2 * sizeof(float));
    // The padding is zeros, a full-scale negative DC. Read as samples, it
    // would pull the last frames toward -1.
    const float *samples32 = pcm.bytes;
    size_t frames = (size_t)handle.length;
    for (size_t i = frames - 30; i < frames; i++) {
        XCTAssertLessThan(fabsf(samples32[i * 2]), 0.6f, @"frame %zu", i);
    }
}

- (void)testASeekLandsOnTheSampleAReadFromTheStartGives {
    [self assertSeeksAtMultiple:1];
}

- (void)testASeekAtDSD512LandsOnTheSampleAReadFromTheStartGives {
    [self assertSeeksAtMultiple:8];
}

- (void)assertSeeksAtMultiple:(uint32_t)multiple {
    NSString *name = [NSString stringWithFormat:@"seek-%u.dsf", multiple];
    NSURL *url = [self write:VibeDSFFile(2, multiple, YES, 400000ull * multiple, VibeDSFSine(997, 0.5), nil) named:name];
    NSData *whole = [self decode:[self open:url]];
    const float *reference = whole.bytes;
    AudioFileHandle *handle = [self open:url];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:5000];
    AVAudioFramePosition targets[] = {0, 1, 26, 27, 53, 1000, 4097, 12345, handle.length - 100};
    for (size_t t = 0; t < sizeof targets / sizeof targets[0]; t++) {
        AVAudioFramePosition target = targets[t];
        NSError *error = nil;
        XCTAssertTrue([handle seekToFrame:target error:&error], @"%@", error);
        XCTAssertEqual(handle.framePosition, target);
        XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
        AVAudioFrameCount expected = (AVAudioFrameCount)MIN(5000, handle.length - target);
        XCTAssertEqual(buffer.frameLength, expected, @"at %lld", target);
        for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++) {
            for (int c = 0; c < 2; c++) {
                if (buffer.floatChannelData[c][f] != reference[(target + f) * 2 + c]) {
                    XCTFail(@"seek to %lld: frame %u channel %d differs", target, f, c);
                    return;
                }
            }
        }
        XCTAssertEqual(handle.framePosition, target + expected);
    }
    NSError *error = nil;
    XCTAssertTrue([handle seekToFrame:handle.length + 1000 error:&error], @"%@", error);
    XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, 0u);
}

- (void)testInterleavedReadsMatchPlanarOnes {
    NSURL *url = [self write:VibeDSFFile(7, 1, YES, 100000, VibeDSFSine(500, 0.5), nil) named:@"interleaved.dsf"];
    NSData *planar = [self decode:[self open:url]];
    NSError *error = nil;
    AudioFileHandle *interleaved = [[AudioFileHandle alloc] initForReading:url interleaved:YES error:&error];
    XCTAssertNotNil(interleaved, @"%@", error);
    XCTAssertTrue(interleaved.processingFormat.isInterleaved);
    XCTAssertEqualObjects([self decode:interleaved], planar);
}

#pragma mark - Damage

- (void)testATruncatedFilePlaysTheSamplesItHolds {
    NSData *whole = VibeDSFFile(2, 1, YES, 300000, VibeDSFSine(1000, 0.5), nil);
    // Cut inside the fourth group of blocks, in the second channel's block.
    NSUInteger cut = 92 + 3 * 2 * 4096 + 4096 + 1000;
    AudioFileHandle *handle = [self open:[self write:[whole subdataWithRange:NSMakeRange(0, cut)] named:@"cut.dsf"]];
    // Each channel holds three whole blocks and the second channel's 1,000 bytes.
    XCTAssertEqual(handle.length, (AVAudioFramePosition)((3 * 4096 + 1000) * 8 / 16));
    NSData *pcm = [self decode:handle];
    XCTAssertEqual(pcm.length, (NSUInteger)handle.length * 2 * sizeof(float));
}

- (void)testAFileShorterThanItsHeaderIsRefused {
    NSData *whole = VibeDSFFile(2, 1, YES, 10000, VibeDSFSine(1000, 0.5), nil);
    NSUInteger cuts[] = {0, 3, 4, 50, 91};
    for (size_t i = 0; i < sizeof cuts / sizeof cuts[0]; i++) {
        NSUInteger cut = cuts[i];
        NSURL *url = [self write:[whole subdataWithRange:NSMakeRange(0, cut)] named:[NSString stringWithFormat:@"short-%lu.dsf", (unsigned long)cut]];
        XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:NULL], @"%lu bytes", (unsigned long)cut);
    }
}

// Each field forged in turn: refused, or opened with a length the data holds,
// and read to its end without a crash.
- (void)testHostileHeadersAreRefusedOrBounded {
    NSData *valid = VibeDSFFile(2, 1, YES, 50000, VibeDSFSine(1000, 0.5), nil);
    struct { size_t offset; int bytes; uint64_t value; BOOL opens; } forgeries[] = {
        {4, 8, 29, NO},                     // the DSD chunk's size
        {32, 8, 0, NO},                     // the fmt chunk's size
        {40, 4, 2, NO},                     // the format version
        {44, 4, 1, NO},                     // a format other than raw DSD
        {48, 4, 0, NO},                     // no channel type
        {48, 4, 8, NO},                     // a channel type past 7
        {52, 4, 3, NO},                     // channels the type does not name
        {52, 4, 0xFFFFFFFF, NO},
        {56, 4, 0, NO},                     // no rate
        {56, 4, 2822401, NO},               // a rate no DSD has
        {56, 4, 2822400u * 16, NO},         // DSD1024
        {60, 4, 4, NO},                     // 4 bits a sample
        {72, 4, 0, NO},                     // no block size
        {72, 4, 0xFFFFFFFF, NO},
        {64, 8, UINT64_MAX, YES},           // a sample count past the data: trimmed
        {64, 8, 0, YES},                    // no samples
        {84, 8, 0, NO},                     // a data chunk shorter than its header
        {84, 8, UINT64_MAX, YES},           // a data chunk past the file: trimmed
        {12, 8, UINT64_MAX, YES},           // a file size past the file
        {20, 8, UINT64_MAX, YES},           // a tag past the file
        {20, 8, 5, YES},                    // a tag inside the header
    };
    for (size_t i = 0; i < sizeof forgeries / sizeof forgeries[0]; i++) {
        NSMutableData *forged = [valid mutableCopy];
        for (int b = 0; b < forgeries[i].bytes; b++) {
            ((uint8_t *)forged.mutableBytes)[forgeries[i].offset + b] = (uint8_t)(forgeries[i].value >> (8 * b));
        }
        NSString *name = [NSString stringWithFormat:@"forged-%zu.dsf", i];
        AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:[self write:forged named:name] error:NULL];
        XCTAssertEqual(handle != nil, forgeries[i].opens, @"%@: offset %zu", name, forgeries[i].offset);
        if (handle) {
            // At most the two blocks a channel the data holds, padding and all.
            XCTAssertLessThanOrEqual(handle.length, 2 * 4096 * 8 / 16, @"%@", name);
            NSData *pcm = [self decode:handle];
            XCTAssertEqual(pcm.length, (NSUInteger)handle.length * 2 * sizeof(float), @"%@", name);
        }
    }
}

- (void)testADSDIFFFileIsRefused {
    // DSDIFF, which may hold DST, is out of scope: no decoder takes it.
    NSMutableData *dff = [NSMutableData dataWithBytes:"FRM8\0\0\0\0\0\0\0\x40" "DSD " length:16];
    [dff increaseLengthBy:4096];
    NSError *error = nil;
    XCTAssertNil([[AudioFileHandle alloc] initForReading:[self write:dff named:@"file.dff"] error:&error]);
    XCTAssertNotNil(error);
}

#pragma mark - The parser

- (void)testTheParserMapsEachChannelsBytesAcrossTheBlocks {
    NSData *file = VibeDSFFile(3, 1, NO, 3 * 4096 * 8, VibeDSFSine(1000, 0.5), nil);
    VibeDSFInfo info;
    XCTAssertTrue(VibeDSFParseHeader(file.bytes, file.length, file.length, &info));
    XCTAssertEqual(info.channels, 3u);
    XCTAssertEqual(VibeDSFByteOffset(&info, 0, 0), 92u);
    XCTAssertEqual(VibeDSFByteOffset(&info, 2, 0), 92u + 2 * 4096);
    XCTAssertEqual(VibeDSFByteOffset(&info, 1, 4096 + 5), 92u + 4 * 4096 + 5);
}

@end
