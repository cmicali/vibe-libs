//
//  VibeAudioDigest.mm
//  vibe-libs
//
//  The audio's digest, read from the file's bytes without TagLib, so it can
//  check TagLib's write (VibeTagWriter.h). Each format's walk names the
//  bytes a tag write must never change, with the facts that decode them.
//  The digest hashes those bytes, and the match compares two files' in turn.
//  Both read with pread, never a map, so a file cut short while it is read
//  is an error, not a SIGBUS.
//

#import "VibeTagWriter.h"
#include "VibeMP4ItemNames.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <memory>
#include <new>
#include <vector>

namespace {

// A file's bytes, in memory or read through a descriptor. A read through
// the descriptor fills a window that a view points into, valid until the
// next read. A short or failed read sets failed() and views zeros, and the
// caller discards the answer.
class Bytes {
public:
    Bytes(const uint8_t *memory, uint64_t length) : n(length), _memory(memory) {}
    Bytes(int fd, uint64_t length) : n(length), _fd(fd) {}

    const uint64_t n;
    bool failed() const { return _failed; }
    bool has(uint64_t at, uint64_t length) const { return at <= n && length <= n - at; }

    // [at, at + length), which the caller has checked with has().
    const uint8_t *view(uint64_t at, uint64_t length) {
        if (_memory) return _memory + at;
        if (at >= _windowAt && at + length <= _windowAt + _windowLength) return _window.data() + (at - _windowAt);
        const uint64_t want = std::min<uint64_t>(std::max<uint64_t>(length, kWindow), n - at);
        if (_window.size() < want) _window.resize((size_t)want);
        uint64_t done = 0;
        while (done < want) {
            const ssize_t count = pread(_fd, _window.data() + done, (size_t)(want - done), (off_t)(at + done));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            done += (uint64_t)count;
        }
        if (done < want) {
            _failed = true;
            std::fill(_window.begin() + (ptrdiff_t)done, _window.begin() + (ptrdiff_t)want, 0);
        }
        _windowAt = at;
        _windowLength = want;
        return _window.data();
    }

