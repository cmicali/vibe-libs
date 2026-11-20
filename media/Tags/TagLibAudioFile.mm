//
//  TagLibAudioFile.mm
//  vibe-libs
//

#import "TagLibAudioFile.h"
#import "NSString+CPPStrings.h"
#import "VibeMacros.h"
#import "VibeTagFields.h"
#include "VibeCheckedFileStream.h"

#include <algorithm>
#include <map>
#include <mutex>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <tfilestream.h>
#include <mpegfile.h>
#include <mpegproperties.h>
#include <mp4file.h>
#include <mp4properties.h>
#include <flacfile.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>
#include <popularimeterframe.h>
#include <aifffile.h>
#include <wavfile.h>
#include <vorbisfile.h>
#include <opusfile.h>
#include <wavpackfile.h>
#include <apetag.h>
#include <tpicturetype.h>
#include <apefile.h>
#include <apeproperties.h>
#include <dsffile.h>
#include <tdebuglistener.h>
#include <tagutils.h>
#include <tpropertymap.h>
#include <infotag.h>
#include <utf8-cpp.core.h>

namespace {

#if !defined(NDEBUG)

// TagLib's listener writes to std::cerr unsynchronized, so two workers race
// on the stream (TSan). The fix lives here, outside TagLib's copy, so a
// re-copy of TagLib cannot drop it.
// Release never gets here: NDEBUG makes TagLib::debug() a no-op.
class VibeTagLibDebugListener : public TagLib::DebugListener {
public:
    void printMessage(const TagLib::String &message) override {
        NSString *text = @(message.toCString(true));
        LogWarn(@"%@", [text stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
};

#endif

// A file read through the caller's byte-range reader. The parse fetches the
// blocks TagLib reads instead of the whole file. A remote reader's server must
// honor ranges to avoid skipped bytes. Fetched in aligned blocks, one request per run of missing blocks, cached for
// the stream's life. TRAP: a failed fetch THROWS. The caller's try around
// its reads turns that into a failed parse. Returning short would let TagLib
// build a tag from bytes that were never read.
class VibeRangedStream : public TagLib::IOStream {
public:
    VibeRangedStream(NSURL *url, VibeTagByteRangeRead read, TagLib::offset_t length)
        : _url(url), _read(read), _length(length), _name(url.path.UTF8String ?: "") {}

    ~VibeRangedStream() override {
        if (_requests > 0) {
            LogInfo(@"Remote tag read %@: %u requests, %llu KB",
                    _url.lastPathComponent, _requests, _bytesFetched / 1024);
        }
    }

    TagLib::FileName name() const override { return _name.c_str(); }

    TagLib::ByteVector readBlock(size_t length) override {
        if (_position >= _length || length == 0) {
            return TagLib::ByteVector();
        }
        length = (size_t)MIN((TagLib::offset_t)length, _length - _position);
        fetchRange(_position, length);
        TagLib::ByteVector result;
        result.resize((unsigned int)length);
        TagLib::offset_t at = _position;
        size_t filled = 0;
        while (filled < length) {
            TagLib::offset_t block = at / kBlockSize;
            const TagLib::ByteVector &bytes = _blocks.at(block);
            size_t within = (size_t)(at - block * kBlockSize);
            size_t take = MIN(length - filled, (size_t)bytes.size() - within);
            ::memcpy(result.data() + filled, bytes.data() + within, take);
            filled += take;
            at += take;
        }
        _position += length;
        return result;
    }

    void writeBlock(const TagLib::ByteVector &) override {}
    void insert(const TagLib::ByteVector &, TagLib::offset_t, size_t) override {}
    void removeBlock(TagLib::offset_t, size_t) override {}
    bool readOnly() const override { return true; }
    bool isOpen() const override { return true; }

    void seek(TagLib::offset_t offset, Position p) override {
        TagLib::offset_t base = p == Beginning ? 0 : (p == Current ? _position : _length);
        _position = MAX((TagLib::offset_t)0, base + offset);
    }

    TagLib::offset_t tell() const override { return _position; }
    TagLib::offset_t length() override { return _length; }
    void truncate(TagLib::offset_t) override {}

private:
    static constexpr TagLib::offset_t kBlockSize = 64 * 1024;
    // Fetch the first 384 KiB together to avoid another request for nearby art.
    static constexpr TagLib::offset_t kHeadBlocks = 6;

    // One request from the first missing block to the last, so a tag read
    // in one readBlock is one round trip.
    void fetchRange(TagLib::offset_t start, size_t length) {
        TagLib::offset_t first = start / kBlockSize;
        TagLib::offset_t last = (start + (TagLib::offset_t)length - 1) / kBlockSize;
        while (first <= last && _blocks.count(first)) first++;
        while (last >= first && _blocks.count(last)) last--;
        if (first > last) {
            return;
        }
        if (first == 0) {
            last = MAX(last, MIN(kHeadBlocks, (_length + kBlockSize - 1) / kBlockSize) - 1);
        }
        TagLib::offset_t from = first * kBlockSize;
        TagLib::offset_t to = MIN((last + 1) * kBlockSize, _length);
        NSError *error = nil;
        NSData *data = _read(_url, (uint64_t)from, (uint64_t)(to - from), &error);
        _requests++;
        if (!data || (TagLib::offset_t)data.length < to - from) {
            throw std::runtime_error(std::string("remote read failed: ")
                    + (error.localizedDescription.UTF8String ?: "short read"));
        }
        _bytesFetched += data.length;
        for (TagLib::offset_t block = first; block <= last; block++) {
            TagLib::offset_t at = block * kBlockSize - from;
            TagLib::offset_t size = MIN(kBlockSize, to - block * kBlockSize);
            _blocks[block] = TagLib::ByteVector((const char *)data.bytes + at, (unsigned int)size);
        }
    }

    NSURL *_url;
    VibeTagByteRangeRead _read;
    TagLib::offset_t _length;
    std::string _name;
    TagLib::offset_t _position = 0;
    std::map<TagLib::offset_t, TagLib::ByteVector> _blocks;
    unsigned _requests = 0;
    uint64_t _bytesFetched = 0;
};

// RIFF INFO text has no declared charset in most files. TagLib 2.3.2 reads it
// as UTF-8 and answers an empty string for any other bytes, so Latin-1 or
// Windows-1252 text from Windows tools reads as "". This reads UTF-8 when the
// bytes are valid UTF-8, and Latin-1, the RIFF default, otherwise.
// The bytes each INFO value was read from, while a VibeInfoEncodingScope
// lives on this thread.
struct VibeInfoOriginals {
    std::vector<std::pair<TagLib::String, TagLib::ByteVector>> values;
};
thread_local VibeInfoOriginals *tVibeInfoOriginals = nullptr;

class VibeInfoStringHandler : public TagLib::RIFF::Info::StringHandler {
public:
    TagLib::String parse(const TagLib::ByteVector &data) const override {
        TagLib::String text = utf8::is_valid(data.begin(), data.end()) ? TagLib::String(data, TagLib::String::UTF8)
                                                                      : TagLib::String(data, TagLib::String::Latin1);
        if (tVibeInfoOriginals) {
            TagLib::ByteVector bytes = data;
            while (!bytes.isEmpty() && bytes[bytes.size() - 1] == '\0') bytes.resize(bytes.size() - 1);
            tVibeInfoOriginals->values.emplace_back(text, bytes);
        }
        return text;
    }

    // A value read in this scope renders as the bytes it came from, so a
    // Latin-1 value stays Latin-1. Any other renders as UTF-8, as TagLib's.
    TagLib::ByteVector render(const TagLib::String &text) const override {
        if (tVibeInfoOriginals) {
            for (const auto &[original, bytes] : tVibeInfoOriginals->values) {
                if (original == text) return bytes;
            }
        }
        return text.data(TagLib::String::UTF8);
    }
};

// TRAP: TagLib keeps one handler for the process. It is installed once,
// before the first parse, and lives forever.
static void VibeInstallInfoStringHandler() {
    static std::once_flag once;
    std::call_once(once, [] {
        TagLib::RIFF::Info::Tag::setStringHandler(new VibeInfoStringHandler());
    });
}

} // namespace

VibeInfoEncodingScope::VibeInfoEncodingScope() : _previous(tVibeInfoOriginals) {
    tVibeInfoOriginals = new VibeInfoOriginals();
}

VibeInfoEncodingScope::~VibeInfoEncodingScope() {
    delete tVibeInfoOriginals;
    tVibeInfoOriginals = static_cast<VibeInfoOriginals *>(_previous);
}

namespace {

// The stream a parse reads: the file, or its bytes through the caller's reader.
static std::unique_ptr<TagLib::IOStream> VibeOpenTagStream(const char *path, VibeTagByteRangeRead rangeRead,
                                                           uint64_t rangeLength, bool writable) {
    if (rangeRead) {
        NSURL *url = [NSURL fileURLWithPath:@(path) isDirectory:NO];
        return std::make_unique<VibeRangedStream>(url, rangeRead, (TagLib::offset_t)rangeLength);
    }
    if (writable) {
        return std::make_unique<VibeCheckedFileStream>(path);
    }
    return std::make_unique<TagLib::FileStream>(path, true);
}

} // namespace

#if !defined(NDEBUG)

// Leaked by design: TagLib keeps the pointer.
void VibeInstallTagLibDebugListener(void) {
    TagLib::setDebugListener(new VibeTagLibDebugListener());
}

#endif

TagLibAudioFile::TagLibAudioFile(const char *path, bool readProperties, VibeTagByteRangeRead rangeRead,
                                 uint64_t rangeLength, bool writable)
    : _stream(VibeOpenTagStream(path, rangeRead, rangeLength, writable)) {
    VibeInstallInfoStringHandler();
    if (!_stream->isOpen()) {
        return;
    }
    _file = openByExtension(path, _stream.get(), readProperties);
    if (!_file || !_file->isValid()) {
        // TRAP: the refused parser leaves the stream anywhere, and RIFF reads
        // from tell(). Without the rewind a .m4a WAV parses with no tags.
        _stream->seek(0);
        _file = openByContent(_stream.get(), readProperties);
    }
    if (_file && !_file->isValid()) {
        _file = nullptr;
    }
}

// TRAP: FLAC::File takes a stream with "fLaC" anywhere near its start,
// which FLAC in Ogg carries in its first page. audio/Decode's handle refuses
// that file at the parser open (AudioFileHandle.m). So it must never parse as
// FLAC here. It is a failed parse, as its play is.
bool TagLibAudioFile::isOgg(TagLib::IOStream *stream) {
    return TagLib::Utils::readHeader(stream, 4, false).startsWith("OggS");
}

// MPEG has no signature of its own, so a file named as MPEG is checked for
// another container's, after any ID3v2 tag. FileRef's list (TagLib #1490).
bool TagLibAudioFile::hasOtherContainerSignature(TagLib::IOStream *stream) {
    static const TagLib::ByteVector asfGuid("\x30\x26\xB2\x75\x8E\x66\xCF\x11"
                                            "\xA6\xD9\x00\xAA\x00\x62\xCE\x6C", 16);
    const TagLib::ByteVector id = TagLib::Utils::readHeader(stream, 24, true);
    // A WAVE holding MPEG audio stays MPEG, which also finds tags after the RIFF data.
    if (id.startsWith("RIFF") && id.containsAt("WAVE", 8) && id.containsAt("fmt ", 12)) {
        const unsigned short format = id.toUShort(20, false);
        if (format == 0x0050 || format == 0x0055) {
            return false;
        }
    }
    return id.startsWith("RIFF") || id.startsWith("RF64") || id.startsWith("BW64") ||
           id.startsWith("FORM") || id.containsAt("ftyp", 4) || id.startsWith("fLaC") ||
           id.startsWith("OggS") || id.startsWith("\x1A\x45\xDF\xA3") || id.startsWith(asfGuid) ||
           id.startsWith("MAC ") || id.startsWith("wvpk") || id.startsWith("TTA") ||
           id.startsWith("MPCK") || id.startsWith("MP+") || id.startsWith("DSD ") ||
           id.startsWith("FRM8") || id.startsWith("ajkg");
}

// The content's parser for a file its extension misnames, or null to use the
// extension's parser. Rewound either way, as the constructor's sniff is.
std::unique_ptr<TagLib::File> TagLibAudioFile::openByContentAndRewind(TagLib::IOStream *stream,
                                                                     bool readProperties) {
    std::unique_ptr<TagLib::File> file = openByContent(stream, readProperties);
    stream->seek(0);
    return file;
}

// FileRef::detectByExtension's mapping plus wave, bwf and qta (a QuickTime
// container MP4::File parses). Of DSD's containers, only DSF is vendored. .ogg and .oga hold Vorbis or Opus, told
// apart by a cheap sniff; FLAC in Ogg has no vendored parser.
// TRAP: the MPEG, AIFF, and WAV parsers take another format's bytes as valid,
// so a misnamed file would parse with no tags. Each checks the header first,
// as APE's does, whose parser finds "MAC " anywhere in a file's first 1 KB.
std::unique_ptr<TagLib::File> TagLibAudioFile::openByExtension(const char *path, TagLib::IOStream *stream,
                                                              bool readProperties) {
    NSString *ext = [@(path) pathExtension].uppercaseString;
    if ([ext isEqualToString:@"MP3"] || [ext isEqualToString:@"MP2"] || [ext isEqualToString:@"AAC"]) {
        std::unique_ptr<TagLib::File> file;
        if (hasOtherContainerSignature(stream))
            file = openByContentAndRewind(stream, readProperties);
        if (file) return file;
        return std::make_unique<TagLib::MPEG::File>(stream, readProperties);
    }
    if ([ext isEqualToString:@"M4A"] || [ext isEqualToString:@"M4R"] || [ext isEqualToString:@"M4B"] ||
        [ext isEqualToString:@"M4P"] || [ext isEqualToString:@"MP4"] || [ext isEqualToString:@"M4V"] ||
        [ext isEqualToString:@"QTA"])
        return std::make_unique<TagLib::MP4::File>(stream, readProperties);
    if ([ext isEqualToString:@"FLAC"])
        return isOgg(stream) ? nullptr : std::make_unique<TagLib::FLAC::File>(stream, readProperties);
    if ([ext isEqualToString:@"OGG"] || [ext isEqualToString:@"OGA"])
        return TagLib::Ogg::Opus::File::isSupported(stream)
                ? std::unique_ptr<TagLib::File>(std::make_unique<TagLib::Ogg::Opus::File>(stream, readProperties))
                : std::make_unique<TagLib::Ogg::Vorbis::File>(stream, readProperties);
    if ([ext isEqualToString:@"OPUS"])
        return std::make_unique<TagLib::Ogg::Opus::File>(stream, readProperties);
    if ([ext isEqualToString:@"AIF"] || [ext isEqualToString:@"AIFF"] ||
        [ext isEqualToString:@"AFC"] || [ext isEqualToString:@"AIFC"]) {
        std::unique_ptr<TagLib::File> file;
        if (!TagLib::RIFF::AIFF::File::isSupported(stream))
            file = openByContentAndRewind(stream, readProperties);
        if (file) return file;
        return std::make_unique<TagLib::RIFF::AIFF::File>(stream, readProperties);
    }
    if ([ext isEqualToString:@"WAV"] || [ext isEqualToString:@"WAVE"] || [ext isEqualToString:@"BWF"]) {
        std::unique_ptr<TagLib::File> file;
        if (!TagLib::RIFF::WAV::File::isSupported(stream))
            file = openByContentAndRewind(stream, readProperties);
        if (file) return file;
        return std::make_unique<TagLib::RIFF::WAV::File>(stream, readProperties);
    }
    if ([ext isEqualToString:@"WV"]) {
        if (!TagLib::WavPack::File::isSupported(stream))
            return openByContentAndRewind(stream, readProperties);
        return std::make_unique<TagLib::WavPack::File>(stream, readProperties);
    }
    if ([ext isEqualToString:@"APE"]) {
        std::unique_ptr<TagLib::File> file;
        if (!TagLib::APE::File::isSupported(stream))
            file = openByContentAndRewind(stream, readProperties);
        if (file) return file;
        return std::make_unique<TagLib::APE::File>(stream, readProperties);
    }
    if ([ext isEqualToString:@"DSF"])
        return std::make_unique<TagLib::DSF::File>(stream, readProperties);
    return nullptr;
}

// FileRef::detectByContent's order. MPEG is last: its sniff takes frame
// sync bytes inside other formats for MP3.
std::unique_ptr<TagLib::File> TagLibAudioFile::openByContent(TagLib::IOStream *stream, bool readProperties) {
    if (TagLib::Ogg::Vorbis::File::isSupported(stream))
        return std::make_unique<TagLib::Ogg::Vorbis::File>(stream, readProperties);
    if (!isOgg(stream) && TagLib::FLAC::File::isSupported(stream))
        return std::make_unique<TagLib::FLAC::File>(stream, readProperties);
    if (TagLib::WavPack::File::isSupported(stream))
        return std::make_unique<TagLib::WavPack::File>(stream, readProperties);
    if (TagLib::Ogg::Opus::File::isSupported(stream))
        return std::make_unique<TagLib::Ogg::Opus::File>(stream, readProperties);
    if (TagLib::APE::File::isSupported(stream))
        return std::make_unique<TagLib::APE::File>(stream, readProperties);
    if (TagLib::MP4::File::isSupported(stream))
        return std::make_unique<TagLib::MP4::File>(stream, readProperties);
    if (TagLib::RIFF::AIFF::File::isSupported(stream))
        return std::make_unique<TagLib::RIFF::AIFF::File>(stream, readProperties);
    if (TagLib::RIFF::WAV::File::isSupported(stream))
        return std::make_unique<TagLib::RIFF::WAV::File>(stream, readProperties);
    if (TagLib::DSF::File::isSupported(stream))
        return std::make_unique<TagLib::DSF::File>(stream, readProperties);
    if (TagLib::MPEG::File::isSupported(stream))
        return std::make_unique<TagLib::MPEG::File>(stream, readProperties);
    return nullptr;
}

VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file) {
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
        // .mp2 and .aac open as MPEG::File too; the header tells them apart.
        if (auto props = mpeg->audioProperties()) {
            if (props->isADTS()) return VibeAudioFileFormatAAC;
            if (props->layer() == 2) return VibeAudioFileFormatMP2;
        }
        return VibeAudioFileFormatMP3;
    }
    if (dynamic_cast<TagLib::FLAC::File*>(file)) {
        return VibeAudioFileFormatFLAC;
    }
    if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
        // The codec names the kind, whatever the container, as AudioFile's
        // read does. MP4 is left for a codec with no kind of its own.
        auto props = mp4->audioProperties();
        switch (props ? props->codec() : TagLib::MP4::Properties::Unknown) {
            case TagLib::MP4::Properties::AAC:  return VibeAudioFileFormatAAC;
            case TagLib::MP4::Properties::ALAC: return VibeAudioFileFormatALAC;
            case TagLib::MP4::Properties::FLAC: return VibeAudioFileFormatFLAC;
            default:                            break;
        }
        return VibeAudioFileFormatMP4;
    }
    if (dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
        return VibeAudioFileFormatAIFF;
    }
    if (dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
        return VibeAudioFileFormatWAV;
    }
    if (dynamic_cast<TagLib::Ogg::Vorbis::File*>(file)) {
        return VibeAudioFileFormatVorbis;
    }
    if (dynamic_cast<TagLib::Ogg::Opus::File*>(file)) {
        return VibeAudioFileFormatOpus;
    }
    if (dynamic_cast<TagLib::WavPack::File*>(file)) {
        return VibeAudioFileFormatWavPack;
    }
    if (dynamic_cast<TagLib::APE::File*>(file)) {
        return VibeAudioFileFormatMonkeysAudio;
    }
    if (dynamic_cast<TagLib::DSF::File*>(file)) {
        return VibeAudioFileFormatDSD;
    }
    return nil;
}

