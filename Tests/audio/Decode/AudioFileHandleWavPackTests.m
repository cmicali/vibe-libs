//
// WavPack through AudioFileHandle, by libwavpack: the facts each kind of file
// states, a lossless decode bit for bit, seeks, a hybrid file lossless with
// its correction file and lossy without it, DSD as its DSF decodes, a file that never
// stated its length, and cut files. Also the AIFF-C spellings, which dr_wav
// plays. AudioFileHandleReadAheadTests interrupts a hybrid pair's reads.
//
// The fixtures are in WavPack/ beside this file. make-fixtures.sh made them
// from make-sources.py's integer signals, which VibeWavPackSample repeats.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"
#import "AudioFileFixtures.h"

@interface AudioFileHandleWavPackTests : XCTestCase
@property (strong) NSURL *scratch;
@end

// make-sources.py's sample at one frame and channel, `bits` wide, signed.
static int64_t VibeWavPackSample(uint64_t index, uint64_t frame, uint32_t channel, uint32_t bits) {
    uint32_t state = (uint32_t)(index * 2654435761u + 12345u);
    state = state * 1664525u + 1013904223u;
    int64_t noise = (int64_t)(state >> 16) - 32768;
    int64_t full = (int64_t)1 << (bits - 1), amplitude = full >> 1;
    int64_t period = 200 + 37 * (int64_t)channel, p = (int64_t)(frame % (uint64_t)period);
    int64_t triangle = p < period / 2 ? -amplitude + (4 * amplitude * p) / period : 3 * amplitude - (4 * amplitude * p) / period;
    return triangle + ((noise * full) >> 19);
}

// One lossless fixture: what it holds and what the handle states for it.
typedef struct {
    const char *name;
    double rate;
    uint32_t channels, frames, bits, container;
    BOOL isFloat, isSigned;
} VibeWavPackLossless;

static const VibeWavPackLossless kLossless[] = {
    {"s16.wv", 44100, 2, 8192, 16, 16, NO, YES},
    {"s24.wv", 96000, 2, 16384, 24, 24, NO, YES},
    {"s20.wv", 48000, 2, 4096, 20, 24, NO, YES},
    {"s32.wv", 48000, 2, 4096, 32, 32, NO, YES},
    {"f32.wv", 44100, 2, 4096, 24, 32, YES, NO},
    {"u8.wv", 22050, 1, 4096, 8, 8, NO, NO},
    {"surround.wv", 48000, 6, 4096, 16, 16, NO, YES},
};

// The floats a fixture's samples decode to, interleaved: an integer scaled by
// its container as dr_wav scales a WAV's, a float as it was written.
static NSData *VibeWavPackExpected(VibeWavPackLossless fixture) {
    NSMutableData *pcm = [NSMutableData dataWithLength:(NSUInteger)fixture.frames * fixture.channels * sizeof(float)];
    float *out = pcm.mutableBytes;
    uint32_t bits = fixture.isFloat ? 24 : fixture.bits;
    for (uint64_t f = 0; f < fixture.frames; f++) {
        for (uint32_t c = 0; c < fixture.channels; c++) {
            uint64_t i = f * fixture.channels + c;
            int64_t value = VibeWavPackSample(i, f, c, bits);
            out[i] = fixture.isFloat ? (float)((double)value / 8388608.0)
                                     : (float)((double)(value << (fixture.container - fixture.bits)) / (double)(1ull << (fixture.container - 1)));
        }
    }
    return pcm;
}


static NSData *VibeDecodeRange(AudioFileHandle *handle, AVAudioFramePosition from, AVAudioFrameCount frames) {
    if (![handle seekToFrame:from error:NULL]) return nil;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:frames];
    if (![handle readIntoBuffer:buffer frameCount:frames error:NULL]) return nil;
    NSMutableData *capture = [NSMutableData data];
    VibeAppendPCM(capture, buffer);
    return capture;
}

@implementation AudioFileHandleWavPackTests

- (void)setUp {
    [super setUp];
    self.scratch = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                              isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.scratch withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.scratch error:nil];
    [super tearDown];
}

// hybrid.wv in the scratch folder, as `name`, with `wvc` beside it as
// `wvcName` when given.
- (NSURL *)hybridNamed:(NSString *)name beside:(NSData *)wvc named:(NSString *)wvcName {
    NSURL *url = [self.scratch URLByAppendingPathComponent:name];
    XCTAssertTrue([[NSData dataWithContentsOfURL:VibeWavPackFixture(@"hybrid.wv")] writeToURL:url atomically:YES]);
    if (wvc) {
        XCTAssertTrue([wvc writeToURL:[self.scratch URLByAppendingPathComponent:wvcName] atomically:YES]);
    }
    return url;
}

