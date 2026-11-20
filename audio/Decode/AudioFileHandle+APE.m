//
//  AudioFileHandle+APE.m
//  vibe-libs
//
//  Monkey's Audio's decode of an .ape file through its SDK
//  (third_party/monkeys_audio, behind VibeAPEDecoder.h): the open, the facts
//  it answers in place of CoreAudio's parser, which has no reader for it, and
//  the reads. The byte reads are AudioFileHandle.m's (VibeStreamRead). The
//  close is the stream decoders' (closeStreamDecoder).
//

#import "AudioFileHandleInternal.h"
#import "VibeMacros.h"

// The format ID an APE file states. The SDK names no constant.
static const AudioFormatID kVibeMonkeysAudioFormat = 'APE ';

@implementation AudioFileHandle (APE)

// The SDK's reads, through the stream decoders' at their cursor. A read
// that failed, or a wait that answered no, reads nothing (-1).
static int64_t VibeAPERead(void *user, int64_t position, void *buffer, int64_t count) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    handle->_streamCursor = position;
    size_t got = VibeStreamRead(user, buffer, (size_t)count);
    if ((int64_t)got < count && (handle->_streamReadFailed || handle->_waitError)) {
        return -1;
    }
    return (int64_t)got;
}

// The SDK answers the facts. The source depth is the lossless formats' flag,
// as dr_flac's is (AudioFileHandle+Stream.m): an 8-bit file states 16. A
// float file states 32. The packet is one of the file's frames. The layout
// is the source WAV's channel mask, which the file keeps.
- (BOOL)openAPEInterleaved:(BOOL)interleaved {
    int code = 0;
    _ape = VibeAPEDecoderOpen(VibeAPERead, (__bridge void *)self, _size, &code);
    if (!_ape) {
        LogInfo(@"Open: %@ is no Monkey's Audio file the SDK decodes (%d)", _url.lastPathComponent, code);
        return NO;
    }
    VibeAPEFacts facts = VibeAPEDecoderFacts(_ape);
    UInt32 depth = facts.bitsPerSample;
    AudioStreamBasicDescription description = {
        .mSampleRate = facts.sampleRate, .mFormatID = kVibeMonkeysAudioFormat,
        .mFormatFlags = depth <= 16 ? kAppleLosslessFormatFlag_16BitSourceData
                : depth <= 24 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_32BitSourceData,
        .mFramesPerPacket = facts.blocksPerFrame, .mChannelsPerFrame = facts.channels,
    };
    if (facts.sampleRate == 0 || facts.channels == 0 || facts.length == 0
            || ![self takeFileFormat:description layout:VibeMaskLayout(facts.channelMask, facts.channels) interleaved:interleaved]) {
        [self closeStreamDecoder];
        return NO;
    }
    _length = facts.length;
    return YES;
}

// Reads all that is asked but at the end of the audio, or of a file cut
// short. A failed read keeps the frames before it, and reports the failure.
- (BOOL)readAPEIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    bool failed = false;
    int64_t got = VibeAPEDecoderRead(_ape, buffer.floatChannelData, _processingFormat.isInterleaved, wanted, &failed);
    buffer.frameLength = (AVAudioFrameCount)got;
    if (failed && !_waitError) {
        if (error) {
            *error = VibeHandleError(kAudioFilePositionError, [NSString stringWithFormat:@"Reading %@ failed", _url.lastPathComponent]);
        }
        return NO;
    }
    return [self reportWaitFault:error];
}

@end
