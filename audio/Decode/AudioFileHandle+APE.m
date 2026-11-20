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

// The format ID an APE file states. The SDK names no constant. AudioTypes'
// kVibeAudioFormatMonkeysAudio is the same, which this piece cannot import.
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
// is the source WAV's channel mask, which the file keeps. A rate past what
// the handle's decoders play is refused.
- (BOOL)openAPEInterleaved:(BOOL)interleaved {
    int code = 0;
    _ape = VibeAPEDecoderOpen(VibeAPERead, (__bridge void *)self, _size, &code);
    if (!_ape) {
        LogInfo(@"Open: %@ is no Monkey's Audio file the SDK decodes (%d)", _url.lastPathComponent, code);
        return NO;
    }
    VibeAPEFacts facts = VibeAPEDecoderFacts(_ape);
    if (facts.sampleRate > kVibeDecodeMaxRate) {
        [self closeStreamDecoder];
        return NO;
    }
    AudioStreamBasicDescription description = {
        .mSampleRate = facts.sampleRate, .mFormatID = kVibeMonkeysAudioFormat,
        .mFormatFlags = VibeLosslessDepthFlag(facts.bitsPerSample),
        .mFramesPerPacket = facts.blocksPerFrame, .mChannelsPerFrame = facts.channels,
    };
    return [self keepStreamDecoderWithLength:(UInt64)facts.length description:description
                                      layout:VibeMaskLayout(facts.channelMask, facts.channels) interleaved:interleaved];
}

// Reads all that is asked but at the end of the audio, or of a file cut
// short. A failed read keeps the frames before it, and sets `failed`.
- (AVAudioFrameCount)readAPEInto:(float *const *)planes frameCount:(AVAudioFrameCount)wanted failed:(BOOL *)failed {
    bool readFailed = false;
    int64_t got = VibeAPEDecoderRead(_ape, planes, _processingFormat.isInterleaved, wanted, &readFailed);
    *failed = readFailed;
    return (AVAudioFrameCount)got;
}

@end