- (AudioFileHandle *)open:(NSURL *)url interleaved:(BOOL)interleaved {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url interleaved:interleaved error:&error];
    XCTAssertNotNil(handle, @"%@: %@", url.lastPathComponent, error);
    return handle;
}

#pragma mark - Lossless

// Every lossless fixture decodes to its source's samples exactly, in either
// layout, and states its facts as the WAV it was packed from.
- (void)testLosslessFilesDecodeBitForBitAndStateTheirSource {
    for (size_t i = 0; i < sizeof kLossless / sizeof *kLossless; i++) {
        VibeWavPackLossless fixture = kLossless[i];
        NSString *name = @(fixture.name);
        NSData *expected = VibeWavPackExpected(fixture);
        for (int interleaved = 0; interleaved < 2; interleaved++) {
            AudioFileHandle *handle = [self open:VibeWavPackFixture(name) interleaved:interleaved];
            XCTAssertEqualObjects(handle.decoderName, @"libwavpack", @"%@", name);
            XCTAssertEqual(handle.length, (AVAudioFramePosition)fixture.frames, @"%@", name);
            const AudioStreamBasicDescription *file = handle.fileFormat.streamDescription;
            XCTAssertEqual(file->mSampleRate, fixture.rate, @"%@", name);
            XCTAssertEqual(file->mChannelsPerFrame, fixture.channels, @"%@", name);
            XCTAssertEqual(file->mFormatID, kAudioFormatLinearPCM, @"%@", name);
            XCTAssertEqual(file->mBitsPerChannel, fixture.isFloat ? 32u : fixture.bits, @"%@", name);
            XCTAssertEqual(file->mBytesPerFrame, fixture.container / 8 * fixture.channels, @"%@", name);
            XCTAssertEqual((file->mFormatFlags & kAudioFormatFlagIsFloat) != 0, fixture.isFloat, @"%@", name);
            XCTAssertEqual((file->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0, fixture.isSigned, @"%@", name);
            XCTAssertEqual((file->mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0, fixture.bits < fixture.container && !fixture.isFloat,
                           @"%@: a narrow sample is high-aligned in its bytes", name);
            NSMutableData *pcm = [NSMutableData data];
            NSError *error = nil;
            XCTAssertTrue(VibeReadToEnd(handle, pcm, &error), @"%@: %@", name, error);
            XCTAssertEqualObjects(pcm, expected, @"%@, interleaved %d", name, interleaved);
            XCTAssertEqual(handle.framePosition, (AVAudioFramePosition)fixture.frames, @"%@", name);
        }
    }
}

// Five or more channels fold as the file's mask says, as a WAV's do. Mono
// and stereo state no layout.
- (void)testSurroundStatesItsChannelMask {
    AudioFileHandle *surround = [self open:VibeWavPackFixture(@"surround.wv") interleaved:NO];
    const AudioChannelLayout *layout = surround.fileFormat.channelLayout.layout;
    XCTAssertTrue(layout != NULL);
    XCTAssertEqual(layout->mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap);
    XCTAssertEqual(layout->mChannelBitmap, 0x3Fu);
    XCTAssertNil([self open:VibeWavPackFixture(@"s16.wv") interleaved:NO].fileFormat.channelLayout);
}

#pragma mark - Seeking

// A seek lands on the frame asked for, inside a block, at a block's start,
// and across many blocks, both ways. Past the end, it lands at the end, and
// reads nothing.
- (void)testSeeksLandExactly {
    for (NSString *name in @[@"s16.wv", @"surround.wv", @"hybrid.wv"]) {
        AudioFileHandle *handle = [self open:VibeWavPackFixture(name) interleaved:YES];
        NSMutableData *whole = [NSMutableData data];
        XCTAssertTrue(VibeReadToEnd(handle, whole, NULL), @"%@", name);
        AVAudioFramePosition length = handle.length;
        size_t frameBytes = handle.processingFormat.channelCount * sizeof(float);
        XCTAssertEqual(whole.length, (NSUInteger)length * frameBytes, @"%@", name);
        for (NSNumber *target in @[@(length - 300), @0, @1, @1023, @1024, @3000, @17, @(length / 2), @5]) {
            AVAudioFramePosition at = target.longLongValue;
            NSData *read = VibeDecodeRange(handle, at, 300);
            NSData *slice = [whole subdataWithRange:NSMakeRange((NSUInteger)at * frameBytes,
                                                                MIN(300 * frameBytes, whole.length - (NSUInteger)at * frameBytes))];
            XCTAssertEqualObjects(read, slice, @"%@ at %lld", name, at);
            XCTAssertEqual(handle.framePosition, at + (AVAudioFramePosition)(read.length / frameBytes), @"%@ at %lld", name, at);
        }
        for (NSNumber *past in @[@(length), @(length + 1000)]) {
            XCTAssertTrue([handle seekToFrame:past.longLongValue error:NULL], @"%@", name);
            XCTAssertEqual(handle.framePosition, length, @"%@", name);
            XCTAssertEqual(VibeDecodeRange(handle, past.longLongValue, 64).length, 0u, @"%@", name);
        }
        XCTAssertEqualObjects(VibeDecodeRange(handle, 100, 64), [whole subdataWithRange:NSMakeRange(100 * frameBytes, 64 * frameBytes)],
                              @"%@: a seek back from the end", name);
    }
}

#pragma mark - Lossy, DSD, and the length

// A hybrid file alone plays its lossy half. It states WavPack's own format
// and no depth, so bit-perfect output keeps none, and it sounds like its
// source.
- (void)testAHybridFileAlonePlaysItsLossyHalf {
    AudioFileHandle *handle = [self open:[self hybridNamed:@"alone.wv" beside:nil named:nil] interleaved:YES];
    XCTAssertNil(handle.correctionFileURL);
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, (AudioFormatID)'wvpk');
    XCTAssertEqual(handle.fileFormat.streamDescription->mBitsPerChannel, 0u);
    XCTAssertEqual(handle.length, 8192);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    NSData *source = VibeWavPackExpected(kLossless[0]);
    XCTAssertEqual(pcm.length, source.length);
    const float *got = pcm.bytes, *want = source.bytes;
    double error = 0, signal = 0;
    for (NSUInteger i = 0; i < pcm.length / sizeof(float); i++) {
        error += (got[i] - want[i]) * (got[i] - want[i]);
        signal += want[i] * want[i];
    }
    XCTAssertGreaterThan(error, 0, @"the lossy half, not the lossless decode");
    XCTAssertLessThan(error / signal, 0.01, @"within 20 dB of its source");
}

// The lossy half alone, decoded to the end: what every fallback must match.
- (NSData *)lossyHalf {
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd([self open:[self hybridNamed:@"reference.wv" beside:nil named:nil] interleaved:YES], pcm, NULL));
    return pcm;
}