    bool is(uint64_t at, const char *text) {
        const size_t length = strlen(text);
        return has(at, length) && memcmp(view(at, length), text, length) == 0;
    }
    uint8_t u8(uint64_t at) { return *view(at, 1); }
    uint32_t be32(uint64_t at) {
        const uint8_t *b = view(at, 4);
        return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
    }
    uint64_t be64(uint64_t at) { return (uint64_t)be32(at) << 32 | be32(at + 4); }
    uint32_t le32(uint64_t at) {
        const uint8_t *b = view(at, 4);
        return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
    }
    uint64_t le64(uint64_t at) { return (uint64_t)le32(at) | (uint64_t)le32(at + 4) << 32; }
    std::vector<uint8_t> copy(uint64_t at, uint64_t length) {
        const uint8_t *b = view(at, length);
        return std::vector<uint8_t>(b, b + length);
    }

private:
    static constexpr uint64_t kWindow = 64 * 1024;
    const uint8_t *_memory = nullptr;
    int _fd = -1;
    std::vector<uint8_t> _window;
    uint64_t _windowAt = 0, _windowLength = 0;
    bool _failed = false;
};

// Where a format's walk sends the audio, in order: runs of the file, and
// the small values the walk adds itself.
class Sink {
public:
    virtual ~Sink() = default;
    virtual void file(uint64_t at, uint64_t length) = 0;
    virtual void bytes(const void *bytes, uint64_t length) = 0;
    void text(const char *text) { bytes(text, strlen(text)); }
    void u64(uint64_t value) { bytes(&value, sizeof value); }
};

class Digest : public Sink {
public:
    explicit Digest(Bytes &f) : _f(f) { CC_SHA256_Init(&_context); }
    void file(uint64_t at, uint64_t length) override {
        while (length > 0) {
            const uint64_t take = std::min<uint64_t>(length, 1 << 20);
            hash(_f.view(at, take), take);
            at += take;
            length -= take;
        }
    }
    void bytes(const void *bytes, uint64_t length) override { hash(bytes, length); }
    NSData *finish() {
        uint8_t out[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(out, &_context);
        return [NSData dataWithBytes:out length:sizeof out];
    }

private:
    void hash(const void *bytes, uint64_t length) { CC_SHA256_Update(&_context, bytes, (CC_LONG)length); }
    Bytes &_f;
    CC_SHA256_CTX _context;
};

// The audio as a list of spans: runs of the file, and the walk's own values
// kept in `owned`. Touching runs merge, so an MP3, FLAC, WAV, or AIFF is a
// few spans, an MP4 two a chunk, and an Ogg three a page.
class Recorder : public Sink {
public:
    struct Span {
        uint64_t at, length;
        bool owned;
    };
    void file(uint64_t at, uint64_t length) override { push(at, length, false); }
    void bytes(const void *bytes, uint64_t length) override {
        const uint64_t at = owned.size();
        owned.insert(owned.end(), (const uint8_t *)bytes, (const uint8_t *)bytes + length);
        push(at, length, true);
    }
    std::vector<Span> spans;
    std::vector<uint8_t> owned;
    uint64_t total = 0;

private:
    void push(uint64_t at, uint64_t length, bool isOwned) {
        if (length == 0) return;
        total += length;
        if (!spans.empty() && spans.back().owned == isOwned && spans.back().at + spans.back().length == at) {
            spans.back().length += length;
        }
        else {
            spans.push_back({at, length, isOwned});
        }
    }
};

// Past every ID3v2 tag at `at`, or `at`.
uint64_t SkipID3v2(Bytes &f, uint64_t at) {
    while (f.has(at, 10) && f.is(at, "ID3")) {
        const uint8_t *h = f.view(at, 10);
        const uint64_t size = (uint64_t)(h[6] & 0x7F) << 21 | (uint64_t)(h[7] & 0x7F) << 14
                | (uint64_t)(h[8] & 0x7F) << 7 | (h[9] & 0x7F);
        const uint64_t whole = 10 + size + ((h[5] & 0x10) ? 10 : 0);
        if (!f.has(at, whole)) break;
        at += whole;
    }
    return at;
}

// The end before the tags MPEG and FLAC files carry at their end: ID3v1,
// then Lyrics3v2 or APE.
uint64_t TrimTrailingTags(Bytes &f, uint64_t start, uint64_t end) {
    if (end - start >= 128 && f.is(end - 128, "TAG")) end -= 128;
    for (int pass = 0; pass < 2; pass++) {
        if (end - start >= 32 && f.is(end - 32, "APETAGEX")) {
            const uint64_t size = f.le32(end - 32 + 12);
            const uint64_t whole = size + ((f.le32(end - 32 + 20) & 0x80000000u) ? 32 : 0);
            if (whole <= end - start) end -= whole;
        }
        if (end - start >= 15 && f.is(end - 9, "LYRICS200")) {
            uint64_t size = 0;
            bool digits = true;
            const uint8_t *b = f.view(end - 15, 6);
            for (int i = 0; i < 6; i++) {
                if (b[i] < '0' || b[i] > '9') digits = false;
                else size = size * 10 + (b[i] - '0');
            }
            if (digits && size + 15 <= end - start) end -= size + 15;
        }
    }
    return end;
}

bool WalkMPEG(Bytes &f, Sink &d) {
    const uint64_t start = SkipID3v2(f, 0);
    const uint64_t end = TrimTrailingTags(f, start, f.n);
    if (start >= end || !f.has(start, 2) || f.u8(start) != 0xFF || (f.u8(start + 1) & 0xE0) != 0xE0) return false;
    d.text("MPEG");
    d.file(start, end - start);
    return true;
}

bool WalkFLAC(Bytes &f, Sink &d) {
    uint64_t at = SkipID3v2(f, 0);
    if (!f.is(at, "fLaC")) return false;
    at += 4;
    bool streamInfo = false, last = false;
    d.text("FLAC");
    while (!last) {
        if (!f.has(at, 4)) return false;
        const uint8_t *h = f.view(at, 4);
        last = (h[0] & 0x80) != 0;
        const uint8_t type = h[0] & 0x7F;
        const uint64_t length = (uint64_t)h[1] << 16 | (uint64_t)h[2] << 8 | h[3];
        if (!f.has(at + 4, length)) return false;
        if (type == 0) {
            d.file(at + 4, length);
            streamInfo = true;
        }
        at += 4 + length;
    }
    const uint64_t end = TrimTrailingTags(f, at, f.n);
    d.file(at, end - at);
    return streamInfo;
}

// TRAP: a plain RIFF data chunk of size 0, or of 0xFFFFFFFF, which a writer
// that never finished leaves, holds no audio to check, so it is no audio.
bool WalkRIFF(Bytes &f, Sink &d) {
    const bool rf64 = f.is(0, "RF64") || f.is(0, "BW64");
    uint64_t dataSize64 = 0;
    bool format = false, data = false;
    d.text("WAVE");
    for (uint64_t at = 12; f.has(at, 8);) {
        uint64_t size = f.le32(at + 4);
        if (f.is(at, "ds64") && f.has(at + 8, 16)) dataSize64 = f.le64(at + 16);
        const bool isData = f.is(at, "data");
        if (isData && !rf64 && (size == 0 || size == 0xFFFFFFFFu)) return false;
        if (rf64 && isData && size == 0xFFFFFFFFu) size = dataSize64;
        const uint64_t body = at + 8;
        const uint64_t take = std::min<uint64_t>(size, f.n - body);
        if (f.is(at, "fmt ")) {
            d.text("fmt ");
            d.file(body, take);
            format = true;
        }
        else if (isData) {
            d.text("data");
            d.file(body, take);
            data = true;
        }
        if (size > f.n - body) break;
        at = body + size + (size & 1);
    }
    return format && data;
}

bool WalkAIFF(Bytes &f, Sink &d) {
    bool common = false, sound = false;
    d.text("AIFF");
    for (uint64_t at = 12; f.has(at, 8);) {
        const uint64_t size = f.be32(at + 4);
        const uint64_t body = at + 8;
        const uint64_t take = std::min<uint64_t>(size, f.n - body);
        if (f.is(at, "COMM")) {
            d.text("COMM");
            d.file(body, take);
            common = true;
        }
        else if (f.is(at, "SSND")) {
            d.text("SSND");
            d.file(body, take);
            sound = true;
        }
        if (size > f.n - body) break;
        at = body + size + (size & 1);
    }
    return common && sound;
}

#pragma mark - MP4

struct Atom {
    uint64_t body = 0, end = 0;
    bool found = false;
};

// The first child named `type` in [from, to).
Atom FindAtom(Bytes &f, uint64_t from, uint64_t to, const char *type) {
    for (uint64_t at = from; at + 8 <= to && f.has(at, 8);) {
        uint64_t size = f.be32(at);
        uint64_t header = 8;
        if (size == 1) {
            if (!f.has(at, 16)) break;
            size = f.be64(at + 8);
            header = 16;
        }
        else if (size == 0) {
            size = to - at;
        }
        if (size < header || size > to - at) break;
        if (memcmp(f.view(at + 4, 4), type, 4) == 0) return {at + header, at + size, true};
        at += size;
    }
    return {};
}

// Every child named `type` in [from, to).
std::vector<Atom> FindAtoms(Bytes &f, uint64_t from, uint64_t to, const char *type) {
    std::vector<Atom> atoms;
    for (uint64_t at = from; at < to;) {
        Atom atom = FindAtom(f, at, to, type);
        if (!atom.found) break;
        atoms.push_back(atom);
        at = atom.end;
    }
    return atoms;
}

uint32_t BE32(const std::vector<uint8_t> &b, uint64_t at) {
    return (uint32_t)b[at] << 24 | (uint32_t)b[at + 1] << 16 | (uint32_t)b[at + 2] << 8 | b[at + 3];
}

// A sound track's samples, chunk by chunk, where its sample table says
// they lie. So a rewritten chunk offset that misses its bytes changes it.
// TRAP: a track with no samples, as a fragmented MP4's is, is no audio.
bool WalkTrack(Bytes &f, const Atom &trak, Sink &d) {
    const Atom mdia = FindAtom(f, trak.body, trak.end, "mdia");
    const Atom hdlr = mdia.found ? FindAtom(f, mdia.body, mdia.end, "hdlr") : Atom();
    if (!hdlr.found || hdlr.end - hdlr.body < 12 || !f.is(hdlr.body + 8, "soun")) return false;
    const Atom minf = FindAtom(f, mdia.body, mdia.end, "minf");
    const Atom stbl = minf.found ? FindAtom(f, minf.body, minf.end, "stbl") : Atom();
    if (!stbl.found) return false;
    const Atom stsd = FindAtom(f, stbl.body, stbl.end, "stsd");
    const Atom stszAtom = FindAtom(f, stbl.body, stbl.end, "stsz");
    const Atom stscAtom = FindAtom(f, stbl.body, stbl.end, "stsc");
    Atom stcoAtom = FindAtom(f, stbl.body, stbl.end, "stco");
    const bool wide = !stcoAtom.found;
    if (wide) stcoAtom = FindAtom(f, stbl.body, stbl.end, "co64");
    if (!stsd.found || !stszAtom.found || !stscAtom.found || !stcoAtom.found) return false;
    if (stszAtom.end - stszAtom.body < 12 || stscAtom.end - stscAtom.body < 8 || stcoAtom.end - stcoAtom.body < 8) {
        return false;
    }
    // The tables, read once, since the walk reads them in turn.
    const std::vector<uint8_t> stsz = f.copy(stszAtom.body, stszAtom.end - stszAtom.body);
    const std::vector<uint8_t> stsc = f.copy(stscAtom.body, stscAtom.end - stscAtom.body);
    const std::vector<uint8_t> stco = f.copy(stcoAtom.body, stcoAtom.end - stcoAtom.body);

    const uint32_t fixedSize = BE32(stsz, 4);
    const uint64_t samples = BE32(stsz, 8);
    if (fixedSize == 0 && (stsz.size() - 12) / 4 < samples) return false;
    const uint64_t runs = BE32(stsc, 4);
    if ((stsc.size() - 8) / 12 < runs) return false;
    const uint64_t chunks = BE32(stco, 4);
    if ((stco.size() - 8) / (wide ? 8 : 4) < chunks) return false;

    d.text("stsd");
    d.file(stsd.body, stsd.end - stsd.body);
    uint64_t sample = 0;
    for (uint64_t run = 0; run < runs; run++) {
        const uint64_t entry = 8 + run * 12;
        const uint64_t first = BE32(stsc, entry);
        const uint64_t perChunk = BE32(stsc, entry + 4);
        const uint64_t next = run + 1 < runs ? BE32(stsc, entry + 12) : chunks + 1;
        if (first == 0 || next < first) return false;
        for (uint64_t chunk = first; chunk < next && chunk <= chunks; chunk++) {
            const uint64_t offset = wide ? (uint64_t)BE32(stco, 8 + (chunk - 1) * 8) << 32 | BE32(stco, 12 + (chunk - 1) * 8)
                                         : BE32(stco, 8 + (chunk - 1) * 4);
            uint64_t length = 0;
            for (uint64_t i = 0; i < perChunk && sample < samples; i++, sample++) {
                length += fixedSize ? fixedSize : BE32(stsz, 12 + sample * 4);
            }
            if (!f.has(offset, length)) return false;
            d.u64(length);
            d.file(offset, length);
        }
    }
    return samples > 0 && sample == samples;
}

bool WalkMP4(Bytes &f, Sink &d) {
    const Atom moov = FindAtom(f, 0, f.n, "moov");
    if (!moov.found) return false;
    d.text("MP4");
    bool any = false;
    for (const Atom &trak : FindAtoms(f, moov.body, moov.end, "trak")) {
        any = WalkTrack(f, trak, d) || any;
    }
    return any;
}

#pragma mark - Ogg

// The identification packet, Vorbis's setup packet, and every page after
// the headers with its flags, granule, and body. A page's number and CRC
// change when TagLib repaginates the comment, so they are left out.
bool WalkOgg(Bytes &f, Sink &d) {
    std::vector<std::vector<uint8_t>> headers;
    std::vector<uint8_t> packet;
    size_t headerCount = 0;  // known once the first packet is
    uint32_t serial = 0;
    bool first = true;
    d.text("OGG");
    for (uint64_t at = 0; at < f.n;) {
        if (!f.has(at, 27) || !f.is(at, "OggS")) return false;
        const uint8_t flags = f.u8(at + 5);
        const uint64_t granule = f.le64(at + 6);
        const uint32_t pageSerial = f.le32(at + 14);
        const uint8_t segments = f.u8(at + 26);
        if (!f.has(at + 27, segments)) return false;
        uint8_t lacing[255];
        memcpy(lacing, f.view(at + 27, segments), segments);
        uint64_t length = 0;
        for (int i = 0; i < segments; i++) length += lacing[i];
        uint64_t body = at + 27 + segments;
        if (!f.has(body, length)) return false;
        if (first) {
            serial = pageSerial;
            first = false;
        }
        int segment = 0;
        if (pageSerial == serial && (headerCount == 0 || headers.size() < headerCount)) {
            for (; segment < segments && (headerCount == 0 || headers.size() < headerCount); segment++) {
                const uint8_t *b = f.view(body, lacing[segment]);
                packet.insert(packet.end(), b, b + lacing[segment]);
                body += lacing[segment];
                if (lacing[segment] < 255) {
                    headers.push_back(packet);
                    packet.clear();
                    if (headers.size() == 1) {
                        const std::vector<uint8_t> &id = headers[0];
                        if (id.size() >= 7 && memcmp(id.data(), "\x01vorbis", 7) == 0) headerCount = 3;
                        else if (id.size() >= 8 && memcmp(id.data(), "OpusHead", 8) == 0) headerCount = 2;
                        else return false;
                    }
                }
            }
            if (segment == segments) {
                at = body;
                continue;
            }
        }
        uint64_t rest = 0;
        for (int i = segment; i < segments; i++) rest += lacing[i];
        d.u64(pageSerial);
        d.bytes(&flags, 1);
        d.u64(granule);
        d.file(body, rest);
        at = body + rest;
    }
    if (headerCount == 0 || headers.size() < headerCount) return false;
    d.bytes(headers[0].data(), headers[0].size());
    if (headerCount == 3) d.bytes(headers[2].data(), headers[2].size());
    return true;
}

#pragma mark - WavPack, Monkey's Audio, and DSF

// Each block, from the first byte to the tags at the end: a 32-byte header
// whose size at byte 4 counts what follows its first 8 bytes. Bytes after
// the last block, before the tags, go in too, so nothing a write could
// touch is left out. A block that passes the tags is no audio. The
// correction file of a hybrid file is another file, never read here.
bool WalkWavPack(Bytes &f, Sink &d) {
    const uint64_t end = TrimTrailingTags(f, 0, f.n);
    d.text("WVPK");
    uint64_t at = 0;
    bool any = false;
    while (f.has(at, 32) && at + 32 <= end && f.is(at, "wvpk")) {
        const uint64_t size = (uint64_t)f.le32(at + 4) + 8;
        if (size < 32 || size > end - at) return false;
        d.file(at, size);
        at += size;
        any = true;
    }
    d.file(at, end - at);
    return any;
}

// The descriptor, header, seek table, the WAV header it keeps, the frames,
// and the WAV's terminating bytes, from "MAC " to the tags at the end. A
// file from version 3.98 on states those lengths, which must fit before the
// tags. An ID3v2 tag before it, which TagLib never writes, goes in too.
bool WalkMonkeysAudio(Bytes &f, Sink &d) {
    const uint64_t start = SkipID3v2(f, 0);
    const uint64_t end = TrimTrailingTags(f, start, f.n);
    if (!f.has(start, 8)) return false;
    const uint32_t version = f.le32(start + 4) & 0xFFFF;
    if (version >= 3980) {
        if (!f.has(start, 36)) return false;
        uint64_t stated = (uint64_t)f.le32(start + 28) << 32;
        for (uint64_t field = 8; field <= 32; field += 4) {
            if (field != 28) stated += f.le32(start + field);
        }
        if (stated > end - start) return false;
    }
    d.text("APE");
    d.file(0, end);
    return true;
}

// The fmt chunk and the data chunk, each whole. The header's file size and
// tag pointer change when the tag does, so they are left out.
bool WalkDSF(Bytes &f, Sink &d) {
    if (!f.has(0, 40) || f.le64(4) != 28 || !f.is(28, "fmt ")) return false;
    const uint64_t format = f.le64(32);
    if (format < 12 || !f.has(28, format) || !f.has(28 + format, 12) || !f.is(28 + format, "data")) return false;
    const uint64_t data = 28 + format;
    const uint64_t size = f.le64(data + 4);
    if (size < 12 || !f.has(data, size)) return false;
    d.text("DSF");
    d.file(28, format);
    d.file(data, size);
    return true;
}

// Sends the file's audio to the sink, as its format's walk finds it.
bool WalkAudio(Bytes &f, Sink &sink) {
    const uint64_t afterID3 = SkipID3v2(f, 0);
    if (f.is(0, "wvpk")) return WalkWavPack(f, sink);
    if (f.is(afterID3, "MAC ") || f.is(afterID3, "MACF")) return WalkMonkeysAudio(f, sink);
    if (f.is(0, "DSD ")) return WalkDSF(f, sink);
    if (f.is(afterID3, "fLaC")) return WalkFLAC(f, sink);
    if (f.is(0, "OggS")) return WalkOgg(f, sink);
    if ((f.is(0, "RIFF") || f.is(0, "RF64") || f.is(0, "BW64")) && f.is(8, "WAVE")) return WalkRIFF(f, sink);
    if (f.is(0, "FORM") && (f.is(8, "AIFF") || f.is(8, "AIFC"))) return WalkAIFF(f, sink);
    if (f.is(4, "ftyp")) return WalkMP4(f, sink);
    return WalkMPEG(f, sink);
}

#pragma mark - Files

BOOL Fail(NSError *__autoreleasing *error, VibeTagWriteError code, NSString *path, NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:VibeTagWriteErrorDomain code:code
                                 userInfo:@{NSLocalizedDescriptionKey: reason, NSFilePathErrorKey: path}];
    }
    return NO;
}