bool tagLibFileCarriesID3v2(TagLib::File *file) {
    return dynamic_cast<TagLib::MPEG::File *>(file) || dynamic_cast<TagLib::RIFF::WAV::File *>(file)
            || dynamic_cast<TagLib::RIFF::AIFF::File *>(file) || dynamic_cast<TagLib::DSF::File *>(file);
}

NSData *_Nullable audioMD5FromTagLibFile(TagLib::File *file) {
    auto flac = dynamic_cast<TagLib::FLAC::File *>(file);
    auto props = flac ? flac->audioProperties() : nullptr;
    if (!props) {
        return nil;
    }
    const TagLib::ByteVector md5 = props->signature();
    if (md5.size() != 16 || std::all_of(md5.begin(), md5.end(), [](char byte) { return byte == 0; })) {
        return nil;
    }
    return [[NSData alloc] initWithBytes:md5.data() length:md5.size()];
}

int bitsPerSampleFromTagLibFile(TagLib::File *file) {
    int bits = 0;
    if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        if (auto props = flac->audioProperties()) bits = props->bitsPerSample();
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        // An AAC sample entry names 16 bits, which describes no source.
        auto props = mp4->audioProperties();
        if (props && (props->codec() == TagLib::MP4::Properties::ALAC
                      || props->codec() == TagLib::MP4::Properties::FLAC)) {
            bits = props->bitsPerSample();
        }
    }
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        // PCM is 1, and IEEE float 3. Other codecs, such as ADPCM or MP3 in
        // WAV, name a coded size or none.
        auto props = wav->audioProperties();
        if (props && (props->format() == 1 || props->format() == 3)) bits = props->bitsPerSample();
    }
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        if (auto props = aiff->audioProperties()) bits = props->bitsPerSample();
    }
    else if (auto wavpack = dynamic_cast<TagLib::WavPack::File *>(file)) {
        // A hybrid file is lossless only with its correction file, another
        // file (VibeWavPackHybridBitsFromTagLibFile). DSD has 1 bit, which
        // describes no PCM depth.
        auto props = wavpack->audioProperties();
        if (props && props->isLossless() && !props->isDsd()) bits = props->bitsPerSample();
    }
    else if (auto ape = dynamic_cast<TagLib::APE::File *>(file)) {
        if (auto props = ape->audioProperties()) bits = props->bitsPerSample();
    }
    // DSD is one bit a sample. The fmt chunk's bits per sample is its bit
    // order, 1 or 8, not a depth.
    else if (dynamic_cast<TagLib::DSF::File *>(file)) {
        bits = 1;
    }
    return bits > 0 && bits <= 64 ? bits : 0;
}