// With its correction file beside it, a hybrid file decodes to its source
// bit for bit, in either layout, and states the source's facts, as a lossless
// file does. So bit-perfect output keeps its depth.
- (void)testAHybridFileWithItsCorrectionFileDecodesBitForBit {
    NSData *expected = VibeWavPackExpected(kLossless[0]);
    for (int interleaved = 0; interleaved < 2; interleaved++) {
        AudioFileHandle *handle = [self open:VibeWavPackFixture(@"hybrid.wv") interleaved:interleaved];
        XCTAssertEqualObjects(handle.correctionFileURL.lastPathComponent, @"hybrid.wvc");
        XCTAssertEqualObjects(handle.decoderName, @"libwavpack");
        const AudioStreamBasicDescription *file = handle.fileFormat.streamDescription;
        XCTAssertEqual(file->mFormatID, kAudioFormatLinearPCM);
        XCTAssertEqual(file->mBitsPerChannel, 16u);
        XCTAssertEqual(file->mSampleRate, 44100);
        XCTAssertEqual(handle.length, 8192);
        NSMutableData *pcm = [NSMutableData data];
        NSError *error = nil;
        XCTAssertTrue(VibeReadToEnd(handle, pcm, &error), @"%@", error);
        XCTAssertEqualObjects(pcm, expected, @"interleaved %d", interleaved);
    }
}

// A correction file that is missing, empty, unreadable, cut short, or
// another song's leaves the lossy half playing, with no error, exactly as the
// .wv alone plays.
- (void)testABadCorrectionFileFallsBackToTheLossyHalf {
    NSData *wvc = [NSData dataWithContentsOfURL:VibeWavPackFixture(@"hybrid.wvc")];
    NSData *lossy = [self lossyHalf];
    NSDictionary<NSString *, NSData *> *cases = @{
        @"empty": [NSData data],
        @"cut-short": [wvc subdataWithRange:NSMakeRange(0, wvc.length / 2)],
        @"header-only": [wvc subdataWithRange:NSMakeRange(0, 32)],
        @"another-song": [NSData dataWithContentsOfURL:VibeWavPackFixture(@"negated.wvc")],
        @"not-wavpack": [NSMutableData dataWithLength:wvc.length],
        @"unreadable": wvc,
    };
    for (NSString *name in cases) {
        NSString *wvName = [name stringByAppendingPathExtension:@"wv"];
        NSString *wvcName = [name stringByAppendingPathExtension:@"wvc"];
        NSURL *url = [self hybridNamed:wvName beside:cases[name] named:wvcName];
        NSString *wvcPath = [self.scratch URLByAppendingPathComponent:wvcName].path;
        if ([name isEqualToString:@"unreadable"]) {
            XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0} ofItemAtPath:wvcPath error:NULL]);
        }
        AudioFileHandle *handle = [self open:url interleaved:YES];
        XCTAssertNil(handle.correctionFileURL, @"%@", name);
        XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, (AudioFormatID)'wvpk', @"%@", name);
        XCTAssertEqual(handle.length, 8192, @"%@", name);
        NSMutableData *pcm = [NSMutableData data];
        NSError *error = nil;
        XCTAssertTrue(VibeReadToEnd(handle, pcm, &error), @"%@: %@", name, error);
        XCTAssertEqualObjects(pcm, lossy, @"%@", name);
        XCTAssertEqualObjects(VibeDecodeRange(handle, 4000, 300), [lossy subdataWithRange:NSMakeRange(4000 * 8, 300 * 8)],
                              @"%@: a seek", name);
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:wvcPath error:NULL];
    }
}

