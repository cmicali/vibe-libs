//
//  AudioFileHandle+WavPack.m
//  vibe-libs
//
//  libwavpack's decode of a WavPack file: the open through a reader over the
//  handle's stream reads, a hybrid file's correction file, the facts, the
//  reads, the seek, the restart after an interrupted read, and the close.
//  The sniff that sends a file here is AudioFileHandle+Stream.m's. The ivars
//  are AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"
#import "CloudFileMaterializer.h"

#import <Accelerate/Accelerate.h>


// The samples one unpack fills, across every channel: 64 KB. A file of many
// channels unpacks fewer frames at a time.
static const uint32_t kVibeWavPackChunkSamples = 16384;

// TRAP: OPEN_NORMALIZE scales a float file's samples to ±1 when its encoder
// stored them at another exponent. OPEN_DSD_AS_PCM decimates DSD to 24-bit
// PCM at an eighth of its rate. With neither, DSD would decode as 1-bit
// bytes. OPEN_WVC only names the file-name open's search: a reader open
// takes the correction file when it is given one.
static const int kVibeWavPackOpenFlags = OPEN_NORMALIZE | OPEN_DSD_AS_PCM;

// The spellings of a hybrid file's correction file, in the order they are
// tried: the same folder and name, with the .wv's extension and a c in its
// case (wv to wvc, WV to WVC), then wvc, then WVC. A case-sensitive volume
// needs all three. A case-insensitive one finds the file at the first.
NSArray<NSURL *> *VibeWavPackCorrectionSpellings(NSURL *url) {
    NSString *extension = url.pathExtension;
    unichar last = extension.length ? [extension characterAtIndex:extension.length - 1] : 'v';
    NSString *matched = [extension stringByAppendingString:[NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:last]
                                                           ? @"C" : @"c"];
    NSURL *base = url.URLByDeletingPathExtension;
    NSMutableArray<NSURL *> *spellings = [NSMutableArray array];
    for (NSString *spelling in [NSOrderedSet orderedSetWithArray:@[matched, @"wvc", @"WVC"]]) {
        [spellings addObject:[base URLByAppendingPathExtension:spelling]];
    }
    return spellings;
}

@implementation AudioFileHandle (WavPack)

#pragma mark - The reader

// Inside the implementation, so they may read the handle's ivars.
// libwavpack reads through these, at the stream decoders' cursor, so its
// reads wait for a stream's bytes and fail as dr_flac's do (VibeStreamRead).

static int32_t VibeWavPackRead(void *user, void *data, int32_t count) {
    return count > 0 ? (int32_t)VibeStreamRead(user, data, (size_t)count) : 0;
}

// Not vorbisfile's tell, which answers a long.
static int64_t VibeWavPackPosition(void *user) {
    return ((__bridge AudioFileHandle *)user)->_streamCursor;
}

static int VibeWavPackMoveTo(void *user, int64_t position) {
    return VibeStreamSeekFrom(user, position, SEEK_SET);
}

// The library pushes back only the byte it has just read.
static int VibeWavPackPushBack(void *user, int c) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    if (handle->_streamCursor == 0) {
        return EOF;
    }
    handle->_streamCursor--;
    return c;
}

static int64_t VibeWavPackLength(void *user) {
    return ((__bridge AudioFileHandle *)user)->_size;
}

static int VibeWavPackCanSeek(void *user) {
    return 1;
}

static WavpackStreamReader64 kVibeWavPackReader = {
    .read_bytes = VibeWavPackRead, .get_pos = VibeWavPackPosition, .set_pos_abs = VibeWavPackMoveTo,
    .set_pos_rel = VibeStreamSeekFrom, .push_back_byte = VibeWavPackPushBack, .get_length = VibeWavPackLength,
    .can_seek = VibeWavPackCanSeek,
};

// Over the correction file too, when the open found one. Both cursors start
// over, and the correction file's interruption is cleared with this handle's
// (the core's seek).
- (WavpackContext *)newWavPackContext {
    _streamCursor = 0;
    AudioFileHandle *correction = _wavpackCorrection;
    if (correction) {
        correction->_streamCursor = 0;
        if ([AudioFileHandle isInterruption:correction->_waitError]) {
            correction->_waitError = nil;
        }
    }
    char message[80];
    return WavpackOpenFileInputEx64(&kVibeWavPackReader, (__bridge void *)self, (__bridge void *)correction, message,
                                    kVibeWavPackOpenFlags, 0);
}

// A correction file's lost or failed read is this file's: the read or seek it
// happened in answers NO with its error, and the context is stale, so the
// frames libwavpack made without the correction never play as lossless.
- (void)takeCorrectionFault {
    AudioFileHandle *correction = _wavpackCorrection;
    if (!correction || !(correction->_waitError || correction->_streamReadFailed)) {
        return;
    }
    if (correction->_waitError && !_waitError) {
        _waitError = correction->_waitError;
    }
    _streamReadFailed = _streamReadFailed || correction->_streamReadFailed;
    _wavpackStale = YES;
}