// TagLib calls every WavPack file that is not lossless hybrid: a lossy file
// is a hybrid file's lossy half.
int VibeWavPackHybridBitsFromTagLibFile(TagLib::File *file) {
    auto wavpack = dynamic_cast<TagLib::WavPack::File *>(file);
    auto props = wavpack ? wavpack->audioProperties() : nullptr;
    int bits = props && !props->isLossless() && !props->isDsd() ? props->bitsPerSample() : 0;
    return bits > 0 && bits <= 64 ? bits : 0;
}

namespace {

const struct {
    TagLib::MP4::CoverArt::Format format;
    const char *mimeType;
} kMP4Formats[] = {
    {TagLib::MP4::CoverArt::JPEG, "image/jpeg"},
    {TagLib::MP4::CoverArt::PNG, "image/png"},
    {TagLib::MP4::CoverArt::GIF, "image/gif"},
    {TagLib::MP4::CoverArt::BMP, "image/bmp"},
};

void ListID3v2(TagLib::ID3v2::Tag *tag, std::vector<VibeEmbeddedPicture> *pictures) {
    if (!tag) return;
    size_t index = 0;
    // Unparsed frames come back as UnknownFrame, so only those that cast
    // count.
    for (TagLib::ID3v2::Frame *frame : tag->frameList("APIC")) {
        auto picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
        if (!picture) continue;
        if (!picture->picture().isEmpty()) {
            VibeEmbeddedPicture item;
            item.index = index;
            item.type = (int)picture->type();
            item.data = picture->picture();
            item.mimeType = picture->mimeType();
            item.description = picture->description();
            pictures->push_back(item);
        }
        index++;
    }
}

// A FLAC file's picture blocks, or a Xiph comment's METADATA_BLOCK_PICTURE.
void ListPictures(const TagLib::List<TagLib::FLAC::Picture *> &list, std::vector<VibeEmbeddedPicture> *pictures) {
    size_t index = 0;
    for (TagLib::FLAC::Picture *picture : list) {
        if (picture && !picture->data().isEmpty()) {
            VibeEmbeddedPicture item;
            item.index = index;
            item.type = (int)picture->type();
            item.data = picture->data();
            item.mimeType = picture->mimeType();
            item.description = picture->description();
            item.width = picture->width();
            item.height = picture->height();
            item.colorDepth = picture->colorDepth();
            item.colorCount = picture->numColors();
            pictures->push_back(item);
        }
        index++;
    }
}

// An APE tag's front and back covers, its two binary picture items, each
// after an optional file name. TagLib's complex properties parse them.
void ListAPE(TagLib::APE::Tag *tag, std::vector<VibeEmbeddedPicture> *pictures) {
    if (!tag) return;
    size_t index = 0;
    for (const TagLib::VariantMap &property : tag->complexProperties("PICTURE")) {
        const TagLib::ByteVector data = property.value("data").toByteVector();
        if (!data.isEmpty()) {
            VibeEmbeddedPicture item;
            item.index = index;
            item.type = TagLib::Utils::pictureTypeFromString(property.value("pictureType").toString());
            item.data = data;
            item.description = property.value("description").toString();
            pictures->push_back(item);
        }
        index++;
    }
}

void ListMP4(TagLib::MP4::Tag *tag, std::vector<VibeEmbeddedPicture> *pictures) {
    if (!tag->contains("covr")) return;
    size_t index = 0;
    for (const TagLib::MP4::CoverArt &art : tag->item("covr").toCoverArtList()) {
        if (!art.data().isEmpty()) {
            VibeEmbeddedPicture item;
            item.index = index;
            item.type = -1;
            item.data = art.data();
            item.mimeType = VibeMIMETypeOfMP4Format(art.format());
            pictures->push_back(item);
        }
        index++;
    }
}

} // namespace

