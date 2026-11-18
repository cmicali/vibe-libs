//
//  TagLibAudioFile.h
//  vibe-libs
//
//  TagLib's side of a tag read: the file factory, the ranged stream, the
//  format name and the embedded art's bytes. C++, so only .mm files import
//  it.
//

#import <Foundation/Foundation.h>
#import "AudioFileFormat.h"

#include <memory>
#include <tfile.h>
#include <tiostream.h>
#include <tag.h>

NS_ASSUME_NONNULL_BEGIN

// A blocking read of `length` bytes at `offset` of the file at url, nil with
// an error on failure. The caller supplies it for a file that is not on disk.
// One example is a remote placeholder, whose bytes sit on a server.
typedef NSData *_Nullable (^VibeTagByteRangeRead)(NSURL *url, uint64_t offset, uint64_t length,
                                                  NSError *__autoreleasing _Nullable *_Nullable error);

// Replaces TagLib::FileRef, whose detection links every parser in the
// library. Same order: extension, isValid(), then magic bytes. Without
// readProperties no audio properties are parsed, which the art read never
// uses; no format's validity depends on them. With rangeRead, the file's
// rangeLength bytes are read through it instead of from disk.
class TagLibAudioFile {
public:
    explicit TagLibAudioFile(const char *path, bool readProperties = true,
                             VibeTagByteRangeRead _Nullable rangeRead = nil, uint64_t rangeLength = 0);

    bool isNull() const { return _file == nullptr; }
    TagLib::File *_Nullable file() const { return _file.get(); }
    TagLib::Tag *_Nullable tag() const { return _file ? _file->tag() : nullptr; }

private:
    static bool isOgg(TagLib::IOStream *stream);
    static bool hasOtherContainerSignature(TagLib::IOStream *stream);
    static std::unique_ptr<TagLib::File> openByContentAndRewind(TagLib::IOStream *stream, bool readProperties);
    static std::unique_ptr<TagLib::File> openByExtension(const char *path, TagLib::IOStream *stream,
                                                         bool readProperties);
    static std::unique_ptr<TagLib::File> openByContent(TagLib::IOStream *stream, bool readProperties);

    std::unique_ptr<TagLib::IOStream> _stream; // declared first: must outlive _file
    std::unique_ptr<TagLib::File> _file;
};

VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file);
NSData *_Nullable albumArtDataFromTagLibFile(TagLib::File *file);
// A FLAC's audio MD5 from STREAMINFO. nil for another format, and for the
// zeros an encoder writes when it computed none.
NSData *_Nullable audioMD5FromTagLibFile(TagLib::File *file);
// The bits per sample of a lossless stream: FLAC, ALAC or FLAC in MP4, PCM
// or float WAV, and AIFF. 0 for a lossy codec, which has none.
int bitsPerSampleFromTagLibFile(TagLib::File *file);

// The embedded art's bytes, read without audio properties. NO is a failed
// read: no parser took the file, or TagLib threw. YES with nil art is a file
// that carries none. Blocking.
BOOL VibeTagLibReadEmbeddedArt(NSString *path, VibeTagByteRangeRead _Nullable rangeRead, uint64_t rangeLength,
                               NSData *_Nullable __autoreleasing *_Nonnull art);

// Routes TagLib's debug output to the log. Defined only where NDEBUG is not,
// since Release's TagLib::debug() is a no-op.
void VibeInstallTagLibDebugListener(void);

NS_ASSUME_NONNULL_END