#pragma mark - The correction file

// YES when the context decodes the file's last block lossless with the
// correction file: the correction holds that block, and the block's checksum,
// which is the lossless decode's, passes. So a correction file cut short, or
// another song's, is caught. Then it seeks back to the start. One block's
// decode, and the reads that find the last block in both files.
static BOOL VibeWavPackCorrectionHolds(WavpackContext *context, int32_t *frame) {
    int64_t total = WavpackGetNumSamples64(context);
    return (WavpackGetMode(context) & MODE_WVC) && total > 0 && WavpackSeekSample64(context, total - 1)
            && WavpackUnpackSamples(context, frame, 1) == 1 && WavpackGetNumErrors(context) == 0
            && WavpackSeekSample64(context, 0);
}

// A hybrid file plays lossless when its correction file sits beside it, opens,
// and holds (VibeWavPackCorrectionHolds). Otherwise it plays its lossy half,
// as it did, with no error. A file still downloading never looks for one, nor
// takes one still downloading: both play lossy until both are on disk. An
// interruption is the open's, not a fallback.
- (void)openWavPackCorrection {
    int mode = WavpackGetMode(_wavpack);
    if (!(mode & MODE_HYBRID) || (mode & MODE_LOSSLESS) || _availability.partURL) {
        return;
    }
    for (NSURL *spelling in VibeWavPackCorrectionSpellings(_url)) {
        if ([CloudFileMaterializer availabilityForURL:spelling]) {
            return;
        }
        NSError *error = nil;
        AudioFileHandle *correction = [[AudioFileHandle alloc] initBytesForReading:spelling interrupted:_openInterrupted
                                                                             error:&error];
        if ([AudioFileHandle isInterruption:error]) {
            _waitError = error;
            return;
        }
        if (correction) {
            [self tryWavPackCorrection:correction];
            return;
        }
    }
}

// The lossless context replaces the lossy one when the correction holds.
// Otherwise the lossy one is opened again, since the try moved the cursor it
// reads at.
- (void)tryWavPackCorrection:(AudioFileHandle *)correction {
    uint32_t channels = (uint32_t)MAX(1, WavpackGetNumChannels(_wavpack));
    int32_t *frame = calloc(channels, sizeof(int32_t));
    _wavpackCorrection = correction;
    WavpackContext *lossless = frame ? [self newWavPackContext] : NULL;
    BOOL holds = lossless && VibeWavPackCorrectionHolds(lossless, frame);
    free(frame);
    if ([AudioFileHandle isInterruption:correction->_waitError] && !_waitError) {
        _waitError = correction->_waitError;
    }
    if (holds && !_waitError) {
        WavpackCloseFile(_wavpack);
        _wavpack = lossless;
        return;
    }
    if (lossless) {
        WavpackCloseFile(lossless);
    }
    _wavpackCorrection = nil;
    if (!_waitError) {
        WavpackContext *lossy = [self newWavPackContext];
        WavpackCloseFile(_wavpack);
        _wavpack = lossy;
    }
}

#pragma mark - The open

// libwavpack answers the facts. A lossless file states them as the WAV it was
// packed from: PCM of its width, high-aligned in its bytes, float or signed
// integer, and an 8-bit sample unsigned unless its source's was signed. So
// bit-perfect output keeps its depth. A hybrid file with its correction file
// is lossless. One without it, and DSD, state WavPack's own format ID and no
// depth, as a lossy codec does. A layout follows from the channel mask, as a
// WAV's does. The length is the first block's count, or the last block's end
// for a file that never stated it. A file whose length cannot be found is
// refused.
- (BOOL)openWavPackInterleaved:(BOOL)interleaved {
    _wavpack = [self newWavPackContext];
    if (_wavpack) {
        [self openWavPackCorrection];
    }
    if (!_wavpack || _waitError) {
        [self closeWavPack];
        return NO;
    }
    int mode = WavpackGetMode(_wavpack), qualify = WavpackGetQualifyMode(_wavpack);
    UInt32 channels = (UInt32)WavpackGetNumChannels(_wavpack), rate = WavpackGetSampleRate(_wavpack);
    UInt32 bits = (UInt32)WavpackGetBitsPerSample(_wavpack), bytes = (UInt32)WavpackGetBytesPerSample(_wavpack);
    int64_t total = WavpackGetNumSamples64(_wavpack);
    BOOL isFloat = (mode & MODE_FLOAT) != 0, dsd = (qualify & QMODE_DSD_AUDIO) != 0;
    // libwavpack gives 1 to 4 bytes and a channel or more, and the keep
    // checks the rate and channels. A damaged header can state 0 bits.
    // DSD decodes to an eighth of its DSD rate, so DSD256 and up is refused.
    if (rate > kVibeDecodeMaxRate || bits < 1 || bits > bytes * 8
            || !(_wavpackSamples = malloc(kVibeWavPackChunkSamples * sizeof(int32_t)))) {
        [self closeStreamDecoder];
        return NO;
    }
    _wavpackScale = isFloat ? 0 : 1.0f / (float)(1u << (bytes * 8 - 1));
    AudioStreamBasicDescription description = {.mSampleRate = rate, .mChannelsPerFrame = channels};
    if ((mode & MODE_LOSSLESS) && !dsd) {
        VibeDescribePCM(&description, bits, bytes, isFloat, !isFloat && (bytes > 1 || (qualify & QMODE_SIGNED_BYTES)), NO);
    } else {
        description.mFormatID = kVibeWavPackFormat;
    }
    AVAudioChannelLayout *layout = VibeMaskLayout(WavpackGetChannelMask(_wavpack), channels);
    return [self keepStreamDecoderWithLength:total > 0 ? (UInt64)total : 0 description:description
                                      layout:layout interleaved:interleaved];
}