// A file held open for reading, with what fstat said at the open, so a
// change while it is read shows.
class OpenFile {
public:
    explicit OpenFile(NSString *path) : _path(path) {
        _fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (_fd < 0) {
            _openError = errno;
        }
        else if (fstat(_fd, &_opened) != 0) {
            _openError = errno;
            close(_fd);
            _fd = -1;
        }
    }
    ~OpenFile() {
        if (_fd >= 0) close(_fd);
    }
    OpenFile(const OpenFile &) = delete;
    OpenFile &operator=(const OpenFile &) = delete;

    bool isOpen() const { return _fd >= 0; }
    int fd() const { return _fd; }
    int openError() const { return _openError; }
    uint64_t size() const { return (uint64_t)_opened.st_size; }
    NSString *path() const { return _path; }
    bool isSameFile(const OpenFile &other) const {
        return _opened.st_dev == other._opened.st_dev && _opened.st_ino == other._opened.st_ino;
    }
    // Whether the file's size and modification time are as at the open.
    bool unchanged() const {
        struct stat now;
        return fstat(_fd, &now) == 0 && now.st_size == _opened.st_size
                && now.st_mtimespec.tv_sec == _opened.st_mtimespec.tv_sec
                && now.st_mtimespec.tv_nsec == _opened.st_mtimespec.tv_nsec;
    }

private:
    NSString *_path;
    int _fd = -1;
    int _openError = 0;
    struct stat _opened {};
};

