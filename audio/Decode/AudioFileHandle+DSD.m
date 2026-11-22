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
    _dsdBytesEnd = VibeDSDBytes(&_dsf);
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
    _dsdLead = nil;
    _dsdLookahead = nil;
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
    BOOL landed = !_wavpack || [self seekWavPackDSDToByte:MAX(0, target - kVibeDSDToPCMLeadFrames) * perFrame];
    if (!landed && !_waitError && error) {
        *error = VibeSeekError(_url, kAudioFilePositionError);
    }
    return [self reportWaitFault:error] && landed;
}

// Replace just the part of the read that overlaps the adjacent track.
static void VibeCopyDSDEdge(NSData *edge, SInt64 start, SInt64 first, size_t bytes,
                            uint8_t *const *channels, UInt32 count) {
    if (!edge) return;
    size_t span = edge.length / count;
    SInt64 from = MAX(first, start), to = MIN(first + (SInt64)bytes, start + (SInt64)span);
    if (to <= from) return;
    for (UInt32 c = 0; c < count; c++) {
        memcpy(channels[c] + (from - first), (const uint8_t *)edge.bytes + c * span + (from - start), to - from);
    }
}

- (BOOL)readDSDBytes:(uint8_t *const *)channels from:(SInt64)first count:(size_t)bytes {
    BOOL read = _wavpack ? [self readWavPackDSDBytes:channels from:first count:bytes]
            : VibeDSFReadChannels(&_dsf, VibeDSFHandleRead, (__bridge void *)self, first, bytes, channels,
                                  _dsdSpan, _dsdSpanBytes);
    if (read && (_dsdLead || _dsdLookahead)) {
        VibeCopyDSDEdge(_dsdLead, -(SInt64)(_dsdLead.length / _dsf.channels), first, bytes, channels, _dsf.channels);
        VibeCopyDSDEdge(_dsdLookahead, _length * VibeDSDToPCMBytesPerFrame(_dsd), first, bytes, channels, _dsf.channels);
    }
    return read;
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
    if (![self readDSDBytes:channels from:feed * perFrame count:bytes]) {
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
    // The length, or where a WavPack file's decode ended short, which a feed
    // can move. _dsdBytesEnd holds the length's bytes, or fewer.
    SInt64 end = _dsdBytesEnd / perFrame;
    AVAudioFrameCount done = 0;
    BOOL failed = NO;
    // After a restart, the lead's outputs go to a scratch buffer. Then the
    // feed runs kVibeDSDToPCMDelayFrames ahead of the frame delivered.
    if (_dsdRestarted && wanted > 0 && _dsdPosition < end) {
        float scratch[kDropped * kVibeDSFMaxChannels];
        float *scratchPlanes[1] = {scratch};
        failed = ![self feedDSDFrames:kDropped from:_dsdPosition - kVibeDSDToPCMLeadFrames into:scratchPlanes interleaved:YES];
        _dsdRestarted = failed;
        end = _dsdBytesEnd / perFrame;
    }
    while (!failed) {
        SInt64 left = MIN((SInt64)(wanted - done), end - _dsdPosition);
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
            end = _dsdBytesEnd / perFrame;
            UInt32 kept = (UInt32)MIN((SInt64)frames, MAX(0, end - _dsdPosition));
            done += kept;
            _dsdPosition += kept;
        }
    }
    buffer.frameLength = done;
    return [self finishReadFailed:failed error:error];
}

@end

@implementation AudioFileHandle (DSDSplice)

- (AVAudioFramePosition)dsdSpliceFrameBeforeEnd:(AVAudioFramePosition)end {
    if (end > 0 && end < _length) return -1;
    return _dsd ? MAX(0, _length - kVibeDSDToPCMDelayFrames) : -1;
}

- (NSData *)dsdEdgeFromFrame:(SInt64)frame count:(UInt32)frames forFile:(AudioFileHandle *)other {
    unsigned perFrame = VibeDSDToPCMBytesPerFrame(_dsd);
    size_t bytes = frames * perFrame;
    NSMutableData *edge = [NSMutableData dataWithLength:_dsf.channels * bytes];
    uint8_t *channels[kVibeDSFMaxChannels];
    uint8_t *data = edge.mutableBytes;
    for (UInt32 c = 0; c < _dsf.channels; c++) channels[c] = data + c * bytes;
    if (![self readDSDBytes:channels from:frame * perFrame count:bytes]) return nil;
    if (_dsf.lsbFirst != other->_dsf.lsbFirst) {
        for (NSUInteger i = 0; i < edge.length; i++) data[i] = __builtin_bitreverse8(data[i]);
    }
    return edge;
}

- (BOOL)prepareDSDSpliceToFile:(AudioFileHandle *)next {
    if (self == next || !_dsd || !next->_dsd || _dsf.sampleRate != next->_dsf.sampleRate
            || _dsf.channels != next->_dsf.channels || _length == 0 || next.length == 0
            || (_dsdPosition > [self dsdSpliceFrameBeforeEnd:0] && !_dsdRestarted)) return NO;
    if (![next seekToFrame:0 error:NULL]) return NO;
    NSData *head = [next dsdEdgeFromFrame:0 count:kVibeDSDToPCMDelayFrames forFile:self];
    if (!head) return NO;
    NSData *tail = [self dsdEdgeFromFrame:_length - kVibeDSDToPCMLeadFrames count:kVibeDSDToPCMLeadFrames forFile:next];
    if (!tail || _dsdBytesEnd / VibeDSDToPCMBytesPerFrame(_dsd) < _length) return NO;
    next->_dsdLead = tail;
    _dsdLookahead = head;
    return YES;
}

@end