// The context before the correction file's handle it reads. That handle
// closes its file as any handle does: on the close queue, for an open with an
// `interrupted` block (this piece's AGENTS.md, "Closing a file").
- (void)closeWavPack {
    if (_wavpack) {
        WavpackCloseFile(_wavpack);
        _wavpack = NULL;
    }
    _wavpackCorrection = nil;
    free(_wavpackSamples);
    _wavpackSamples = NULL;
}

// TRAP: libwavpack keeps the block it was reading when a read was lost, cut
// short, and a seek inside that block decodes on from it. A failed seek has
// freed its blocks. So after either, or a decode that ended short, the
// context is stale (_wavpackStale), and the next seek swaps in a fresh one,
// opened as the first was, over the correction file too. One that fails to
// open keeps the old, still stale, and that seek fails.
- (BOOL)restartWavPack {
    WavpackContext *fresh = [self newWavPackContext];
    [self takeCorrectionFault];
    if (!fresh) {
        return NO;
    }
    WavpackCloseFile(_wavpack);
    _wavpack = fresh;
    _wavpackStale = NO;
    return YES;
}

#pragma mark - Seeking and reading

// A target at or past the end lands there without the library, which refuses
// it, and without a restart, so a stale unsized file reads no tail again.
// Reads there return nothing. A DSD file's seek decodes the 16 samples before
// the target, so the decimation lands sample-exact.
- (BOOL)seekWavPackToFrame:(SInt64)frame {
    if (frame >= _length) {
        _wavpackPosition = _length;
        return YES;
    }
    if (_wavpackStale && ![self restartWavPack]) {
        return NO;
    }
    BOOL landed = WavpackSeekSample64(_wavpack, frame);
    [self takeCorrectionFault];
    if (landed && !_wavpackStale) {
        _wavpackPosition = frame;
        return YES;
    }
    _wavpackStale = YES;
    return NO;
}

// libwavpack unpacks interleaved 32-bit samples, right-aligned in the file's
// bytes, or float bits. An integer is scaled to ±1 as dr_wav scales a WAV's:
// the scale is a power of two, so rounding to float first changes nothing,
// and the two decode one file's samples to the same floats. A damaged block
// decodes as silence, and the decode goes on from the next. A cut file ends
// at its last whole block.
- (AVAudioFrameCount)readWavPackInto:(float *const *)planes frameCount:(AVAudioFrameCount)wanted {
    UInt32 channels = _processingFormat.channelCount;
    BOOL interleaved = _processingFormat.isInterleaved;
    uint32_t chunk = MAX(1u, kVibeWavPackChunkSamples / channels);
    AVAudioFrameCount got = 0;
    while (got < wanted && !_wavpackStale) {
        uint32_t frames = WavpackUnpackSamples(_wavpack, _wavpackSamples, MIN(chunk, wanted - got));
        [self takeCorrectionFault];
        if (_wavpackStale) {
            break;
        }
        if (frames == 0) {
            // TRAP: an unpack that stops short of the length is the decode's
            // end. libwavpack would go on at the next block that follows on,
            // so damage that reorders blocks read frames after the end.
            _wavpackStale = YES;
            break;
        }
        if (interleaved) {
            float *to = planes[0] + (size_t)got * channels;
            vDSP_Length count = (vDSP_Length)frames * channels;
            if (_wavpackScale == 0) {
                memcpy(to, _wavpackSamples, count * sizeof(float));
            } else {
                vDSP_vflt32(_wavpackSamples, 1, to, 1, count);
                vDSP_vsmul(to, 1, &_wavpackScale, to, 1, count);
            }
        } else {
            for (UInt32 c = 0; c < channels; c++) {
                float *to = planes[c] + got;
                if (_wavpackScale == 0) {
                    static const float one = 1; // a strided copy
                    vDSP_vsmul((const float *)_wavpackSamples + c, channels, &one, to, 1, frames);
                } else {
                    vDSP_vflt32(_wavpackSamples + c, channels, to, 1, frames);
                    vDSP_vsmul(to, 1, &_wavpackScale, to, 1, frames);
                }
            }
        }
        got += frames;
    }
    _wavpackPosition += got;
    return got;
}

@end