BOOL OpenFailed(const OpenFile &file, NSError *__autoreleasing *error) {
    return Fail(error, VibeTagWriteErrorOpenFailed, file.path(),
                [NSString stringWithFormat:@"The file could not be opened: %s", strerror(file.openError())]);
}

BOOL Changed(const OpenFile &file, NSError *__autoreleasing *error) {
    return Fail(error, VibeTagWriteErrorReadFailed, file.path(),
                @"The file could not be read whole, or changed while it was read");
}

// One file's walk, with its read failures and changes.
BOOL Walk(OpenFile &file, Bytes &bytes, Sink &sink, NSError *__autoreleasing *error) {
    const bool found = WalkAudio(bytes, sink);
    if (bytes.failed() || !file.unchanged()) return Changed(file, error);
    if (!found) return Fail(error, VibeTagWriteErrorNoParser, file.path(), @"The file's audio could not be found");
    return YES;
}

// A stretch of a recorded stream: the walk's own bytes, or the file's read
// into `buffer`. false when the read came back short.
bool Stretch(const OpenFile &file, const Recorder &recorder, const Recorder::Span &span, uint64_t offset,
             uint64_t length, uint8_t *buffer, const uint8_t **out) {
    if (span.owned) {
        *out = recorder.owned.data() + span.at + offset;
        return true;
    }
    uint64_t done = 0;
    while (done < length) {
        const ssize_t count = pread(file.fd(), buffer + done, (size_t)(length - done),
                                    (off_t)(span.at + offset + done));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        done += (uint64_t)count;
    }
    *out = buffer;
    return true;
}