// `wv` and `wvc` fixtures copied into the scratch folder as `name`.wv and
// `name`.wvc.
- (NSURL *)pairNamed:(NSString *)name wv:(NSString *)wv wvc:(NSString *)wvc {
    NSURL *url = [self.scratch URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"wv"]];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:VibeWavPackFixture(wv) toURL:url error:NULL]);
    NSURL *correction = [self.scratch URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"wvc"]];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:VibeWavPackFixture(wvc) toURL:correction error:NULL]);
    return url;
}

// Another encode's .wvc of the same song pairs with the .wv block for block,
// by index, samples, and flags, and the song's last two blocks are digital
// silence, which decodes the same with either. Its first and middle blocks
// tell it apart, so it falls back to the lossy half. The right .wvc decodes
// bit for bit.
- (void)testAnotherEncodesCorrectionFileFallsBack {
    AudioFileHandle *wrong = [self open:[self pairNamed:@"wrong" wv:@"fade.wv" wvc:@"fade-b3.wvc"] interleaved:YES];
    XCTAssertNil(wrong.correctionFileURL);
    XCTAssertEqual(wrong.fileFormat.streamDescription->mFormatID, (AudioFormatID)'wvpk');
    AudioFileHandle *right = [self open:[self pairNamed:@"right" wv:@"fade.wv" wvc:@"fade.wvc"] interleaved:YES];
    XCTAssertNotNil(right.correctionFileURL);
    NSMutableData *expected = [VibeWavPackExpected(kLossless[0]) mutableCopy];
    const size_t frameBytes = 2 * sizeof(float);
    memset((uint8_t *)expected.mutableBytes + (8192 - 2048) * frameBytes, 0, 2048 * frameBytes);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(right, pcm, NULL));
    XCTAssertEqualObjects(pcm, expected);
}

// A .wvc cut short while it plays leaves blocks with no correction, which
// libwavpack would decode lossy under lossless facts. The read fails instead,
// and so does every later seek.
- (void)testACorrectionFileCutDuringThePlayFailsTheRead {
    NSURL *url = [self pairNamed:@"cut" wv:@"long.wv" wvc:@"long.wvc"];
    AudioFileHandle *handle = [self open:url interleaved:YES];
    XCTAssertNotNil(handle.correctionFileURL);
    XCTAssertNotNil(VibeDecodeRange(handle, 0, 4096), @"the head plays");
    NSFileHandle *wvc = [NSFileHandle fileHandleForWritingToURL:handle.correctionFileURL error:NULL];
    XCTAssertTrue([wvc truncateAtOffset:200 * 1024 error:NULL]);
    [wvc closeAndReturnError:NULL];
    NSMutableData *pcm = [NSMutableData data];
    NSError *error = nil;
    XCTAssertFalse(VibeReadToEnd(handle, pcm, &error), @"no lossy frames under lossless facts");
    XCTAssertNotNil(error);
    XCTAssertFalse([handle seekToFrame:100 error:NULL]);
}

// A .wvc emptied after the open: a seek into what the reads have not held
// fails, and so does the seek after it, whose restart would open without the
// .wvc and decode the lossy half under lossless facts.
- (void)testASeekOverAnEmptiedCorrectionFileFails {
    NSURL *url = [self pairNamed:@"emptied" wv:@"long.wv" wvc:@"long.wvc"];
    AudioFileHandle *handle = [self open:url interleaved:YES];
    XCTAssertNotNil(handle.correctionFileURL);
    XCTAssertNotNil(VibeDecodeRange(handle, 0, 4096), @"the head plays");
    XCTAssertTrue([[NSData data] writeToURL:handle.correctionFileURL atomically:NO]);
    XCTAssertFalse([handle seekToFrame:300000 error:NULL]);
    XCTAssertFalse([handle seekToFrame:100 error:NULL]);
}

