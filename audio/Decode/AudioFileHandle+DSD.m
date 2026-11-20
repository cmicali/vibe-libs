//
//  AudioFileHandle+DSD.m
//  vibe-libs
//
//  The decode of a DSF file, its DSD converted to PCM: the open, the facts,
//  the reads, the seeks, and the close. VibeDSF.h parses the container and
//  reads each channel's DSD bytes through the handle's reads. VibeDSDToPCM.h
//  converts them. The ivars are AudioFileHandleInternal.h's.
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
// which no other decoder takes either. The facts are the PCM's: float at the
// output rate, so the player and a bit-perfect device see the samples they
// get. dsdSampleRate keeps the DSD rate.
- (BOOL)openDSFInterleaved:(BOOL)interleaved {
    uint8_t header[kVibeDSFHeaderBytes];
    ssize_t got = VibeHandleFetch(self, 0, sizeof header, header, sizeof header);
    if (got < (ssize_t)sizeof header || !VibeDSFParseHeader(header, sizeof header, (uint64_t)MAX(0, _size), &_dsf)) {
        return NO;
    }
    _dsd = VibeDSDToPCMCreate(_dsf.channels, _dsf.rateMultiple, _dsf.lsbFirst);
    if (!_dsd) {
        return NO;
    }
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    size_t chunkBytes = (size_t)kVibeDSDChunkFrames * perFrame;
    _dsdBytes = malloc(chunkBytes * _dsf.channels);
    // A chunk spans at most two groups of blocks more than it fills.
    _dsdSpanBytes = (chunkBytes / kVibeDSFBlockBytes + 2) * kVibeDSFBlockBytes * _dsf.channels;
    _dsdSpan = malloc(_dsdSpanBytes);
    double rate = (double)_dsf.sampleRate / (16.0 * _dsf.rateMultiple);
    AudioStreamBasicDescription description = {
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * _dsf.channels, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * _dsf.channels,
        .mChannelsPerFrame = _dsf.channels, .mBitsPerChannel = 32,
    };
    if (!_dsdBytes || !_dsdSpan
            || ![self takeFileFormat:description layout:VibeDSFChannelLayout(_dsf.channelType) interleaved:interleaved]) {
        [self closeDSD];
        return NO;
    }
    _length = (SInt64)(_dsf.sampleCount / (8ull * perFrame));
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

// Lands at the end for a target past it, where reads return nothing.
- (BOOL)seekDSDToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    [self restartDSDAtFrame:MIN(MAX(0, frame), _length)];
    return [self reportWaitFault:error];
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
    if (!VibeDSFReadChannels(&_dsf, VibeDSFHandleRead, (__bridge void *)self, feed * perFrame, bytes, channels,
                             _dsdSpan, _dsdSpanBytes)) {
        return NO;
    }
    for (uint32_t c = 0; c < _dsf.channels; c++) {
        float *out = interleaved ? planes[0] + c : planes[c];
        VibeDSDToPCMProcess(_dsd, c, channels[c], frames, out, interleaved ? _dsf.channels : 1);
    }
    return YES;
}

- (BOOL)readDSDIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    enum { kDropped = kVibeDSDToPCMLeadFrames + kVibeDSDToPCMDelayFrames };
    BOOL interleaved = _processingFormat.isInterleaved;
    UInt32 channels = _dsf.channels;
    float *const *planes = buffer.floatChannelData;
    AVAudioFrameCount total = (AVAudioFrameCount)MIN((SInt64)wanted, MAX(0, _length - _dsdPosition));
    AVAudioFrameCount done = 0;
    BOOL failed = NO;
    // After a restart, the lead's outputs go to a scratch buffer. Then the
    // feed runs kVibeDSDToPCMDelayFrames ahead of the frame delivered.
    if (_dsdRestarted && total > 0) {
        float scratch[kDropped * kVibeDSFMaxChannels];
        float *scratchPlanes[1] = {scratch};
        failed = ![self feedDSDFrames:kDropped from:_dsdPosition - kVibeDSDToPCMLeadFrames into:scratchPlanes interleaved:YES];
        _dsdRestarted = failed;
    }
    while (done < total && !failed) {
        UInt32 frames = MIN(total - done, (UInt32)kVibeDSDChunkFrames);
        float *at[kVibeDSFMaxChannels];
        for (UInt32 c = 0; c < (interleaved ? 1 : channels); c++) {
            at[c] = planes[c] + (size_t)done * (interleaved ? channels : 1);
        }
        failed = ![self feedDSDFrames:frames from:_dsdPosition + kVibeDSDToPCMDelayFrames into:at interleaved:interleaved];
        if (!failed) {
            done += frames;
            _dsdPosition += frames;
        }
    }
    buffer.frameLength = done;
    return [self finishReadFailed:failed error:error];
}

@end
