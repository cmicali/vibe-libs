//
//  VibeAudioDigest.mm
//  vibe-libs
//
//  The audio's digest, read from the file's bytes without TagLib, so it can
//  check TagLib's write (VibeTagWriter.h). Each format's walk takes the
//  bytes a tag write must never change, with the facts that decode them.
//  The digest hashes those bytes, and the match compares two files' in turn.
//

#import "VibeTagWriter.h"
#include "VibeMP4ItemNames.h"

#include <CommonCrypto/CommonDigest.h>
#include <string.h>
#include <algorithm>
#include <vector>

namespace {

struct Bytes {
    const uint8_t *b;
    uint64_t n;
    bool has(uint64_t at, uint64_t length) const { return at <= n && length <= n - at; }
    bool is(uint64_t at, const char *text) const {
        const size_t length = strlen(text);
        return has(at, length) && memcmp(b + at, text, length) == 0;
    }
    uint32_t be32(uint64_t at) const {
        return (uint32_t)b[at] << 24 | (uint32_t)b[at + 1] << 16 | (uint32_t)b[at + 2] << 8 | b[at + 3];
    }
    uint64_t be64(uint64_t at) const { return (uint64_t)be32(at) << 32 | be32(at + 4); }
    uint32_t le32(uint64_t at) const {
        return (uint32_t)b[at] | (uint32_t)b[at + 1] << 8 | (uint32_t)b[at + 2] << 16 | (uint32_t)b[at + 3] << 24;
    }
    uint64_t le64(uint64_t at) const { return (uint64_t)le32(at) | (uint64_t)le32(at + 4) << 32; }
};

// Where a format's walk sends the audio's bytes, in order.
class Sink {
public:
    virtual ~Sink() = default;
    virtual void add(const void *bytes, uint64_t length) = 0;
    void add(const char *text) { add(text, strlen(text)); }
    void add64(uint64_t value) { add(&value, sizeof value); }
};

class Digest : public Sink {
public:
    Digest() { CC_SHA256_Init(&_context); }
    void add(const void *bytes, uint64_t length) override {
        while (length > 0) {
            const CC_LONG take = (CC_LONG)std::min<uint64_t>(length, 1u << 30);
            CC_SHA256_Update(&_context, bytes, take);
            bytes = (const uint8_t *)bytes + take;
            length -= take;
        }
    }
    using Sink::add;
    NSData *finish() {
        uint8_t out[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(out, &_context);
        return [NSData dataWithBytes:out length:sizeof out];
    }

private:
    CC_SHA256_CTX _context;
};

// Past every ID3v2 tag at `at`, or `at`.
uint64_t SkipID3v2(const Bytes &f, uint64_t at) {
    while (f.has(at, 10) && f.is(at, "ID3")) {
        const uint64_t size = (uint64_t)(f.b[at + 6] & 0x7F) << 21 | (uint64_t)(f.b[at + 7] & 0x7F) << 14
                | (uint64_t)(f.b[at + 8] & 0x7F) << 7 | (f.b[at + 9] & 0x7F);
        const uint64_t whole = 10 + size + ((f.b[at + 5] & 0x10) ? 10 : 0);
        if (!f.has(at, whole)) break;
        at += whole;
    }
    return at;
}

// The end before the tags MPEG and FLAC files carry at their end: ID3v1,
// then Lyrics3v2 or APE.
uint64_t TrimTrailingTags(const Bytes &f, uint64_t start, uint64_t end) {
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
            for (uint64_t i = end - 15; i < end - 9; i++) {
                if (f.b[i] < '0' || f.b[i] > '9') digits = false;
                else size = size * 10 + (f.b[i] - '0');
            }
            if (digits && size + 15 <= end - start) end -= size + 15;
        }
    }
    return end;
}

bool DigestMPEG(const Bytes &f, Sink &d) {
    const uint64_t start = SkipID3v2(f, 0);
    const uint64_t end = TrimTrailingTags(f, start, f.n);
    if (start >= end || !f.has(start, 2) || f.b[start] != 0xFF || (f.b[start + 1] & 0xE0) != 0xE0) return false;
    d.add("MPEG");
    d.add(f.b + start, end - start);
    return true;
}