// The correction file's name follows the .wv's: the same name, with wvc in
// the case of the .wv's extension first. The check an indexer asks finds the
// same file a play opens, and nothing for a file alone.
- (void)testTheCorrectionFileIsFoundByItsName {
    NSData *wvc = [NSData dataWithContentsOfURL:VibeWavPackFixture(@"hybrid.wvc")];
    NSURL *upper = [self hybridNamed:@"UPPER.WV" beside:wvc named:@"UPPER.WVC"];
    XCTAssertEqualObjects([AudioFileHandle correctionFileForWavPack:upper].lastPathComponent, @"UPPER.WVC");
    AudioFileHandle *handle = [self open:upper interleaved:YES];
    XCTAssertEqualObjects(handle.correctionFileURL.lastPathComponent, @"UPPER.WVC");
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, kAudioFormatLinearPCM);

    NSURL *mixed = [self hybridNamed:@"mixed.wv" beside:wvc named:@"mixed.WVC"];
    XCTAssertNotNil([AudioFileHandle correctionFileForWavPack:mixed]);
    XCTAssertEqual([self open:mixed interleaved:YES].fileFormat.streamDescription->mFormatID, kAudioFormatLinearPCM);

    NSURL *alone = [self hybridNamed:@"alone.wv" beside:nil named:nil];
    XCTAssertNil([AudioFileHandle correctionFileForWavPack:alone]);
    XCTAssertNil([AudioFileHandle correctionFileForWavPack:VibeWavPackFixture(@"s16.wv")]);
}

// A lossless file never looks for a correction file, nor states one.
- (void)testALosslessFileStatesNoCorrectionFile {
    NSURL *url = [self.scratch URLByAppendingPathComponent:@"lossless.wv"];
    XCTAssertTrue([[NSData dataWithContentsOfURL:VibeWavPackFixture(@"s16.wv")] writeToURL:url atomically:YES]);
    XCTAssertTrue([[NSData dataWithContentsOfURL:VibeWavPackFixture(@"hybrid.wvc")]
                   writeToURL:[self.scratch URLByAppendingPathComponent:@"lossless.wvc"] atomically:YES]);
    AudioFileHandle *handle = [self open:url interleaved:YES];
    XCTAssertNil(handle.correctionFileURL);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    XCTAssertEqualObjects(pcm, VibeWavPackExpected(kLossless[0]));
}

// The DSD fixtures: each .wv was packed from the .dsf of the same name, so
// both hold the same DSD. They cover both of a DSF's bit orders, mono, 5.1,
// the 48 kHz family, and DSD64 to DSD512.
static NSArray<NSString *> *VibeDSDFixtures(void) {
    return @[@"dsd", @"dsd-msb", @"dsd128-48k", @"dsd256", @"dsd512", @"dsd-surround"];
}

