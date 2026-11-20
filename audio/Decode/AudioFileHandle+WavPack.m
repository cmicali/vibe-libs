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
#import "PlayableExtensions.h"

#import <Accelerate/Accelerate.h>

#include <libkern/OSByteOrder.h>
#include <sys/stat.h>


// The samples one unpack fills, across every channel: 64 KB. A file of many
// channels unpacks fewer frames at a time.
static const uint32_t kVibeWavPackChunkSamples = 16384;

// TRAP: OPEN_NORMALIZE scales a float file's samples to ±1 when its encoder
// stored them at another exponent. OPEN_DSD_AS_PCM decimates DSD to 24-bit
// PCM at an eighth of its rate. With neither, DSD would decode as 1-bit
// bytes. OPEN_WVC only names the file-name open's search: a reader open
// takes the correction file when it is given one.
static const int kVibeWavPackOpenFlags = OPEN_NORMALIZE | OPEN_DSD_AS_PCM;

// The correction file a play of the hybrid file at `url` would take, or nil:
// the first spelling (PlayableExtensions) that is a regular file of some
// bytes, on this device. A placeholder whose bytes are elsewhere, and a file
// a transfer is still writing, are none, since a play would wait for them.
// One stat a spelling, and no read. The play and the indexer's check share it.
static NSURL *VibeWavPackUsableCorrection(NSURL *url) {
    for (NSURL *spelling in [PlayableExtensions wavPackCorrectionSpellingsOf:url]) {
        struct stat info;
        if (stat(spelling.fileSystemRepresentation, &info) != 0) {
            continue;
        }
        BOOL dataless = NO;
#ifdef SF_DATALESS
        dataless = (info.st_flags & SF_DATALESS) != 0;
#endif
        if (!S_ISREG(info.st_mode) || info.st_size <= 0 || dataless
                || [CloudFileMaterializer availabilityForURL:spelling]) {
            return nil;
        }
        return spelling;
    }
    return nil;
}

@implementation AudioFileHandle (WavPackCorrection)

+ (NSURL *)correctionFileForWavPack:(NSURL *)url {
    return VibeWavPackUsableCorrection(url);
}

@end

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
// frames libwavpack made without the correction never play as lossless. So is
// any error libwavpack counts while it decodes with a correction file: a
// block of the .wvc missing, cut short, or another song's, as when the .wvc
// was replaced or cut during the play. libwavpack would decode that block's
// lossy half, while the facts say lossless, so the read fails for good. It
// can't tell that from a damaged block, which then fails the read too.
- (void)takeCorrectionFault {
    AudioFileHandle *correction = _wavpackCorrection;
    if (!correction) {
        return;
    }
    if (correction->_waitError || correction->_streamReadFailed) {
        if (correction->_waitError && !_waitError) {
            _waitError = correction->_waitError;
        }
        _streamReadFailed = _streamReadFailed || correction->_streamReadFailed;
        _wavpackStale = YES;
    } else if (_wavpack && WavpackGetNumErrors(_wavpack) > 0) {
        _streamReadFailed = YES;
        _wavpackStale = YES;
    }
}

#pragma mark - The correction file

// The samples in the file's first block, from its header, past any ID3v2
// tags. A hybrid encode gives every block that many, but its last. 0 when the
// header can't be read.
- (uint32_t)wavPackBlockSamples {
    uint8_t header[32];
    UInt32 got = 0;
    SInt64 at = 0;
    if (VibeHandleRead((__bridge void *)self, 0, 10, header, &got) == noErr && got == 10) {
        at = VibeID3v2TagBytes(header);
    }
    if (VibeHandleRead((__bridge void *)self, at, sizeof header, header, &got) != noErr || got != sizeof header
            || memcmp(header, "wvpk", 4) != 0) {
        return 0;
    }
    return OSReadLittleInt32(header, 20);
}