bool DigestFLAC(const Bytes &f, Sink &d) {
    uint64_t at = SkipID3v2(f, 0);
    if (!f.is(at, "fLaC")) return false;
    at += 4;
    bool streamInfo = false, last = false;
    d.add("FLAC");
    while (!last) {
        if (!f.has(at, 4)) return false;
        last = (f.b[at] & 0x80) != 0;
        const uint8_t type = f.b[at] & 0x7F;
        const uint64_t length = (uint64_t)f.b[at + 1] << 16 | (uint64_t)f.b[at + 2] << 8 | f.b[at + 3];
        if (!f.has(at + 4, length)) return false;
        if (type == 0) {
            d.add(f.b + at + 4, length);
            streamInfo = true;
        }
        at += 4 + length;
    }
    const uint64_t end = TrimTrailingTags(f, at, f.n);
    d.add(f.b + at, end - at);
    return streamInfo;
}

bool DigestRIFF(const Bytes &f, Sink &d) {
    const bool rf64 = f.is(0, "RF64") || f.is(0, "BW64");
    uint64_t dataSize64 = 0;
    bool format = false, data = false;
    d.add("WAVE");
    for (uint64_t at = 12; f.has(at, 8);) {
        uint64_t size = f.le32(at + 4);
        if (f.is(at, "ds64") && f.has(at + 8, 16)) dataSize64 = f.le64(at + 16);
        if (rf64 && f.is(at, "data") && size == 0xFFFFFFFFu) size = dataSize64;
        const uint64_t body = at + 8;
        const uint64_t take = std::min<uint64_t>(size, f.n - body);
        if (f.is(at, "fmt ")) {
            d.add("fmt ");
            d.add(f.b + body, take);
            format = true;
        }
        else if (f.is(at, "data")) {
            d.add("data");
            d.add(f.b + body, take);
            data = true;
        }
        if (size > f.n - body) break;
        at = body + size + (size & 1);
    }
    return format && data;
}