TagLib::String VibeMIMETypeOfMP4Format(int format) {
    for (const auto &entry : kMP4Formats) {
        if (entry.format == format) return entry.mimeType;
    }
    return TagLib::String();
}

int VibeMP4FormatOfMIMEType(const TagLib::String &mimeType) {
    for (const auto &entry : kMP4Formats) {
        if (mimeType == entry.mimeType) return entry.format;
    }
    return TagLib::MP4::CoverArt::Unknown;
}

std::vector<VibeEmbeddedPicture> VibeEmbeddedPictures(TagLib::File *file) {
    std::vector<VibeEmbeddedPicture> pictures;
    if (tagLibFileCarriesID3v2(file)) {
        ListID3v2(VibeID3v2TagOfFile(file), &pictures);
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        ListPictures(flac->pictureList(), &pictures);
    }
    // Vorbis and Opus, both tagged with a Xiph comment.
    else if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag())) {
        ListPictures(xiph->pictureList(), &pictures);
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        ListMP4(mp4->tag(), &pictures);
    }
    else {
        ListAPE(VibeAPETagOfFile(file, false), &pictures);
    }
    return pictures;
}

TagLib::APE::Tag *_Nullable VibeAPETagOfFile(TagLib::File *file, bool create) {
    if (auto wavpack = dynamic_cast<TagLib::WavPack::File *>(file)) {
        return create || wavpack->hasAPETag() ? wavpack->APETag(create) : nullptr;
    }
    if (auto monkeys = dynamic_cast<TagLib::APE::File *>(file)) {
        return create || monkeys->hasAPETag() ? monkeys->APETag(create) : nullptr;
    }
    return nullptr;
}