BOOL Differs(NSString *pathA, NSString *pathB, uint64_t at, NSError *__autoreleasing *error) {
    if (error) {
        NSString *reason = [NSString stringWithFormat:@"The audio differs from byte %llu of its stream",
                                                      (unsigned long long)at];
        *error = [NSError errorWithDomain:VibeTagWriteErrorDomain code:VibeTagWriteErrorAudioDiffers
                                 userInfo:@{NSLocalizedDescriptionKey: reason, NSFilePathErrorKey: pathB,
                                            @"VibeOtherFilePath": pathA}];
    }
    return NO;
}

constexpr uint64_t kCompareBuffer = 1 << 20;

BOOL Matches(NSString *pathA, NSString *pathB, NSError *__autoreleasing *error) {
    OpenFile a(pathA), b(pathB);
    if (!a.isOpen()) return OpenFailed(a, error);
    if (!b.isOpen()) return OpenFailed(b, error);
    if (a.isSameFile(b)) return Fail(error, VibeTagWriteErrorSameFile, pathB, @"Both paths name one file");
    // Each byte is read once, so caching it would only push out what the
    // app reads.
    fcntl(a.fd(), F_NOCACHE, 1);
    fcntl(b.fd(), F_NOCACHE, 1);
    Bytes bytesA(a.fd(), a.size()), bytesB(b.fd(), b.size());
    Recorder spansA, spansB;
    if (!Walk(a, bytesA, spansA, error) || !Walk(b, bytesB, spansB, error)) return NO;
    // Streams of two lengths differ, so a cut tail costs no read.
    if (spansA.total != spansB.total) return Differs(pathA, pathB, std::min(spansA.total, spansB.total), error);
    // Uninitialized, and no larger than the audio: each byte is read in
    // before it is compared, and zeroing 2 MiB cost a small file's match
    // most of its time.
    const uint64_t bufferSize = std::max<uint64_t>(1, std::min(kCompareBuffer, spansA.total));
    std::unique_ptr<uint8_t[]> bufferA(new uint8_t[bufferSize]), bufferB(new uint8_t[bufferSize]);
    size_t i = 0, j = 0;
    uint64_t inA = 0, inB = 0, at = 0;
    while (i < spansA.spans.size() && j < spansB.spans.size()) {
        const Recorder::Span &spanA = spansA.spans[i], &spanB = spansB.spans[j];
        const uint64_t take = std::min({spanA.length - inA, spanB.length - inB, bufferSize});
        const uint8_t *pa = nullptr, *pb = nullptr;
        if (!Stretch(a, spansA, spanA, inA, take, bufferA.get(), &pa)) return Changed(a, error);
        if (!Stretch(b, spansB, spanB, inB, take, bufferB.get(), &pb)) return Changed(b, error);
        if (memcmp(pa, pb, (size_t)take) != 0) {
            uint64_t k = 0;
            while (pa[k] == pb[k]) k++;
            return Differs(pathA, pathB, at + k, error);
        }
        at += take;
        inA += take;
        inB += take;
        if (inA == spanA.length) {
            i++;
            inA = 0;
        }
        if (inB == spanB.length) {
            j++;
            inB = 0;
        }
    }
    if (!a.unchanged()) return Changed(a, error);
    if (!b.unchanged()) return Changed(b, error);
    return YES;
}

