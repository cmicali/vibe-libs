//
//  AudioFileHandle+WavPack.m
//  vibe-libs
//
//  libwavpack's decode of a WavPack file: the open through a reader over the
//  handle's stream reads, the facts, the reads, the seek, the restart after
//  an interrupted read, and the close. The sniff that sends a file here is
//  AudioFileHandle+Stream.m's. The ivars are AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"

// The samples one unpack fills, across every channel: 64 KB. A file of many
// channels unpacks fewer frames at a time.
static const uint32_t kVibeWavPackChunkSamples = 16384;

// The highest rate the handle plays, as dr_wav's (this piece's AGENTS.md). A
// DSD file decodes to an eighth of its DSD rate, so DSD256 and up is refused.
static const uint32_t kVibeWavPackMaxRate = 768000;

// TRAP: OPEN_NORMALIZE scales a float file's samples to ±1 when its encoder
// stored them at another exponent. OPEN_DSD_AS_PCM decimates DSD to 24-bit
// PCM at an eighth of its rate. With neither, DSD would decode as 1-bit
// bytes. No OPEN_WVC: a hybrid file plays its lossy half alone.
static const int kVibeWavPackOpenFlags = OPEN_NORMALIZE | OPEN_DSD_AS_PCM;

@implementation AudioFileHandle (WavPack)

#pragma mark - The reader

// Inside the implementation, so they may read the handle's ivars.
// libwavpack reads through these, at the stream decoders' cursor, so its
// reads wait for a stream's bytes and fail as dr_flac's do (VibeStreamRead).

static int32_t VibeWavPackRead(void *user, void *data, int32_t count) {
    return count > 0 ? (int32_t)VibeStreamRead(user, data, (size_t)count) : 0;
}

static int64_t VibeWavPackPosition(void *user) {
    return ((__bridge AudioFileHandle *)user)->_streamCursor;
}

static int VibeWavPackMove(void *user, int64_t delta, int mode) {
    _Static_assert(SEEK_SET == 0 && SEEK_CUR == 1 && SEEK_END == 2, "VibeStreamSeek's origins");
    return VibeStreamSeek(user, delta, mode) ? 0 : -1;
}

static int VibeWavPackMoveTo(void *user, int64_t position) {
    return VibeWavPackMove(user, position, SEEK_SET);
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
    .set_pos_rel = VibeWavPackMove, .push_back_byte = VibeWavPackPushBack, .get_length = VibeWavPackLength,
    .can_seek = VibeWavPackCanSeek,
};

- (WavpackContext *)newWavPackContext {
    _streamCursor = 0;
    char message[80];
    return WavpackOpenFileInputEx64(&kVibeWavPackReader, (__bridge void *)self, NULL, message, kVibeWavPackOpenFlags, 0);
}

#pragma mark - The open

// libwavpack answers the facts. A lossless file states them as the WAV it was
// packed from: PCM of its width, high-aligned in its bytes, float or signed
// integer, and an 8-bit sample unsigned unless its source's was signed. So
// bit-perfect output keeps its depth. A hybrid file without its correction
// file, and DSD, state WavPack's own format ID and no depth, as a lossy codec
// does. A layout follows from the channel mask, as a WAV's does. The length
// is the first block's count, or the last block's end for a file that never
// stated it. A file whose length cannot be found is refused.
- (BOOL)openWavPackInterleaved:(BOOL)interleaved {
    _wavpack = [self newWavPackContext];
    if (!_wavpack) {
        return NO;
    }
    int mode = WavpackGetMode(_wavpack), qualify = WavpackGetQualifyMode(_wavpack);
    UInt32 channels = (UInt32)WavpackGetNumChannels(_wavpack), rate = WavpackGetSampleRate(_wavpack);
    UInt32 bits = (UInt32)WavpackGetBitsPerSample(_wavpack), bytes = (UInt32)WavpackGetBytesPerSample(_wavpack);
    int64_t total = WavpackGetNumSamples64(_wavpack);
    BOOL isFloat = (mode & MODE_FLOAT) != 0, dsd = (qualify & QMODE_DSD_AUDIO) != 0;
    _wavpackSamples = malloc(kVibeWavPackChunkSamples * sizeof(int32_t));
    if (rate > kVibeWavPackMaxRate || bytes < 1 || bytes > 4 || bits > bytes * 8 || channels == 0 || !_wavpackSamples) {
        [self closeStreamDecoder];
        return NO;
    }
    _wavpackScale = isFloat ? 0 : 1.0 / (double)(1u << (bytes * 8 - 1));
    AudioStreamBasicDescription description = {.mSampleRate = rate, .mChannelsPerFrame = channels};
    if ((mode & MODE_LOSSLESS) && !dsd) {
        BOOL isSigned = !isFloat && (bytes > 1 || (qualify & QMODE_SIGNED_BYTES));
        description.mFormatID = kAudioFormatLinearPCM;
        description.mFormatFlags = (bits < bytes * 8 ? kAudioFormatFlagIsAlignedHigh : kAudioFormatFlagIsPacked)
                | (isFloat ? kAudioFormatFlagIsFloat : 0) | (isSigned ? kAudioFormatFlagIsSignedInteger : 0);
        description.mBitsPerChannel = bits;
        description.mBytesPerFrame = description.mBytesPerPacket = bytes * channels;
        description.mFramesPerPacket = 1;
    } else {
        description.mFormatID = kVibeWavPackFormat;
    }
    AVAudioChannelLayout *layout = VibeMaskLayout(WavpackGetChannelMask(_wavpack), channels);
    return [self keepStreamDecoderWithLength:total > 0 ? (UInt64)total : 0 description:description
                                      layout:layout interleaved:interleaved];
}