// DSD in WavPack goes through the handle's own converter, as a DSF's does, so
// the same DSD decodes to the same samples, bit for bit, in either layout. The
// facts are the DSF's: float PCM at 176.4 kHz, or 192 kHz in the 48 kHz
// family, a frame for each 16 DSD samples at DSD64, and the DSD rate.
// DSD256 and DSD512 play, since they no longer decode past 768 kHz.
- (void)testDSDDecodesAsItsDSFDoes {
    for (NSString *name in VibeDSDFixtures()) {
        for (NSNumber *interleaved in @[@YES, @NO]) {
            NSURL *wvURL = VibeWavPackFixture([name stringByAppendingPathExtension:@"wv"]);
            AudioFileHandle *wv = [self open:wvURL interleaved:interleaved.boolValue];
            AudioFileHandle *dsf = [self open:VibeWavPackFixture([name stringByAppendingPathExtension:@"dsf"])
                                  interleaved:interleaved.boolValue];
            if (!wv || !dsf) continue;
            XCTAssertEqualObjects(wv.decoderName, @"libwavpack", @"%@", name);
            XCTAssertEqualObjects(dsf.decoderName, @"dsd", @"%@", name);
            XCTAssertGreaterThan(wv.dsdSampleRate, 0, @"%@", name);
            XCTAssertEqual(wv.dsdSampleRate, dsf.dsdSampleRate, @"%@", name);
            XCTAssertEqual(wv.length, dsf.length, @"%@", name);
            XCTAssertEqual(wv.fileFormat.sampleRate, dsf.fileFormat.sampleRate, @"%@", name);
            XCTAssertEqual(wv.fileFormat.channelCount, dsf.fileFormat.channelCount, @"%@", name);
            XCTAssertEqual(wv.fileFormat.streamDescription->mFormatID, kAudioFormatLinearPCM, @"%@", name);
            XCTAssertEqual(wv.fileFormat.commonFormat, AVAudioPCMFormatFloat32, @"%@", name);
            XCTAssertEqual(wv.fileFormat.streamDescription->mBitsPerChannel, 32u, @"%@", name);
            XCTAssertEqualObjects(wv.processingFormat, dsf.processingFormat, @"%@", name);
            NSMutableData *fromWV = [NSMutableData data], *fromDSF = [NSMutableData data];
            XCTAssertTrue(VibeReadToEnd(wv, fromWV, NULL), @"%@", name);
            XCTAssertTrue(VibeReadToEnd(dsf, fromDSF, NULL), @"%@", name);
            XCTAssertEqual(fromWV.length, (NSUInteger)wv.length * wv.processingFormat.channelCount * sizeof(float), @"%@", name);
            XCTAssertTrue([fromWV isEqualToData:fromDSF], @"%@, interleaved %@", name, interleaved);
        }
    }
    AudioFileHandle *dsd64 = [self open:VibeWavPackFixture(@"dsd.wv") interleaved:YES];
    XCTAssertEqual(dsd64.fileFormat.sampleRate, 176400);
    XCTAssertEqual(dsd64.dsdSampleRate, 2822400);
    XCTAssertEqual(dsd64.length, 141120 / 16);
    AudioFileHandle *dsd512 = [self open:VibeWavPackFixture(@"dsd512.wv") interleaved:YES];
    XCTAssertEqual(dsd512.fileFormat.sampleRate, 176400);
    XCTAssertEqual(dsd512.dsdSampleRate, 22579200);
    AudioFileHandle *family48 = [self open:VibeWavPackFixture(@"dsd128-48k.wv") interleaved:YES];
    XCTAssertEqual(family48.fileFormat.sampleRate, 192000);
    XCTAssertEqual(family48.fileFormat.channelCount, 1u);
}

// A seek primes the converter as a DSF's does, so a seek's output equals a
// read's from the start, sample for sample, at every frame, the first ones
// included, and across libwavpack's blocks both ways.
- (void)testADSDSeekEqualsAReadFromTheStart {
    for (NSString *name in @[@"dsd.wv", @"dsd512.wv", @"dsd-surround.wv"]) {
        AudioFileHandle *handle = [self open:VibeWavPackFixture(name) interleaved:NO];
        NSMutableData *whole = [NSMutableData data];
        XCTAssertTrue(VibeReadToEnd(handle, whole, NULL), @"%@", name);
        AVAudioFramePosition length = handle.length;
        size_t frameBytes = handle.processingFormat.channelCount * sizeof(float);
        for (NSNumber *target in @[@(length - 100), @0, @1, @5, @26, @27, @53, @511, @512, @(length / 2), @3,
                                   @(length - 1), @700]) {
            AVAudioFramePosition at = target.longLongValue;
            NSData *read = VibeDecodeRange(handle, at, 300);
            NSUInteger count = MIN(300 * frameBytes, whole.length - (NSUInteger)at * frameBytes);
            XCTAssertEqualObjects(read, [whole subdataWithRange:NSMakeRange((NSUInteger)at * frameBytes, count)],
                                  @"%@ at %lld", name, at);
            XCTAssertEqual(handle.framePosition, at + (AVAudioFramePosition)(read.length / frameBytes), @"%@ at %lld", name, at);
        }
        XCTAssertTrue([handle seekToFrame:length + 10 error:NULL], @"%@", name);
        XCTAssertEqual(handle.framePosition, length, @"%@", name);
        XCTAssertEqual(VibeDecodeRange(handle, length, 64).length, 0u, @"%@", name);
    }
}

// A file whose first block never stated its length, as an encoder writing to
// a pipe leaves it, takes it from its last block, and decodes as the file
// that stated it.
- (void)testAFileThatNeverStatedItsLengthFindsIt {
    AudioFileHandle *handle = [self open:VibeWavPackFixture(@"unsized.wv") interleaved:YES];
    XCTAssertEqual(handle.length, 8192);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    XCTAssertEqualObjects(pcm, VibeWavPackExpected(kLossless[0]));
}

#pragma mark - Damage

// A header whose shift leaves no bits in the sample would state PCM of 0 bits.
// It is refused.
- (void)testAHeaderOfNoBitsIsRefused {
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:VibeWavPackFixture(@"s16.wv")] mutableCopy];
    uint8_t *b = bytes.mutableBytes;
    // The flags' shift, bits 13 to 17: 16 of a 2-byte sample's 16 bits.
    uint32_t flags = (OSReadLittleInt32(b, 24) & ~(0x1Fu << 13)) | (16u << 13);
    OSWriteLittleInt32(b, 24, flags);
    VibeWavPackResum(b, 8 + OSReadLittleInt32(b, 4));
    NSURL *url = [self.scratch URLByAppendingPathComponent:@"no-bits.wv"];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:NULL]);
}

