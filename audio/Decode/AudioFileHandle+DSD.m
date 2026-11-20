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
    static const AudioChannelLabel orders[5][6] = {
        {L, R, C}, {L, R, Ls, Rs}, {L, R, C, LFE}, {L, R, C, Ls, Rs}, {L, R, C, LFE, Ls, Rs},
    };
    static const UInt32 counts[5] = {3, 4, 4, 5, 6};
    if (channelType < 3 || channelType > 7) {
        return nil;
    }
    UInt32 channels = counts[channelType - 3];
    size_t size = offsetof(AudioChannelLayout, mChannelDescriptions) + channels * sizeof(AudioChannelDescription);
    AudioChannelLayout *layout = calloc(1, size);
    if (!layout) {
        return nil;
    }
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = channels;
    for (UInt32 c = 0; c < channels; c++) {
        layout->mChannelDescriptions[c].mChannelLabel = orders[channelType - 3][c];
    }
    AVAudioChannelLayout *result = [[AVAudioChannelLayout alloc] initWithLayout:layout];
    free(layout);
    return result;
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
    if (got < (ssize_t)sizeof header
            || VibeDSFParseHeader(header, sizeof header, (uint64_t)MAX(0, _size), &_dsf) != VibeDSFVerdictOK) {
        return NO;
    }
    _dsd = VibeDSDToPCMCreate(_dsf.channels, _dsf.rateMultiple);
    if (!_dsd) {
        return NO;
    }
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    _dsdBytes = malloc((size_t)kVibeDSDChunkFrames * perFrame * _dsf.channels);
    double rate = (double)_dsf.sampleRate / (16.0 * _dsf.rateMultiple);
    AudioStreamBasicDescription description = {
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * _dsf.channels, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * _dsf.channels,
        .mChannelsPerFrame = _dsf.channels, .mBitsPerChannel = 32,
    };
    if (!_dsdBytes || ![self takeFileFormat:description layout:VibeDSFChannelLayout(_dsf.channelType) interleaved:interleaved]) {
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
}

// The converter starts over from silence, fed from the lead before `frame`,
// whose outputs are dropped. So the reads from `frame` on are what a read
// from the start gives there, sample for sample.
- (void)restartDSDAtFrame:(SInt64)frame {
    VibeDSDToPCMReset(_dsd);
    _dsdPosition = frame;
    _dsdFeed = frame - kVibeDSDToPCMLeadFrames;
    _dsdDrop = kVibeDSDToPCMLeadFrames + kVibeDSDToPCMDelayFrames;
}

// Lands at the end for a target past it, where reads return nothing.
- (BOOL)seekDSDToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    [self restartDSDAtFrame:MIN(MAX(0, frame), _length)];
    return [self reportWaitFault:error];
}

// Feeds the converter `frames` frames from _dsdFeed, writing each channel's
// output at `planes`, a channel to each or interleaved. NO for a failed read,
// with the converter part fed.
- (BOOL)feedDSDFrames:(UInt32)frames into:(float *const *)planes interleaved:(BOOL)interleaved {
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    size_t bytes = (size_t)frames * perFrame;
    uint8_t *channels[8];
    for (uint32_t c = 0; c < _dsf.channels; c++) {
        channels[c] = _dsdBytes + c * bytes;
    }
    if (!VibeDSFReadChannels(&_dsf, VibeDSFHandleRead, (__bridge void *)self, _dsdFeed * perFrame, bytes, channels)) {
        return NO;
    }
    for (uint32_t c = 0; c < _dsf.channels; c++) {
        float *out = interleaved ? planes[0] + c : planes[c];
        VibeDSDToPCMProcess(_dsd, c, channels[c], frames, out, interleaved ? _dsf.channels : 1);
    }
    _dsdFeed += frames;
    return YES;
}

- (BOOL)readDSDIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    BOOL interleaved = _processingFormat.isInterleaved;
    UInt32 channels = _dsf.channels;
    float *const *planes = buffer.floatChannelData;
    AVAudioFrameCount total = (AVAudioFrameCount)MIN((SInt64)wanted, MAX(0, _length - _dsdPosition));
    AVAudioFrameCount done = 0;
    BOOL failed = NO;
    // The outputs a seek drops go to a scratch buffer.
    while (_dsdDrop > 0 && total > 0 && !failed) {
        float scratch[kVibeDSDToPCMLeadFrames + kVibeDSDToPCMDelayFrames][8];
        float *scratchPlanes[1] = {&scratch[0][0]};
        UInt32 frames = _dsdDrop;
        failed = ![self feedDSDFrames:frames into:scratchPlanes interleaved:YES];
        if (!failed) {
            _dsdDrop = 0;
        }
    }
    while (done < total && !failed) {
        UInt32 frames = MIN(total - done, (UInt32)kVibeDSDChunkFrames);
        float *at[8];
        for (UInt32 c = 0; c < (interleaved ? 1 : channels); c++) {
            at[c] = planes[c] + (size_t)done * (interleaved ? channels : 1);
        }
        failed = ![self feedDSDFrames:frames into:at interleaved:interleaved];
        if (!failed) {
            done += frames;
            _dsdPosition += frames;
        }
    }
    buffer.frameLength = done;
    if (failed && !_waitError) {
        if (error) {
            *error = VibeHandleError(kAudioFilePositionError, [NSString stringWithFormat:@"Reading %@ failed", _url.lastPathComponent]);
        }
        // A seek restarts the converter, so the next read may start over.
        return NO;
    }
    return [self reportWaitFault:error];
}

@end