TagLib::ID3v2::Tag *_Nullable VibeID3v2TagOfFile(TagLib::File *file) {
    if (auto mp3 = dynamic_cast<TagLib::MPEG::File *>(file)) {
        return mp3->hasID3v2Tag() ? mp3->ID3v2Tag(false) : nullptr;
    }
    if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        return aiff->hasID3v2Tag() ? aiff->tag() : nullptr;
    }
    if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        return wav->hasID3v2Tag() ? wav->ID3v2Tag() : nullptr;
    }
    if (auto dsf = dynamic_cast<TagLib::DSF::File *>(file)) {
        return dsf->tag();
    }
    return nullptr;
}

namespace {

// What a hostile file can make a read keep (media/Tags/AGENTS.md, Ratings).
constexpr NSUInteger kMaxRatings = 32;
constexpr unsigned int kMaxRatingEmailBytes = 256;

NSString *RatingText(const TagLib::String &string) {
    return [NSString stringWithStdString:string.stripWhiteSpace().to8Bit(true)] ?: @"";
}

} // namespace

NSDictionary<VibeTagField, NSString *> *_Nullable VibeTagRatingFields(TagLib::File *file,
                                                                      const TagLib::PropertyMap &properties) {
    NSMutableDictionary<VibeTagField, NSString *> *ratings = [NSMutableDictionary dictionary];
    auto keep = [&](NSString *name, NSString *text) {
        if (text.length > 0 && !ratings[name] && ratings.count < kMaxRatings) ratings[name] = text;
    };
    auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag()) || dynamic_cast<TagLib::FLAC::File *>(file);
    auto mp4 = dynamic_cast<TagLib::MP4::File *>(file);
    TagLib::ID3v2::Tag *id3v2 = VibeID3v2TagOfFile(file);
    // A freeform RATING reads only when the MP4 has no rate at all, whatever
    // the rate holds.
    bool hasRate = false;
    if (mp4) {
        // MP4's rate first, so it wins over a freeform RATING atom. TRAP:
        // TagLib's property map has no name for rate, so it reads nowhere
        // else. TRAP: TagLib parses a numeric rate by its first two bytes, so
        // a 4-byte integer reads as 0. A rate of 0 or less, as text or a
        // number, is none.
        const TagLib::MP4::ItemMap &items = mp4->tag()->itemMap();
        auto rate = items.find("rate");
        hasRate = rate != items.end();
        if (hasRate) {
            const TagLib::StringList text = rate->second.toStringList();
            NSString *value = text.isEmpty() ? [NSString stringWithFormat:@"%d", rate->second.toInt()]
                                             : RatingText(text.front());
            if (value.doubleValue > 0) keep(VibeTagFieldRating, value);
        }
    }
    // A WavPack or Monkey's Audio file's own tag is its APE tag, read alone,
    // never the ID3v1 tag the map may answer from.
    TagLib::APE::Tag *ape = VibeAPETagOfFile(file, false);
    // Only each format's own tag holds a rating: never an MP3's APE tag, an
    // ID3v1 tag, or an INFO tag the map may answer from, and RATING:<email>
    // only in a Xiph comment or a WavPack or Monkey's Audio file's APE tag,
    // as the writer takes them.
    const bool mapHome = xiph || mp4 || (id3v2 && !id3v2->isEmpty());
    const TagLib::PropertyMap apeProperties = ape ? ape->properties() : TagLib::PropertyMap();
    for (const auto &[key, values] : ape ? apeProperties : mapHome ? properties : TagLib::PropertyMap()) {
        const bool plain = (key == "RATING" && !hasRate) || key == "FMPS_RATING";
        const bool owned = (xiph || ape) && key.startsWith("RATING:") && key.size() > 7 &&
                           key.size() - 7 <= kMaxRatingEmailBytes;
        if ((plain || owned) && !values.isEmpty()) keep(RatingText(key), RatingText(values.front()));
    }
    if (id3v2) {
        for (TagLib::ID3v2::Frame *frame : id3v2->frameListMap().value("POPM")) {
            auto popm = dynamic_cast<TagLib::ID3v2::PopularimeterFrame *>(frame);
            const TagLib::ByteVector email = popm ? popm->email().data(TagLib::String::UTF8) : TagLib::ByteVector();
            if (!popm || popm->rating() <= 0 || email.size() > kMaxRatingEmailBytes) continue;
            // The email untrimmed, as a write compares it.
            NSString *name = [VibeTagFieldPopularimeterPrefix
                    stringByAppendingString:[NSString stringWithStdString:popm->email().to8Bit(true)] ?: @""];
            keep(name, [NSString stringWithFormat:@"%d", popm->rating()]);
        }
    }
    return ratings.count ? ratings : nil;
}

