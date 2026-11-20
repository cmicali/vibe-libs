//
//  AudioFileHandle+DSD.m
//  vibe-libs
//
//  The DSD decode, its DSD converted to PCM: a DSF file's open, and for a
//  DSF or a DSD WavPack file the facts, the reads, the seeks, and the close.
//  VibeDSF.h parses a DSF and reads each channel's DSD bytes through the
//  handle's reads. libwavpack hands out a WavPack file's
//  (AudioFileHandle+WavPack.m). VibeDSDToPCM.h converts them, the same
//  way for both, so the same DSD decodes to the same samples in either. The
//  ivars are AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"

// The frames a read converts at a time. Its bytes are a channel's frames
// times the bytes a frame, for each channel: 64 KB a channel at DSD512.
enum { kVibeDSDChunkFrames = 4096 };

@implementation AudioFileHandle (DSD)

// The fmt chunk's channel types as labels. Nil for mono and stereo, which
// need none. The spec's back channels are CoreAudio's surrounds.
static AVAudioChannelLayout *VibeDSFChannelLayout(uint32_t channelType) {
    enum { L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center,
           Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround,
           LFE = kAudioChannelLabel_LFEScreen };
    static const AudioChannelLabel orders[5][kVibeDSFMaxChannels] = {
        {L, R, C}, {L, R, Ls, Rs}, {L, R, C, LFE}, {L, R, C, Ls, Rs}, {L, R, C, LFE, Ls, Rs},
    };
    uint32_t channels = VibeDSFChannelsOfType(channelType);
    return channels <= 2 ? nil : VibeLabeledLayout(orders[channelType - 3], channels);
}

// The handle's reads for VibeDSF.c. A short read is a file that ended
// before its header said, as a failed one is.
static ssize_t VibeDSFHandleRead(void *user, uint64_t offset, void *buffer, size_t count) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    if (offset > INT64_MAX) {
        return -1;
    }
    return VibeHandleFetch(handle, (SInt64)offset, (SInt64)count, buffer, count);
}

// Takes the file when it is a DSF this reader plays. NO for any other DSF,
// which no other decoder takes either.
- (BOOL)openDSFInterleaved:(BOOL)interleaved {
    uint8_t header[kVibeDSFHeaderBytes];
    ssize_t got = VibeHandleFetch(self, 0, sizeof header, header, sizeof header);
    if (got < (ssize_t)sizeof header || !VibeDSFParseHeader(header, sizeof header, (uint64_t)MAX(0, _size), &_dsf)) {
        return NO;
    }
    return [self startDSDWithLayout:VibeDSFChannelLayout(_dsf.channelType) interleaved:interleaved];
}

// The converter, the buffers, and the facts, for the channels, rate, order,
// and count _dsf holds. The facts are the PCM's: float at the output rate, so
// the player and a bit-perfect device see the samples they get.
// dsdSampleRate keeps the DSD rate. NO frees what it made.
- (BOOL)startDSDWithLayout:(AVAudioChannelLayout *)layout interleaved:(BOOL)interleaved {
    _dsd = VibeDSDToPCMCreate(_dsf.channels, _dsf.rateMultiple, _dsf.lsbFirst);
    if (!_dsd) {
        return NO;
    }
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    size_t chunkBytes = (size_t)kVibeDSDChunkFrames * perFrame;
    _dsdBytes = malloc(chunkBytes * _dsf.channels);
    if (!_wavpack) {
        // A chunk spans at most two groups of blocks more than it fills.
        _dsdSpanBytes = (chunkBytes / kVibeDSFBlockBytes + 2) * kVibeDSFBlockBytes * _dsf.channels;
        _dsdSpan = malloc(_dsdSpanBytes);
    }
    double rate = (double)_dsf.sampleRate / (16.0 * _dsf.rateMultiple);
    AudioStreamBasicDescription description = {
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * _dsf.channels, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * _dsf.channels,
        .mChannelsPerFrame = _dsf.channels, .mBitsPerChannel = 32,
    };
    if (!_dsdBytes || (!_wavpack && !_dsdSpan)
            || ![self takeFileFormat:description layout:layout interleaved:interleaved]) {
        [self closeDSD];
        return NO;
    }
    _dsdBytesEnd = (SInt64)(_dsf.sampleCount / 8);
    _length = _dsdBytesEnd / perFrame;
    [self restartDSDAtFrame:0];
    return YES;
}

- (void)closeDSD {
    VibeDSDToPCMFree(_dsd);
    _dsd = NULL;
    free(_dsdBytes);
    _dsdBytes = NULL;
    free(_dsdSpan);
    _dsdSpan = NULL;
}

