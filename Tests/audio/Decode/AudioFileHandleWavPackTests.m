//
// WavPack through AudioFileHandle, by libwavpack: the facts each kind of file
// states, a lossless decode bit for bit, seeks, a hybrid file's lossy half,
// DSD as PCM, a file that never stated its length, and cut files. Also the
// AIFF-C spellings, which dr_wav plays.
//
// The fixtures are in WavPack/ beside this file. make-fixtures.sh made them
// from make-sources.py's integer signals, which VibeWavPackSample repeats.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"
#import "AudioFileFixtures.h"
#import "PlayableExtensions.h"
#import "TailWindowMath.h"

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
} VibeWavPackFixture;

static const VibeWavPackFixture kLossless[] = {
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
static NSData *VibeWavPackExpected(VibeWavPackFixture fixture) {
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

static NSURL *VibeWavPackURL(NSString *name) {
    return [NSURL fileURLWithPath:[[@__FILE__.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"WavPack"]
                                   stringByAppendingPathComponent:name]];
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
        VibeWavPackFixture fixture = kLossless[i];
        NSString *name = @(fixture.name);
        NSData *expected = VibeWavPackExpected(fixture);
        for (int interleaved = 0; interleaved < 2; interleaved++) {
            AudioFileHandle *handle = [self open:VibeWavPackURL(name) interleaved:interleaved];
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
    AudioFileHandle *surround = [self open:VibeWavPackURL(@"surround.wv") interleaved:NO];
    const AudioChannelLayout *layout = surround.fileFormat.channelLayout.layout;
    XCTAssertTrue(layout != NULL);
    XCTAssertEqual(layout->mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap);
    XCTAssertEqual(layout->mChannelBitmap, 0x3Fu);
    XCTAssertNil([self open:VibeWavPackURL(@"s16.wv") interleaved:NO].fileFormat.channelLayout);
}

#pragma mark - Seeking

// A seek lands on the frame asked for, inside a block, at a block's start,
// and across many blocks, both ways. Past the end, it lands at the end, and
// reads nothing. TRAP: libwavpack's DSD decimator estimates a file's first 9
// frames from the frames its first decode holds, so after a seek into a DSD
// file's first 16 frames they differ from a read from the start. From frame
// 16 on, it seeks exactly.
- (void)testSeeksLandExactly {
    for (NSString *name in @[@"s16.wv", @"surround.wv", @"dsd.wv"]) {
        AudioFileHandle *handle = [self open:VibeWavPackURL(name) interleaved:YES];
        NSMutableData *whole = [NSMutableData data];
        XCTAssertTrue(VibeReadToEnd(handle, whole, NULL), @"%@", name);
        AVAudioFramePosition length = handle.length;
        size_t frameBytes = handle.processingFormat.channelCount * sizeof(float);
        XCTAssertEqual(whole.length, (NSUInteger)length * frameBytes, @"%@", name);
        for (NSNumber *target in @[@(length - 300), @0, @1, @1023, @1024, @3000, @17, @(length / 2), @5]) {
            AVAudioFramePosition at = target.longLongValue;
            if ([name isEqualToString:@"dsd.wv"] && at > 0 && at < 16) continue;
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

// A hybrid file plays its lossy half alone, even with its correction file
// beside it. It states WavPack's own format and no depth, so bit-perfect
// output keeps none, and it sounds like its source.
- (void)testAHybridFilePlaysItsLossyHalf {
    AudioFileHandle *handle = [self open:VibeWavPackURL(@"hybrid.wv") interleaved:YES];
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

// DSD decodes to 24-bit PCM at an eighth of its rate: DSD64 at 352.8 kHz.
// The source is a 1 kHz sine at half scale.
- (void)testDSDPlaysAsPCM {
    AudioFileHandle *handle = [self open:VibeWavPackURL(@"dsd.wv") interleaved:NO];
    XCTAssertEqual(handle.fileFormat.sampleRate, 352800);
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, (AudioFormatID)'wvpk');
    XCTAssertEqual(handle.fileFormat.channelCount, 2u);
    XCTAssertEqual(handle.length, 2822400 / 20 / 8);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    const float *samples = pcm.bytes;
    float peak = 0;
    for (NSUInteger i = pcm.length / sizeof(float) / 4; i < pcm.length / sizeof(float); i++) {
        peak = MAX(peak, fabsf(samples[i]));
    }
    XCTAssertGreaterThan(peak, 0.35f);
    XCTAssertLessThan(peak, 0.65f);
}

// A file whose first block never stated its length, as an encoder writing to
// a pipe leaves it, takes it from its last block, and decodes as the file
// that stated it.
- (void)testAFileThatNeverStatedItsLengthFindsIt {
    AudioFileHandle *handle = [self open:VibeWavPackURL(@"unsized.wv") interleaved:YES];
    XCTAssertEqual(handle.length, 8192);
    NSMutableData *pcm = [NSMutableData data];
    XCTAssertTrue(VibeReadToEnd(handle, pcm, NULL));
    XCTAssertEqualObjects(pcm, VibeWavPackExpected(kLossless[0]));
}

#pragma mark - Damage

// A file cut short opens on its stated length, and decodes its whole blocks
// up to the cut. Cut inside its first block, no decoder takes it.
- (void)testACutFileDecodesUpToTheCut {
    NSData *bytes = [NSData dataWithContentsOfURL:VibeWavPackURL(@"s16.wv")];
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
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:VibeWavPackURL(@"s16.wv")] mutableCopy];
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

#pragma mark - The lists

// .wv and the AIFF-C spellings are playable. A .wvc is not: it is half of a
// hybrid file, and plays only beside it.
- (void)testTheExtensionsArePlayable {
    for (NSString *extension in @[@"wv", @"aifc", @"afc"]) {
        XCTAssertTrue([PlayableExtensions.lookup containsObject:extension], @"%@", extension);
        XCTAssertTrue([PlayableExtensions.tagParsed containsObject:extension], @"%@", extension);
    }
    XCTAssertFalse([PlayableExtensions.lookup containsObject:@"wvc"]);
}

// An AIFF-C named .aifc or .afc plays through dr_wav, as one named .aif does.
- (void)testAIFFCPlaysByEitherName {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100 channels:2
                                                            interleaved:YES];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
    buffer.frameLength = 4096;
    for (AVAudioFrameCount f = 0; f < buffer.frameLength * 2; f++) {
        buffer.int16ChannelData[0][f] = (int16_t)VibeWavPackSample(f, f / 2, f % 2, 16);
    }
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

// A streamed .wv that never stated its length reads its last 1 MB at open.
// Its window holds that. The AIFF-C spellings are chunked, as AIFF is.
- (void)testTheTailWindowCoversTheOpen {
    const uint64_t MB = 1024 * 1024;
    XCTAssertGreaterThanOrEqual(VibeAudioFileTailWindowBytes(@"wv", 40 * MB), 1 * MB);
    XCTAssertGreaterThanOrEqual(VibeAudioFileTailWindowBytes(@"WV", 40 * MB), 1 * MB);
    for (NSString *extension in @[@"aifc", @"afc"]) {
        XCTAssertEqual(VibeAudioFileTailWindowBytes(extension, 32 * MB), VibeAudioFileTailWindowBytes(@"aiff", 32 * MB));
    }
}

@end