// The first front cover wins, since a 32x32 file icon can precede it.
size_t VibeShownPicture(const std::vector<VibeEmbeddedPicture> &pictures) {
    for (size_t i = 0; i < pictures.size(); i++) {
        if (pictures[i].type == 3) return i;
    }
    return pictures.empty() ? SIZE_MAX : 0;
}

NSData *albumArtDataFromTagLibFile(TagLib::File *file) {
    const std::vector<VibeEmbeddedPicture> pictures = VibeEmbeddedPictures(file);
    const size_t shown = VibeShownPicture(pictures);
    if (shown == SIZE_MAX) return nil;
    const TagLib::ByteVector &bytes = pictures[shown].data;
    return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
}

BOOL VibeTagLibReadEmbeddedArt(NSString *path, VibeTagByteRangeRead rangeRead, uint64_t rangeLength,
                               NSData *__autoreleasing *art) {
    *art = nil;
    // The parse's barrier; a throw is a failed read, not "no art".
    try {
        TagLibAudioFile fileRef(path.UTF8String, false, rangeRead, rangeLength);
        if (fileRef.isNull()) {
            return NO;
        }
        *art = albumArtDataFromTagLibFile(fileRef.file());
        return YES;
    }
    catch (const std::exception &e) {
        LogError(@"TagLib art extraction failed for %@: %s", path, e.what());
    }
    catch (...) {
        LogError(@"TagLib art extraction failed for %@", path);
    }
    return NO;
}