// The converter starts over, and the next read feeds it from the lead before
// `frame`, whose outputs it drops. So the reads from `frame` on are what a
// read from the start gives there, sample for sample.
- (void)restartDSDAtFrame:(SInt64)frame {
    VibeDSDToPCMReset(_dsd);
    _dsdPosition = frame;
    _dsdRestarted = YES;
}

// Lands at the end for a target past it, where reads return nothing. A
// WavPack file's decode moves to the lead's first byte now, so a seek that
// fails fails here, as its PCM seek does.
- (BOOL)seekDSDToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    SInt64 target = MIN(MAX(0, frame), _length);
    [self restartDSDAtFrame:target];
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    if (_wavpack && ![self seekWavPackDSDToByte:MAX(0, target - kVibeDSDToPCMLeadFrames) * perFrame] && !_waitError
            && error) {
        *error = VibeHandleError(kAudioFilePositionError,
                                 [NSString stringWithFormat:@"Seeking %@ failed", _url.lastPathComponent]);
        return NO;
    }
    return [self reportWaitFault:error] && !_wavpackStale;
}

// Feeds the converter `frames` frames from frame `feed`, writing each
// channel's output at `planes`, a channel to each or interleaved. Every
// channel's bytes are read before any is converted, so a failed read, NO,
// leaves the converter as it was.
- (BOOL)feedDSDFrames:(UInt32)frames from:(SInt64)feed into:(float *const *)planes interleaved:(BOOL)interleaved {
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    size_t bytes = (size_t)frames * perFrame;
    uint8_t *channels[kVibeDSFMaxChannels];
    for (uint32_t c = 0; c < _dsf.channels; c++) {
        channels[c] = _dsdBytes + c * bytes;
    }
    BOOL read = _wavpack ? [self readWavPackDSDBytes:channels from:feed * perFrame count:bytes]
            : VibeDSFReadChannels(&_dsf, VibeDSFHandleRead, (__bridge void *)self, feed * perFrame, bytes, channels,
                                  _dsdSpan, _dsdSpanBytes);
    if (!read) {
        return NO;
    }
    for (uint32_t c = 0; c < _dsf.channels; c++) {
        float *out = interleaved ? planes[0] + c : planes[c];
        VibeDSDToPCMProcess(_dsd, c, channels[c], frames, out, interleaved ? _dsf.channels : 1);
    }
    return YES;
}

// Reads stop at the length, or where a WavPack file's decode ended short
// (_dsdBytesEnd), which a feed can find. Its last frames before that read the
// bytes after it as silence.
- (BOOL)readDSDIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    enum { kDropped = kVibeDSDToPCMLeadFrames + kVibeDSDToPCMDelayFrames };
    BOOL interleaved = _processingFormat.isInterleaved;
    UInt32 channels = _dsf.channels;
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    float *const *planes = buffer.floatChannelData;
    AVAudioFrameCount done = 0;
    BOOL failed = NO;
    // After a restart, the lead's outputs go to a scratch buffer. Then the
    // feed runs kVibeDSDToPCMDelayFrames ahead of the frame delivered.
    if (_dsdRestarted && wanted > 0 && _dsdPosition < MIN(_length, _dsdBytesEnd / perFrame)) {
        float scratch[kDropped * kVibeDSFMaxChannels];
        float *scratchPlanes[1] = {scratch};
        failed = ![self feedDSDFrames:kDropped from:_dsdPosition - kVibeDSDToPCMLeadFrames into:scratchPlanes interleaved:YES];
        _dsdRestarted = failed;
    }
    while (!failed) {
        SInt64 left = MIN((SInt64)(wanted - done), MIN(_length, _dsdBytesEnd / perFrame) - _dsdPosition);
        if (left <= 0) {
            break;
        }
        UInt32 frames = (UInt32)MIN(left, (SInt64)kVibeDSDChunkFrames);
        float *at[kVibeDSFMaxChannels];
        for (UInt32 c = 0; c < (interleaved ? 1 : channels); c++) {
            at[c] = planes[c] + (size_t)done * (interleaved ? channels : 1);
        }
        failed = ![self feedDSDFrames:frames from:_dsdPosition + kVibeDSDToPCMDelayFrames into:at interleaved:interleaved];
        if (!failed) {
            // A decode that ended short in this chunk keeps the frames before it.
            UInt32 kept = (UInt32)MIN((SInt64)frames, MAX(0, _dsdBytesEnd / perFrame - _dsdPosition));
            done += kept;
            _dsdPosition += kept;
        }
    }
    buffer.frameLength = done;
    return [self finishReadFailed:failed error:error];
}

@end
