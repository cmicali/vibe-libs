//
//  AudioFileHandleInternal.h
//  vibe-libs
//
//  The private header AudioFileHandle.m and its decodes share: dr_mp3's
//  (AudioFileHandle+MPEG.m), dr_flac's, dr_wav's and libvorbis's
//  (AudioFileHandle+Stream.m), and libwavpack's (AudioFileHandle+WavPack.m).
//  It holds the ivars the decodes read, the reads and waits they call, and the
//  decodes' methods the core calls. Only those four files import it.
//

#import "AudioFileHandle.h"

#include "dr_mp3/dr_mp3.h"
#include "dr_flac/dr_flac.h"
#include "dr_wav/dr_wav.h"
#include <vorbis/vorbisfile.h>
// TRAP: wavpack.h names a struct ChunkHeader, as CoreServices' AIFF.h does,
// which Foundation brings in. So it takes another name here.
#define ChunkHeader VibeWavPackChunkHeader
#include <wavpack.h>
#undef ChunkHeader

#include <stdatomic.h>

@class CloudFileAvailability;

// The bound on a decoded sample where damage can run past it: a damaged MP3
// frame, or an Opus header's gain. dr_mp3 never clamps, and one damaged frame
// can decode past +90 dBFS. The FX's reverb and delay then ring at full scale
// for seconds, the equalizer's reference stays up for half a minute, and the
// track's detected tempo moves. The bound, +12 dBFS, sits well above any real
// master's overs (this piece's AGENTS.md).
static const float kVibeDecodeSampleBound = 4.0f;

// The format a lossy WavPack file states: a hybrid file without its correction
// file, or DSD. The SDK names no constant (AudioFileFormat.m).
static const AudioFormatID kVibeWavPackFormat = 'wvpk';

// Small reads go through one block: the parser's under kVibeReadBlock, filling
// all of it — Apple's Ogg reader asks for about 200 bytes at a time on Opus,
// 18,000 reads for three minutes — and dr_flac's 4 KB ones, filling a quarter:
// a seek's bisection probes a few KB at each position it tries, and dr_wav's
// larger reads gain nothing from a copy. Anything bigger is read straight
// through.
enum { kVibeReadBlock = 64 * 1024, kVibeStreamReadSmall = 4096, kVibeStreamReadFill = 16 * 1024 };

@interface AudioFileHandle () {
    // The properties' own, declared here so the decode reads them directly.
    NSURL *_url;
    AVAudioFormat *_fileFormat;
    AVAudioFormat *_processingFormat;
    SInt64 _size;
    // Written by the decode of a stream counting its MPEG packets as it
    // goes, and read on any thread, hence the getter's atomic load.
    AVAudioFramePosition _length;
    AudioFileID _parser;
    ExtAudioFileRef _codec; // NULL while dr_mp3, dr_flac, dr_wav, libvorbis or libwavpack decodes
    // A file still streaming, or reading ahead: every read waits for its
    // bytes. Set by the open and fixed from then on. Nil for a whole file.
    CloudFileAvailability *_availability;
    // Latched by the wait that answered no, so each decoder sees one clean
    // end of data, never bytes after a gap, and its read or seek reports why:
    // the transfer's error, for good, or an interruption, until the next seek.
    NSError *_waitError;
    // dr_mp3's decode: the stream's frames, its packets, on a timeline of
    // packet × framesPerPacket, with _mpegSkip frames before logical frame 0.
    drmp3dec *_mpeg;
    uint8_t *_mpegPacket;    // the packet decoded last
    UInt32 _mpegPacketBytes; // 0 when none is held
    // The frames walked so far: each one's offset and size, in stream order.
    // The walk goes on from _mpegWalk, and has ended at the data's end.
    SInt64 *_mpegOffsets;
    uint16_t *_mpegSizes;
    SInt64 _mpegIndexed;
    SInt64 _mpegIndexCapacity;
    SInt64 _mpegWalk;
    SInt64 _mpegDataEnd;
    BOOL _mpegWalkEnded;
    // What every frame of the stream shares (VibeMPEGFrame.fixed).
    UInt32 _mpegFixed;
    UInt32 _mpegFirstBitrate;
    BOOL _mpegConstantBitrate;
    UInt32 _mpegChannels; // the most any frame walked holds
    UInt32 _mpegFramesPerPacket;
    UInt32 _mpegDelay;       // the synthesis filterbank's, in frames
    SInt64 _mpegSkip;
    SInt64 _mpegPacketCount;
    SInt64 _mpegEstimate;    // an uncounted stream's packets at open, for the settle's log
    _Atomic bool _lengthEstimated;
    SInt64 _mpegNextPacket;
    SInt64 _mpegPosition; // logical frame the next read delivers
    float *_mpegPCM;      // one packet's frames, interleaved
    UInt32 _mpegPCMFrames;
    UInt32 _mpegPCMOffset;
    // dr_flac's, dr_wav's or libvorbis's decode, at most one: the stream read
    // through the descriptor at a cursor of its own.
    drflac *_flac;
    drwav *_wav; // &_wavState once drwav_init has succeeded
    drwav _wavState;
    OggVorbis_File *_vorbis;
    // The frame libvorbis's next read delivers, counted here. vorbisfile's own
    // follows the pages' granule positions, and damage can set those to
    // anything.
    SInt64 _vorbisPosition;
    SInt64 _streamCursor;
    BOOL _streamReadFailed; // a pread failed, which no stream decoder can tell from the end
    // libwavpack's decode, at the same cursor: its context, the frame its
    // next read delivers, counted here, and one unpack's samples.
    WavpackContext *_wavpack;
    SInt64 _wavpackPosition;
    int32_t *_wavpackSamples;
    double _wavpackScale; // an integer sample's to ±1, or 0 for float bits
    // Set by an interrupted read, a failed seek, or a decode that ended
    // short: the next seek starts a fresh context, and reads return nothing
    // until then.
    BOOL _wavpackStale;
}