- (void)closeWavPack {
    if (_wavpack) {
        WavpackCloseFile(_wavpack);
        _wavpack = NULL;
    }
    free(_wavpackSamples);
    _wavpackSamples = NULL;
}

// TRAP: libwavpack keeps the block it was reading when a read was lost, cut
// short, and a seek inside that block decodes on from it. A failed seek has
// freed its blocks. So after either, or a decode that ended short, the
// context is stale (_wavpackStale), and the next seek swaps in a fresh one,
// opened as the first was. One that fails to open keeps the old, still
// stale, and that seek fails.
- (BOOL)restartWavPack {
    WavpackContext *fresh = [self newWavPackContext];
    if (!fresh) {
        return NO;
    }
    WavpackCloseFile(_wavpack);
    _wavpack = fresh;
    _wavpackPosition = 0;
    _wavpackStale = NO;
    return YES;
}

#pragma mark - Seeking and reading

// A target at or past the end lands there without the library, which refuses
// it. Reads there return nothing. A DSD file's seek decodes the 16 samples
// before the target, so the decimation lands sample-exact.
- (BOOL)seekWavPackToFrame:(SInt64)frame {
    if (_wavpackStale && ![self restartWavPack]) {
        return NO;
    }
    if (frame >= _length) {
        _wavpackPosition = _length;
        return YES;
    }
    if (WavpackSeekSample64(_wavpack, frame)) {
        _wavpackPosition = frame;
        return YES;
    }
    _wavpackStale = YES;
    return NO;
}

// libwavpack unpacks interleaved 32-bit samples, right-aligned in the file's
// bytes, or float bits. An integer is scaled to ±1 as dr_wav scales a WAV's,
// so the two decode one file's samples to the same floats. A damaged block
// decodes as silence, and the decode goes on from the next. A cut file ends
// at its last whole block.
- (AVAudioFrameCount)readWavPackInto:(float *const *)planes frameCount:(AVAudioFrameCount)wanted {
    UInt32 channels = _processingFormat.channelCount;
    BOOL interleaved = _processingFormat.isInterleaved;
    uint32_t chunk = MAX(1u, kVibeWavPackChunkSamples / channels);
    const int32_t *samples = _wavpackSamples;
    AVAudioFrameCount got = 0;
    while (got < wanted && !_wavpackStale) {
        uint32_t frames = WavpackUnpackSamples(_wavpack, _wavpackSamples, MIN(chunk, wanted - got));
        if (frames == 0) {
            // TRAP: an unpack that stops short of the length is the decode's
            // end. libwavpack would go on at the next block that follows on,
            // so damage that reorders blocks read frames after the end.
            _wavpackStale = YES;
            break;
        }
        for (uint32_t f = 0; f < frames; f++) {
            for (UInt32 c = 0; c < channels; c++) {
                int32_t sample = samples[(size_t)f * channels + c];
                float value;
                if (_wavpackScale == 0) {
                    memcpy(&value, &sample, sizeof value);
                } else {
                    value = (float)(sample * _wavpackScale);
                }
                if (interleaved) {
                    planes[0][(size_t)(got + f) * channels + c] = value;
                } else {
                    planes[c][got + f] = value;
                }
            }
        }
        got += frames;
    }
    _wavpackPosition += got;
    return got;
}

@end