// A file cut short opens on its stated length, and decodes its whole blocks
// up to the cut. Cut inside its first block, no decoder takes it.
- (void)testACutFileDecodesUpToTheCut {
    NSData *bytes = [NSData dataWithContentsOfURL:VibeWavPackFixture(@"s16.wv")];
    NSData *expected = VibeWavPackExpected(kLossless[0]);
    NSURL *half = [self.scratch URLByAppendingPathComponent:@"half.wv"];
    XCTAssertTrue([[bytes subdataWithRange:NSMakeRange(0, bytes.length / 2)] writeToURL:half atomically:YES]);
    AudioFileHandle *handle = [self open:half interleaved:YES];
    XCTAssertEqual(handle.length, 8192);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    XCTAssertGreaterThan(pcm.length, 0u);
    XCTAssertLessThan(pcm.length, expected.length);
    XCTAssertEqualObjects(pcm, [expected subdataWithRange:NSMakeRange(0, pcm.length)]);
    XCTAssertTrue([handle seekToFrame:100 error:NULL], @"a seek inside what is there");

    NSURL *header = [self.scratch URLByAppendingPathComponent:@"header.wv"];
    XCTAssertTrue([[bytes subdataWithRange:NSMakeRange(0, 40)] writeToURL:header atomically:YES]);
    XCTAssertNil([[AudioFileHandle alloc] initForReading:header error:NULL]);
}

// A block whose checksum fails decodes as silence, and the decode goes on
// from the next block.
- (void)testADamagedBlockIsSilence {
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:VibeWavPackFixture(@"s16.wv")] mutableCopy];
    // The third block's audio: a byte well inside it, past its header and metadata.
    uint8_t *b = bytes.mutableBytes;
    NSUInteger at = 0;
    for (int block = 0; block < 2; block++) {
        at += 8 + OSReadLittleInt32(b, at + 4);
    }
    XCTAssertEqual(memcmp(b + at, "wvpk", 4), 0);
    b[at + 8 + OSReadLittleInt32(b, at + 4) / 2] ^= 0x5A;
    NSURL *url = [self.scratch URLByAppendingPathComponent:@"damaged.wv"];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    AudioFileHandle *handle = [self open:url interleaved:YES];
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    NSData *expected = VibeWavPackExpected(kLossless[0]);
    XCTAssertEqual(pcm.length, expected.length);
    const size_t frameBytes = 2 * sizeof(float);
    XCTAssertEqualObjects([pcm subdataWithRange:NSMakeRange(0, 2048 * frameBytes)],
                          [expected subdataWithRange:NSMakeRange(0, 2048 * frameBytes)]);
    NSData *silence = [NSMutableData dataWithLength:1024 * frameBytes];
    XCTAssertEqualObjects([pcm subdataWithRange:NSMakeRange(2048 * frameBytes, 1024 * frameBytes)], silence);
    XCTAssertEqualObjects([pcm subdataWithRange:NSMakeRange(3072 * frameBytes, pcm.length - 3072 * frameBytes)],
                          [expected subdataWithRange:NSMakeRange(3072 * frameBytes, pcm.length - 3072 * frameBytes)]);
}

// A source DSF whose sample count is not a multiple of 8: WavPack's encoder
// drops the last byte's few samples, with a warning, where the DSF keeps them
// and reads its padding as silence. So the two have the same length, and
// only the last frames, whose filters reach that byte, differ, by those
// samples' share alone.
- (void)testADSFsLastPartByteIsDroppedInWavPack {
    NSData *wv = VibeDecodeFile(VibeWavPackFixture(@"dsd-odd.wv"));
    NSData *dsf = VibeDecodeFile(VibeWavPackFixture(@"dsd-odd.dsf"));
    XCTAssertEqual(wv.length, dsf.length);
    XCTAssertEqual(wv.length, 141123 / 16 * 2 * sizeof(float));
    NSUInteger same = wv.length - 27 * 2 * sizeof(float);
    XCTAssertEqualObjects([wv subdataWithRange:NSMakeRange(0, same)], [dsf subdataWithRange:NSMakeRange(0, same)]);
    const float *a = wv.bytes, *b = dsf.bytes;
    float most = 0;
    for (NSUInteger i = same / sizeof(float); i < wv.length / sizeof(float); i++) {
        most = MAX(most, fabsf(a[i] - b[i]));
    }
    XCTAssertGreaterThan(most, 0);
    XCTAssertLessThan(most, 0.05f); // 0.023, -33 dBFS, for the fixture's 3 samples
}