bool DigestAIFF(const Bytes &f, Sink &d) {
    bool common = false, sound = false;
    d.add("AIFF");
    for (uint64_t at = 12; f.has(at, 8);) {
        const uint64_t size = f.be32(at + 4);
        const uint64_t body = at + 8;
        const uint64_t take = std::min<uint64_t>(size, f.n - body);
        if (f.is(at, "COMM")) {
            d.add("COMM");
            d.add(f.b + body, take);
            common = true;
        }
        else if (f.is(at, "SSND")) {
            d.add("SSND");
            d.add(f.b + body, take);
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
Atom FindAtom(const Bytes &f, uint64_t from, uint64_t to, const char *type) {
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
        if (memcmp(f.b + at + 4, type, 4) == 0) return {at + header, at + size, true};
        at += size;
    }
    return {};
}

// Every child named `type` in [from, to).
std::vector<Atom> FindAtoms(const Bytes &f, uint64_t from, uint64_t to, const char *type) {
    std::vector<Atom> atoms;
    for (uint64_t at = from; at < to;) {
        Atom atom = FindAtom(f, at, to, type);
        if (!atom.found) break;
        atoms.push_back(atom);
        at = atom.end;
    }
    return atoms;
}

// A sound track's samples, chunk by chunk, where its sample table says
// they lie. So a rewritten chunk offset that misses its bytes changes it.
bool DigestTrack(const Bytes &f, const Atom &trak, Sink &d) {
    const Atom mdia = FindAtom(f, trak.body, trak.end, "mdia");
    const Atom hdlr = mdia.found ? FindAtom(f, mdia.body, mdia.end, "hdlr") : Atom();
    if (!hdlr.found || hdlr.end - hdlr.body < 12 || memcmp(f.b + hdlr.body + 8, "soun", 4) != 0) return false;
    const Atom minf = FindAtom(f, mdia.body, mdia.end, "minf");
    const Atom stbl = minf.found ? FindAtom(f, minf.body, minf.end, "stbl") : Atom();
    if (!stbl.found) return false;
    const Atom stsd = FindAtom(f, stbl.body, stbl.end, "stsd");
    const Atom stsz = FindAtom(f, stbl.body, stbl.end, "stsz");
    const Atom stsc = FindAtom(f, stbl.body, stbl.end, "stsc");
    Atom stco = FindAtom(f, stbl.body, stbl.end, "stco");
    const bool wide = !stco.found;
    if (wide) stco = FindAtom(f, stbl.body, stbl.end, "co64");
    if (!stsd.found || !stsz.found || !stsc.found || !stco.found) return false;
    if (stsz.end - stsz.body < 12 || stsc.end - stsc.body < 8 || stco.end - stco.body < 8) return false;

    const uint32_t fixedSize = f.be32(stsz.body + 4);
    const uint64_t samples = f.be32(stsz.body + 8);
    if (fixedSize == 0 && (stsz.end - stsz.body - 12) / 4 < samples) return false;
    const uint64_t runs = f.be32(stsc.body + 4);
    if ((stsc.end - stsc.body - 8) / 12 < runs) return false;
    const uint64_t chunks = f.be32(stco.body + 4);
    if ((stco.end - stco.body - 8) / (wide ? 8 : 4) < chunks) return false;

    d.add("stsd");
    d.add(f.b + stsd.body, stsd.end - stsd.body);
    uint64_t sample = 0;
    for (uint64_t run = 0; run < runs; run++) {
        const uint64_t entry = stsc.body + 8 + run * 12;
        const uint64_t first = f.be32(entry);
        const uint64_t perChunk = f.be32(entry + 4);
        const uint64_t next = run + 1 < runs ? f.be32(entry + 12) : chunks + 1;
        if (first == 0 || next < first) return false;
        for (uint64_t chunk = first; chunk < next && chunk <= chunks; chunk++) {
            const uint64_t offset = wide ? f.be64(stco.body + 8 + (chunk - 1) * 8) : f.be32(stco.body + 8 + (chunk - 1) * 4);
            uint64_t length = 0;
            for (uint64_t i = 0; i < perChunk && sample < samples; i++, sample++) {
                length += fixedSize ? fixedSize : f.be32(stsz.body + 12 + sample * 4);
            }
            if (!f.has(offset, length)) return false;
            d.add64(length);
            d.add(f.b + offset, length);
        }
    }
    return sample == samples;
}

bool DigestMP4(const Bytes &f, Sink &d) {
    const Atom moov = FindAtom(f, 0, f.n, "moov");
    if (!moov.found) return false;
    d.add("MP4");
    bool any = false;
    for (const Atom &trak : FindAtoms(f, moov.body, moov.end, "trak")) {
        any = DigestTrack(f, trak, d) || any;
    }
    return any;
}

#pragma mark - Ogg

// The identification packet, Vorbis's setup packet, and every page after
// the headers with its flags, granule, and body. A page's number and CRC
// change when TagLib repaginates the comment, so they are left out.
bool DigestOgg(const Bytes &f, Sink &d) {
    std::vector<std::vector<uint8_t>> headers;
    std::vector<uint8_t> packet;
    size_t headerCount = 0;  // known once the first packet is
    uint32_t serial = 0;
    bool first = true;
    d.add("OGG");
    for (uint64_t at = 0; at < f.n;) {
        if (!f.is(at, "OggS") || !f.has(at, 27)) return false;
        const uint8_t flags = f.b[at + 5];
        const uint64_t granule = f.le64(at + 6);
        const uint32_t pageSerial = f.le32(at + 14);
        const uint8_t segments = f.b[at + 26];
        if (!f.has(at + 27, segments)) return false;
        const uint8_t *lacing = f.b + at + 27;
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
                packet.insert(packet.end(), f.b + body, f.b + body + lacing[segment]);
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
        d.add64(pageSerial);
        d.add(&flags, 1);
        d.add64(granule);
        d.add(f.b + body, rest);
        at = body + rest;
    }
    if (headerCount == 0 || headers.size() < headerCount) return false;
    d.add(headers[0].data(), headers[0].size());
    if (headerCount == 3) d.add(headers[2].data(), headers[2].size());
    return true;
}

} // namespace

bool VibeMP4ItemNames(const uint8_t *bytes, uint64_t length, std::vector<std::string> *names) {
    const Bytes f{bytes, length};
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
        std::string name((const char *)f.b + at + 4, 4);
        if (name == "----") {
            // The mean and name atoms carry four bytes of version and flags.
            const Atom mean = FindAtom(f, at + 8, at + size, "mean");
            const Atom label = FindAtom(f, at + 8, at + size, "name");
            if (mean.found && label.found && mean.end - mean.body >= 4 && label.end - label.body >= 4) {
                name += ":" + std::string((const char *)f.b + mean.body + 4, mean.end - mean.body - 4) + ":"
                        + std::string((const char *)f.b + label.body + 4, label.end - label.body - 4);
            }
        }
        names->push_back(name);
        at += size;
    }
    return true;
}

namespace {

// The audio's bytes as a list of spans: runs of the mapped file, and the
// small values the walk adds itself, kept in `owned`. Adjacent runs merge,
// so an MP3, FLAC, WAV, or AIFF is a handful of spans.
class Recorder : public Sink {
public:
    Recorder(const Bytes &f) : _f(f) {}
    void add(const void *bytes, uint64_t length) override {
        if (length == 0) return;
        const uint8_t *p = (const uint8_t *)bytes;
        total += length;
        const bool mapped = p >= _f.b && length <= _f.n && (uint64_t)(p - _f.b) <= _f.n - length;
        uint64_t at;
        if (mapped) {
            at = (uint64_t)(p - _f.b);
        }
        else {
            at = owned.size();
            owned.insert(owned.end(), p, p + length);
        }
        if (!spans.empty() && spans.back().owned == !mapped && spans.back().at + spans.back().length == at) {
            spans.back().length += length;
        }
        else {
            spans.push_back({at, length, !mapped});
        }
    }
    using Sink::add;