- (BOOL)reportWaitFault:(NSError **)error;
- (BOOL)takeFileFormat:(AudioStreamBasicDescription)description layout:(AVAudioChannelLayout *)layout
           interleaved:(BOOL)interleaved;

@end

// AudioFileHandle+MPEG.m. The stream open calls the opens, and the core
// calls the rest from its own methods' MPEG branches.
@interface AudioFileHandle (MPEG)

- (BOOL)openMPEGFrom:(SInt64)start to:(SInt64)end junk:(BOOL)junk interleaved:(BOOL)interleaved;
- (BOOL)openMPEGInWAVInterleaved:(BOOL)interleaved;
- (void)countMPEGPacketsOnDisk;
- (BOOL)seekMPEGToFrame:(AVAudioFramePosition)frame error:(NSError **)error;
- (BOOL)readMPEGIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error;

@end

// AudioFileHandle+Stream.m. The open tries it before CoreAudio's parser, the
// reads and seeks call the stream decoders' branches, and dealloc closes the
// decoder.
@interface AudioFileHandle (Stream)

- (BOOL)openOwnDecoderInterleaved:(BOOL)interleaved;
- (BOOL)keepStreamDecoderWithLength:(UInt64)length description:(AudioStreamBasicDescription)description
                             layout:(AVAudioChannelLayout *)layout interleaved:(BOOL)interleaved;
- (void)closeStreamDecoder;
- (BOOL)readStreamIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error;

@end

// AudioFileHandle+WavPack.m. The stream open calls the open, its close and
// reads call the close and the reads, and the core's seek calls the seek.
@interface AudioFileHandle (WavPack)

- (BOOL)openWavPackInterleaved:(BOOL)interleaved;
- (void)closeWavPack;
- (BOOL)seekWavPackToFrame:(SInt64)frame;
- (AVAudioFrameCount)readWavPackInto:(float *const *)planes frameCount:(AVAudioFrameCount)wanted;

@end

// AudioFileHandle+Stream.m's layout for a WAVE channel mask, which a WavPack
// file's mask is too.
AVAudioChannelLayout *VibeMaskLayout(UInt32 mask, UInt32 channels);

// AudioFileHandle.m's reads and waits, which the decode's open also uses.
uint32_t VibeID3v2Syncsafe(const uint8_t bytes[4]);
uint32_t VibeID3v2TagBytes(const uint8_t header[10]);
AudioFileTypeID VibeFileTypeForExtension(NSString *extension);
NSError *VibeHandleError(OSStatus status, NSString *description);
BOOL VibeHandleAwaitWhole(AudioFileHandle *handle, BOOL wait);
ssize_t VibeHandleFetch(AudioFileHandle *handle, SInt64 position, SInt64 requested, void *buffer, size_t capacity);
OSStatus VibeHandleRead(void *clientData, SInt64 position, UInt32 requestCount, void *buffer, UInt32 *actualCount);

// AudioFileHandle.m's byte reads for dr_flac, dr_wav, vorbisfile and libwavpack. The
// stream opens pass them to the decoders. They stay beside the parser's
// reads, because the block read they call on every read is static there.
size_t VibeStreamRead(void *user, void *buffer, size_t count);
drflac_bool32 VibeFLACSeek(void *user, int offset, drflac_seek_origin origin);
drwav_bool32 VibeWAVSeek(void *user, int offset, drwav_seek_origin origin);
drflac_bool32 VibeStreamTell(void *user, drflac_int64 *cursor);
drflac_bool32 VibeStreamSeek(void *user, SInt64 offset, int origin);
size_t VibeVorbisRead(void *buffer, size_t size, size_t count, void *user);
int VibeVorbisSeek(void *user, ogg_int64_t offset, int whence);
long VibeVorbisTell(void *user);
