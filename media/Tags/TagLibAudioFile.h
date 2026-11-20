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
#include <vector>
#include <tbytevector.h>
#include <tfile.h>
#include <tiostream.h>
#include <tag.h>

namespace TagLib::ID3v2 {
class Tag;
}

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
// rangeLength bytes are read through it instead of from disk. With writable,
// the file opens for writing through a VibeCheckedFileStream, or read-only
// when it cannot (VibeTagWriter.h).
class TagLibAudioFile {
public:
    explicit TagLibAudioFile(const char *path, bool readProperties = true,
                             VibeTagByteRangeRead _Nullable rangeRead = nil, uint64_t rangeLength = 0,
                             bool writable = false);

    bool isNull() const { return _file == nullptr; }
    bool streamIsOpen() const { return _stream->isOpen(); }
    bool streamIsReadOnly() const { return _stream->readOnly(); }
    TagLib::IOStream *stream() const { return _stream.get(); }
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

// While one lives on this thread, a RIFF INFO value a parse reads renders
// back as the bytes it was read from, Latin-1 or UTF-8. A new value renders
// as UTF-8. Made before the parse, by the writer.
class VibeInfoEncodingScope {
public:
    VibeInfoEncodingScope();
    ~VibeInfoEncodingScope();
    VibeInfoEncodingScope(const VibeInfoEncodingScope &) = delete;
    VibeInfoEncodingScope &operator=(const VibeInfoEncodingScope &) = delete;

private:
    void *_previous;
};

// The kind of the file's audio (AudioFileFormat.h).
VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file);
// Whether the file's tag is ID3v2: MPEG, WAV, and AIFF. A WAV may carry RIFF
// INFO instead.
bool tagLibFileCarriesID3v2(TagLib::File *file);
// The bytes of the picture VibeShownPicture() names, or nil.
NSData *_Nullable albumArtDataFromTagLibFile(TagLib::File *file);

// One embedded picture with bytes, as its tag stores it.
struct VibeEmbeddedPicture {
    // Its place in the format's own list, empty pictures counted: the ID3v2
    // tag's APIC frames, the picture blocks, or the covr entries.
    size_t index = 0;
    // ID3v2's numbering, which FLAC and Xiph share. -1 in MP4.
    int type = 0;
    TagLib::ByteVector data;
    // MP4's is its typed format's, or empty.
    TagLib::String mimeType;
    TagLib::String description;
    // FLAC's and Xiph's own fields.
    int width = 0, height = 0, colorDepth = 0, colorCount = 0;
};

// Every picture with bytes, in the file's order: an MPEG, WAV, or AIFF's
// ID3v2 tag's, a FLAC's picture blocks, a Xiph comment's, or an MP4's covr
// entries. A picture with no bytes is never shown, taken, or listed.
std::vector<VibeEmbeddedPicture> VibeEmbeddedPictures(TagLib::File *file);
// The picture the art read shows: the first front cover, else the first.
// SIZE_MAX for none.
size_t VibeShownPicture(const std::vector<VibeEmbeddedPicture> &pictures);
// One table, both ways: an MP4 cover's typed format and its MIME type. A
// MIME type MP4 does not type answers MP4::CoverArt::Unknown, the untyped.
TagLib::String VibeMIMETypeOfMP4Format(int format);
int VibeMP4FormatOfMIMEType(const TagLib::String &mimeType);
// A FLAC's audio MD5 from STREAMINFO. nil for another format, and for the
// zeros an encoder writes when it computed none.
NSData *_Nullable audioMD5FromTagLibFile(TagLib::File *file);
// The bits per sample of a lossless stream: FLAC, ALAC or FLAC in MP4, PCM
// or float WAV, and AIFF. 0 for a lossy codec, which has none.
int bitsPerSampleFromTagLibFile(TagLib::File *file);

// Every rating the file holds, by its VibeTagFields.h key, each its first
// value as stored: an ID3v2 tag's POPM frames whose rating is not 0, the
// first of each email, an MP4's rate atom as RATING, and any RATING,
// RATING:<email>, or FMPS_RATING the property map holds. nil for none
// (media/Tags/AGENTS.md, Ratings).
NSDictionary<NSString *, NSString *> *_Nullable VibeTagRatingFields(TagLib::File *file);
// The ID3v2 tag of an MPEG, WAV, or AIFF file, or null for none.
TagLib::ID3v2::Tag *_Nullable VibeID3v2TagOfFile(TagLib::File *file);

// The embedded art's bytes, read without audio properties. NO is a failed
// read: no parser took the file, or TagLib threw. YES with nil art is a file
// that carries none. Blocking.
BOOL VibeTagLibReadEmbeddedArt(NSString *path, VibeTagByteRangeRead _Nullable rangeRead, uint64_t rangeLength,
                               NSData *_Nullable __autoreleasing *_Nonnull art);

// Routes TagLib's debug output to the log. Defined only where NDEBUG is not,
// since Release's TagLib::debug() is a no-op.
void VibeInstallTagLibDebugListener(void);

NS_ASSUME_NONNULL_END