    struct Span {
        uint64_t at, length;
        bool owned;
    };
    const uint8_t *bytes(const Span &span) const { return span.owned ? owned.data() + span.at : _f.b + span.at; }

    std::vector<Span> spans;
    std::vector<uint8_t> owned;
    uint64_t total = 0;

private:
    const Bytes &_f;
};

NSData *MapFile(NSString *path, NSError *__autoreleasing *error) {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
    if (!data && error) {
        *error = [NSError errorWithDomain:VibeTagWriteErrorDomain code:VibeTagWriteErrorOpenFailed
                                 userInfo:@{NSLocalizedDescriptionKey: @"The file could not be read",
                                            NSFilePathErrorKey: path, NSUnderlyingErrorKey: readError}];
    }
    return data;
}

// Sends the file's audio to the sink, as its format's walk finds it.
bool WalkAudio(const Bytes &f, Sink &sink) {
    const uint64_t afterID3 = SkipID3v2(f, 0);
    if (f.is(afterID3, "fLaC")) return DigestFLAC(f, sink);
    if (f.is(0, "OggS")) return DigestOgg(f, sink);
    if ((f.is(0, "RIFF") || f.is(0, "RF64") || f.is(0, "BW64")) && f.is(8, "WAVE")) return DigestRIFF(f, sink);
    if (f.is(0, "FORM") && (f.is(8, "AIFF") || f.is(8, "AIFC"))) return DigestAIFF(f, sink);
    if (f.is(4, "ftyp")) return DigestMP4(f, sink);
    return DigestMPEG(f, sink);
}

BOOL NotFound(NSString *path, NSError *__autoreleasing *error) {
    if (error) {
        *error = [NSError errorWithDomain:VibeTagWriteErrorDomain code:VibeTagWriteErrorNoParser
                                 userInfo:@{NSLocalizedDescriptionKey: @"The file's audio could not be found",
                                            NSFilePathErrorKey: path}];
    }
    return NO;
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

} // namespace

NSData *VibeTagLibAudioDigest(NSString *path, NSError *__autoreleasing *error) {
    NSData *data = MapFile(path, error);
    if (!data) return nil;
    const Bytes f{(const uint8_t *)data.bytes, data.length};
    Digest digest;
    if (!WalkAudio(f, digest)) {
        NotFound(path, error);
        return nil;
    }
    return digest.finish();
}

BOOL VibeTagLibAudioMatches(NSString *pathA, NSString *pathB, NSError *__autoreleasing *error) {
    NSData *dataA = MapFile(pathA, error);
    if (!dataA) return NO;
    NSData *dataB = MapFile(pathB, error);
    if (!dataB) return NO;
    const Bytes a{(const uint8_t *)dataA.bytes, dataA.length}, b{(const uint8_t *)dataB.bytes, dataB.length};
    Recorder spansA(a), spansB(b);
    if (!WalkAudio(a, spansA)) return NotFound(pathA, error);
    if (!WalkAudio(b, spansB)) return NotFound(pathB, error);
    // The digest hashes the same stream, so equal streams are equal digests.
    // Streams of two lengths differ, so a cut tail costs no read.
    if (spansA.total != spansB.total) {
        return Differs(pathA, pathB, std::min(spansA.total, spansB.total), error);
    }
    size_t i = 0, j = 0;
    uint64_t inA = 0, inB = 0, at = 0;
    while (i < spansA.spans.size() && j < spansB.spans.size()) {
        const auto &spanA = spansA.spans[i], &spanB = spansB.spans[j];
        const uint64_t take = std::min(spanA.length - inA, spanB.length - inB);
        const uint8_t *pa = spansA.bytes(spanA) + inA, *pb = spansB.bytes(spanB) + inB;
        // memcmp in pieces, so the first difference is found near where it is.
        for (uint64_t done = 0; done < take;) {
            const size_t piece = (size_t)std::min<uint64_t>(take - done, 1 << 20);
            if (memcmp(pa + done, pb + done, piece) != 0) return Differs(pathA, pathB, at + done, error);
            done += piece;
        }
        at += take;
        inA += take;
        inB += take;
        if (inA == spanA.length) i++, inA = 0;
        if (inB == spanB.length) j++, inB = 0;
    }
    return YES;
}