// DSD is told by its blocks' DSD flag, as libwavpack decodes it, not by the
// source's bit order in the config, which damage can clear. Without it, the
// file still plays as DSD, the same samples.
- (void)testDSDWithoutItsBitOrderStillPlaysAsDSD {
    AudioFileHandle *handle = [self open:VibeWavPackFixture(@"dsd-no-qmode.wv") interleaved:YES];
    XCTAssertEqual(handle.dsdSampleRate, 2822400);
    XCTAssertEqualObjects(VibeDecodeFile(VibeWavPackFixture(@"dsd-no-qmode.wv")), VibeDecodeFile(VibeWavPackFixture(@"dsd.wv")));
}

// WavPack's encoder has no hybrid DSD, so a DSD file that says hybrid is
// damaged, and refused (recommended, open to change). It never looks for a
// correction file, even one beside it.
- (void)testAHybridDSDFileIsRefused {
    NSURL *url = [self.scratch URLByAppendingPathComponent:@"dsd-hybrid.wv"];
    XCTAssertTrue([[NSData dataWithContentsOfURL:VibeWavPackFixture(@"dsd-hybrid.wv")] writeToURL:url atomically:YES]);
    XCTAssertTrue([[NSData dataWithContentsOfURL:VibeWavPackFixture(@"hybrid.wvc")]
                   writeToURL:[self.scratch URLByAppendingPathComponent:@"dsd-hybrid.wvc"] atomically:YES]);
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:NULL]);
}

// A DSD file cut short opens on its stated length, as a PCM one does, and
// reads up to its last whole block, with no error. Only the frames whose
// filters reach past the cut differ from the whole file's, since the cut's
// bytes read as silence. A seek inside what is there lands as in the whole file.
- (void)testACutDSDFileDecodesUpToTheCut {
    NSData *bytes = [NSData dataWithContentsOfURL:VibeWavPackFixture(@"dsd.wv")];
    NSMutableData *whole = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd([self open:VibeWavPackFixture(@"dsd.wv") interleaved:YES], whole, NULL));
    NSURL *half = [self.scratch URLByAppendingPathComponent:@"half.wv"];
    XCTAssertTrue([[bytes subdataWithRange:NSMakeRange(0, bytes.length / 2)] writeToURL:half atomically:YES]);
    AudioFileHandle *handle = [self open:half interleaved:YES];
    XCTAssertEqual(handle.length, 141120 / 16);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    const size_t frameBytes = 2 * sizeof(float);
    XCTAssertGreaterThan(pcm.length, 64 * frameBytes);
    XCTAssertLessThan(pcm.length, whole.length);
    NSUInteger same = pcm.length - 27 * frameBytes;
    XCTAssertEqualObjects([pcm subdataWithRange:NSMakeRange(0, same)], [whole subdataWithRange:NSMakeRange(0, same)]);
    XCTAssertEqualObjects(VibeDecodeRange(handle, 100, 200), [whole subdataWithRange:NSMakeRange(100 * frameBytes, 200 * frameBytes)],
                          @"a seek inside what is there");
}

#pragma mark - The lists

// An AIFF-C named .aifc or .afc plays through dr_wav, as one named .aif does.
- (void)testAIFFCPlaysByEitherName {
    AVAudioPCMBuffer *buffer = VibeToneBuffer(4096, 44100, 2, AVAudioPCMFormatInt16);
    NSData *reference = nil;
    NSError *error = nil;
    NSURL *written = VibeWriteFixture([self.scratch URLByAppendingPathComponent:@"written.aif"], buffer, &error);
    XCTAssertNotNil(written, @"%@", error);
    for (NSString *name in @[@"song.aif", @"song.aifc", @"song.afc"]) {
        NSURL *url = [self.scratch URLByAppendingPathComponent:name];
        XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:written toURL:url error:&error], @"%@: %@", name, error);
        NSData *head = [[NSData dataWithContentsOfURL:url] subdataWithRange:NSMakeRange(8, 4)];
        XCTAssertEqualObjects(head, [@"AIFC" dataUsingEncoding:NSASCIIStringEncoding], @"%@", name);
        AudioFileHandle *handle = [self open:url interleaved:YES];
        XCTAssertEqualObjects(handle.decoderName, @"dr_wav", @"%@", name);
        XCTAssertEqual(handle.length, 4096, @"%@", name);
        NSMutableData *pcm = [NSMutableData data];
        XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL), @"%@", name);
        reference = reference ?: pcm;
        XCTAssertEqualObjects(pcm, reference, @"%@", name);
    }
}

@end