NSData *DigestOf(NSString *path, NSError *__autoreleasing *error) {
    OpenFile file(path);
    if (!file.isOpen()) {
        OpenFailed(file, error);
        return nil;
    }
    Bytes bytes(file.fd(), file.size());
    Digest digest(bytes);
    if (!Walk(file, bytes, digest, error)) return nil;
    return digest.finish();
}

} // namespace

bool VibeMP4ItemNames(const uint8_t *memory, uint64_t length, std::vector<std::string> *names) {
    Bytes f(memory, length);
    names->clear();
    if (!f.is(4, "ftyp")) return false;
    const Atom moov = FindAtom(f, 0, f.n, "moov");
    if (!moov.found) return false;
    const Atom udta = FindAtom(f, moov.body, moov.end, "udta");
    const Atom meta = udta.found ? FindAtom(f, udta.body, udta.end, "meta") : Atom();
    // meta is a full box: four bytes of version and flags before its children.
    const Atom ilst = meta.found && meta.end - meta.body >= 4 ? FindAtom(f, meta.body + 4, meta.end, "ilst") : Atom();
    if (!ilst.found) return true;
    for (uint64_t at = ilst.body; at + 8 <= ilst.end;) {
        const uint64_t size = f.be32(at);
        if (size < 8 || size > ilst.end - at) {
            names->push_back("(damaged)");
            break;
        }
        std::string name((const char *)f.view(at + 4, 4), 4);
        if (name == "----") {
            // The mean and name atoms carry four bytes of version and flags.
            const Atom mean = FindAtom(f, at + 8, at + size, "mean");
            const Atom label = FindAtom(f, at + 8, at + size, "name");
            if (mean.found && label.found && mean.end - mean.body >= 4 && label.end - label.body >= 4) {
                const uint64_t meanLength = mean.end - mean.body - 4, labelLength = label.end - label.body - 4;
                name += ":" + std::string((const char *)f.view(mean.body + 4, meanLength), meanLength) + ":"
                        + std::string((const char *)f.view(label.body + 4, labelLength), labelLength);
            }
        }
        names->push_back(name);
        at += size;
    }
    return true;
}