// YES when the context decodes three whole blocks lossless with the
// correction file: the first, the middle, and the last. libwavpack pairs a
// .wvc's block with the .wv's by its index, its samples, and its flags, and
// nothing ties a .wvc to its .wv. Each block's checksum is the lossless
// decode's, so another song's .wvc, or another encode's of the same song, fails
// it, and one cut short has no last block. A block of digital silence passes
// either way, so one block alone could pass the wrong .wvc for a song that ends
// in silence. Three blocks' decode, and the reads that find each in both
// files. Then it seeks back to the start.
static BOOL VibeWavPackCorrectionHolds(WavpackContext *context, uint32_t blockSamples, int32_t *buffer, uint32_t chunk) {
    int64_t total = WavpackGetNumSamples64(context);
    if (!(WavpackGetMode(context) & MODE_WVC) || total <= 0 || blockSamples == 0) {
        return NO;
    }
    int64_t blocks = (total + blockSamples - 1) / blockSamples;
    int64_t probes[] = {0, blocks / 2, blocks - 1};
    for (size_t i = 0; i < sizeof probes / sizeof *probes; i++) {
        int64_t start = probes[i] * blockSamples;
        if (!WavpackSeekSample64(context, start)) {
            return NO;
        }
        for (int64_t left = MIN((int64_t)blockSamples, total - start); left > 0;) {
            uint32_t got = WavpackUnpackSamples(context, buffer, (uint32_t)MIN(left, (int64_t)chunk));
            if (got == 0) {
                return NO;
            }
            left -= got;
        }
    }
    return WavpackGetNumErrors(context) == 0 && WavpackSeekSample64(context, 0);
}

// A hybrid file plays lossless when its correction file sits beside it, opens,
// and holds (VibeWavPackCorrectionHolds). Otherwise it plays its lossy half,
// as it did, with no error. A file still downloading never looks for one, nor
// takes one still downloading: both play lossy until both are on disk. Only
// the spelling that is there opens. An interruption is the open's, not a
// fallback.
- (void)openWavPackCorrection {
    if (!(WavpackGetMode(_wavpack) & MODE_HYBRID) || _availability.partURL) {
        return;
    }
    NSURL *spelling = VibeWavPackUsableCorrection(_url);
    if (!spelling) {
        return;
    }
    NSError *error = nil;
    AudioFileHandle *correction = [[AudioFileHandle alloc] initBytesForReading:spelling interrupted:_openInterrupted
                                                                         error:&error];
    if ([AudioFileHandle isInterruption:error]) {
        _waitError = error;
    } else if (correction) {
        [self tryWavPackCorrection:correction];
    }
}

// The lossless context replaces the lossy one when the correction holds, and
// no read of either file failed. Otherwise the lossy one stays, at the cursor
// it read to, which the try moved: libwavpack's context holds nothing else of
// the file's position, so no third context is opened.
- (void)tryWavPackCorrection:(AudioFileHandle *)correction {
    SInt64 lossyCursor = _streamCursor;
    uint32_t channels = (uint32_t)MAX(1, WavpackGetNumChannels(_wavpack));
    uint32_t blockSamples = [self wavPackBlockSamples];
    int32_t *buffer = malloc(kVibeWavPackChunkSamples * sizeof(int32_t));
    _wavpackCorrection = correction;
    WavpackContext *lossless = buffer ? [self newWavPackContext] : NULL;
    BOOL holds = lossless
            && VibeWavPackCorrectionHolds(lossless, blockSamples, buffer, MAX(1u, kVibeWavPackChunkSamples / channels));
    free(buffer);
    if ([AudioFileHandle isInterruption:correction->_waitError] && !_waitError) {
        _waitError = correction->_waitError;
    }
    if (holds && !_waitError && !_streamReadFailed && !correction->_waitError && !correction->_streamReadFailed) {
        WavpackCloseFile(_wavpack);
        _wavpack = lossless;
        return;
    }
    if (lossless) {
        WavpackCloseFile(lossless);
    }
    _wavpackCorrection = nil;
    _streamCursor = lossyCursor;
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
// A correction file that went, or emptied, since the open leaves a fresh
// context without it, which would decode the lossy half under lossless facts.
// So that restart fails, as one with a fault in it does.
- (BOOL)restartWavPack {
    WavpackContext *fresh = [self newWavPackContext];
    AudioFileHandle *correction = _wavpackCorrection;
    BOOL faulted = correction && (correction->_waitError || correction->_streamReadFailed);
    if (fresh && (faulted || (correction && !(WavpackGetMode(fresh) & MODE_WVC)))) {
        WavpackCloseFile(fresh);
        fresh = NULL;
    }
    if (!fresh) {
        [self takeCorrectionFault];
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
