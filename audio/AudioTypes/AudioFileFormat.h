//
//  AudioFileFormat.h
//  vibe-libs
//
//  A file's kind, shared by metadata display and conversion. The kind is
//  the codec's name, whatever the container: AAC in an M4A is AAC. A
//  container's name (WAV, AIFF, W64, CAF, MP4) is the kind only for PCM, or
//  for a codec with no name of its own here.
//

#import <Foundation/Foundation.h>
#import <CoreAudioTypes/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *VibeAudioFileFormat NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMP3;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMP2;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatAAC;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatFLAC;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMP4;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatALAC;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatAIFF;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatWAV;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatW64;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatCAF;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatVorbis;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatOpus;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatWavPack;
FOUNDATION_EXPORT VibeAudioFileFormat const VibeAudioFileFormatMonkeysAudio;

// The format ID audio/Decode states for a Monkey's Audio file. The SDK names
// no constant.
enum { kVibeAudioFormatMonkeysAudio = 'APE ' };

// The codec's name, or nil for one without a constant here (PCM among them:
// its name is its container's).
FOUNDATION_EXPORT VibeAudioFileFormat _Nullable VibeAudioFileFormatForCodec(AudioFormatID codec);

NS_ASSUME_NONNULL_END