bool VibeMP4RateIsUnkept(const uint8_t *memory, uint64_t length) {
    Bytes f(memory, length);
    if (!f.is(4, "ftyp")) return false;
    const Atom moov = FindAtom(f, 0, f.n, "moov");
    const Atom udta = moov.found ? FindAtom(f, moov.body, moov.end, "udta") : Atom();
    const Atom meta = udta.found ? FindAtom(f, udta.body, udta.end, "meta") : Atom();
    const Atom ilst = meta.found && meta.end - meta.body >= 4 ? FindAtom(f, meta.body + 4, meta.end, "ilst") : Atom();
    const Atom rate = ilst.found ? FindAtom(f, ilst.body, ilst.end, "rate") : Atom();
    const Atom data = rate.found ? FindAtom(f, rate.body, rate.end, "data") : Atom();
    // A data atom: its type in four bytes, its locale in four, then the
    // value. Type 1 is text; any other of a length but 2 is unkept.
    if (!data.found || data.end - data.body < 8 || f.be32(data.body) == 1) return false;
    return data.end - data.body - 8 != 2;
}

// Each is a barrier: an allocation that fails is an error, not an abort.
NSData *VibeTagLibAudioDigest(NSString *path, NSError *__autoreleasing *error) {
    try {
        return DigestOf(path, error);
    }
    catch (const std::bad_alloc &) {
        Fail(error, VibeTagWriteErrorReadFailed, path, @"The digest ran out of memory");
        return nil;
    }
}

BOOL VibeTagLibAudioMatches(NSString *pathA, NSString *pathB, NSError *__autoreleasing *error) {
    try {
        return Matches(pathA, pathB, error);
    }
    catch (const std::bad_alloc &) {
        return Fail(error, VibeTagWriteErrorReadFailed, pathB, @"The match ran out of memory");
    }
}
