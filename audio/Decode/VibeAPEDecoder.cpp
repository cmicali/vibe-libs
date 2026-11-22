//
//  VibeAPEDecoder.cpp
//  vibe-libs
//
//  Monkey's Audio's decode behind VibeAPEDecoder.h's C surface. The SDK's
//  CAPEDecompress reads a frame's bytes on the caller's thread and decodes
//  them on one worker thread of its own, a frame ahead. So every read
//  through the caller's function happens on the thread that called in.
//

#include "VibeAPEDecoder.h"

// Other authors' headers, which this piece's warnings must not fail.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "monkeys_audio/MACLib/All.h"
#include "monkeys_audio/MACLib/MACLib.h"
#include "monkeys_audio/MACLib/APEInfo.h"
#include "monkeys_audio/MACLib/APETag.h"
#pragma clang diagnostic pop

#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

using namespace APE;

namespace {

// The largest frame any encoder level writes: Insane's 16 × 73,728 audio
// frames. The SDK takes up to ten million, and sizes its buffers by it.
const int64_t kVibeAPELargestFrame = 73728 * 16;
// The most bytes one frame of PCM may take. A decoder holds three such
// buffers: its own, its worker's, and the worker's input. Insane's frame of
// 8 channels at 32 bits takes 38 MB; 32 channels would take 151 MB.
const int64_t kVibeAPELargestFrameBytes = 64 * 1024 * 1024;
// The audio frames one SDK read decodes into the scratch buffer.
const int64_t kVibeAPEChunk = 4096;

// The SDK's I/O over the caller's reads. It holds the cursor. TRAP: a read
// that fails latches, and every later one fails too until a seek clears it,
// so the decoder never sees bytes after a gap.
class VibeAPEIO final : public IAPEIO {
public:
    VibeAPEIO(VibeAPEReadFunction read, void *user, int64 size) : m_read(read), m_user(user), m_size(size) {}

    int Open(const str_utfn *, bool) override { return APE_ERROR_UNDEFINED; }
    int Close() override { return APE_ERROR_SUCCESS; }

    int Read(void *buffer, int64 count, int64 *bytesRead) override {
        if (bytesRead) {
            *bytesRead = 0;
        }
        if (m_failed || !m_read) {
            return APE_ERROR_IO_READ;
        }
        if (count <= 0 || m_position >= m_size) {
            return APE_ERROR_SUCCESS;
        }
        int64 got = m_read(m_user, m_position, buffer, std::min(count, m_size - m_position));
        if (got < 0) {
            m_failed = true;
            return APE_ERROR_IO_READ;
        }
        m_position += got;
        if (bytesRead) {
            *bytesRead = got;
        }
        return APE_ERROR_SUCCESS;
    }

    int Write(const void *, int64, int64 *) override { return APE_ERROR_IO_WRITE; }

    int Seek(int64 position, SeekMethod method) override {
        int64 base = method == SeekFileBegin ? 0 : method == SeekFileCurrent ? m_position : m_size;
        int64 target = 0;
        if (__builtin_add_overflow(base, position, &target) || target < 0) {
            return APE_ERROR_UNDEFINED;
        }
        m_position = target;
        return APE_ERROR_SUCCESS;
    }

    int Create(const str_utfn *) override { return APE_ERROR_UNDEFINED; }
    int Delete() override { return APE_ERROR_UNDEFINED; }
    int SetEOF() override { return APE_ERROR_UNDEFINED; }
    unsigned char *GetBuffer(int *bufferBytes) override {
        if (bufferBytes) {
            *bufferBytes = 0;
        }
        return APE_NULL;
    }
    int64 GetPosition() override { return m_position; }
    int64 GetSize() override { return m_size; }

    bool failed() const { return m_failed; }
    void clearFailure() { m_failed = false; }
    // Every read fails from here on, without calling the caller's function.
    void detach() { m_read = nullptr; }

private:
    VibeAPEReadFunction m_read;
    void *m_user;
    int64 m_size;
    int64 m_position = 0;
    bool m_failed = false;
};

// The extensible WAVE mask in the source WAV's header, which the file keeps
// whole. 0 for any other source, or a mask it does not state.
uint32_t VibeAPEChannelMask(IAPEDecompress *decompress) {
    int64 bytes = decompress->GetInfo(IAPEInfo::APE_INFO_WAV_HEADER_BYTES);
    if (bytes < 12 || bytes > 1024 * 1024) {
        return 0;
    }
    std::vector<unsigned char> header(static_cast<size_t>(bytes));
    if (decompress->GetInfo(IAPEInfo::APE_INFO_WAV_HEADER_DATA, APE_POINTER_TO_INT64(header.data()), bytes) != APE_ERROR_SUCCESS
            || memcmp(header.data(), "RIFF", 4) != 0 || memcmp(header.data() + 8, "WAVE", 4) != 0) {
        return 0;
    }
    auto le32 = [&](size_t at) { return static_cast<uint32_t>(header[at] | header[at + 1] << 8 | header[at + 2] << 16 | header[at + 3] << 24); };
    for (size_t at = 12; at + 8 <= header.size(); ) {
        uint32_t size = le32(at + 4);
        if (memcmp(header.data() + at, "fmt ", 4) == 0) {
            // WAVE_FORMAT_EXTENSIBLE's 40 bytes, the mask at 20.
            if (size >= 40 && at + 8 + 40 <= header.size() && (header[at + 8] | header[at + 9] << 8) == 0xFFFE) {
                return le32(at + 8 + 20);
            }
            return 0;
        }
        at += 8 + static_cast<size_t>(size) + (size & 1);
    }
    return 0;
}

// Whether the seek table has an entry for every frame, each after the one
// before and no further from it than the file is long. `*firstOutside` is
// the first frame that starts at or past the file's end, in a file cut
// short, or the frame count. TRAP: the SDK reads the table at the frame
// count, whatever size the table states, and reads a frame's byte count
// from two of its entries into 32 bits: the last frame's from the file's
// size. A short table, one whose 32-bit entries go backwards, which the SDK
// takes for a jump of 4 GB, or a frame that starts past the end, would read
// past the table or allocate a frame of gigabytes.
bool VibeAPESeekTableHolds(CAPEInfo *info, int64 size, int64 *firstOutside) {
    APE_FILE_INFO *file = reinterpret_cast<APE_FILE_INFO *>(info->GetInfo(IAPEInfo::APE_INFO_FILE_INFO));
    if (!file || file->nSeekTableElements < 0 || static_cast<uint32>(file->nSeekTableElements) < file->nTotalFrames) {
        return false;
    }
    *firstOutside = file->nTotalFrames;
    int64 previous = -1;
    for (uint32 frame = 0; frame < file->nTotalFrames; frame++) {
        int64 at = info->GetInfo(IAPEInfo::APE_INFO_SEEK_BYTE, frame);
        if (at <= previous || (previous >= 0 && at - previous > size)) {
            return false;
        }
        if (at >= size && *firstOutside == file->nTotalFrames) {
            *firstOutside = frame;
        }
        previous = at;
    }
    return true;
}

void VibeAPEDecoderCloseNow(void *decoder);

} // namespace

struct VibeAPEDecoder {
    VibeAPEIO *io = nullptr;
    IAPEDecompress *decompress = nullptr;
    VibeAPEFacts facts = {};
    int64_t blockAlign = 0;
    // The first audio frame past the file's bytes, once a frame's bytes ran
    // past its end: a file cut short. The length from the header past it is
    // never reached.
    int64_t end = INT64_MAX;
    // The frame the next read delivers, kept here. The SDK clamps a seek to
    // the last frame, and steps past a damaged frame's silence.
    int64_t position = 0;
    // Up to here, reads deliver silence: the rest of a damaged frame. The SDK
    // already waits at its end, the next frame's start.
    int64_t silenceEnd = 0;
    std::vector<unsigned char> scratch;
};

namespace {

void VibeAPEDecoderCloseNow(void *opaque) {
    VibeAPEDecoder *decoder = static_cast<VibeAPEDecoder *>(opaque);
    // The decompressor first: it joins its worker, and deletes the info and
    // the tag, which hold the I/O.
    delete decoder->decompress;
    delete decoder->io;
    delete decoder;
}

} // namespace

extern "C" VibeAPEDecoder *VibeAPEDecoderOpen(VibeAPEReadFunction read, void *user, int64_t size, int *error) {
    int code = APE_ERROR_UNDEFINED;
    VibeAPEDecoder *decoder = nullptr;
    try {
        decoder = new VibeAPEDecoder();
        decoder->io = new VibeAPEIO(read, user, size);
        // The tag is read on first use, not at the open: its size answers only
        // the last frame's bytes. So an open reads nothing at the file's end,
        // and a file still downloading opens from its head (this piece's
        // AGENTS.md). The SDK skips its ID3v1 check only for a WAV whose
        // trailing chunk is 128 bytes; this checks always. The info takes the
        // tag only when it opens.
        std::unique_ptr<CAPETag> tag(new CAPETag(decoder->io, false, true));
        std::unique_ptr<CAPEInfo> info(new CAPEInfo(&code, decoder->io, tag.get()));
        if (code == APE_ERROR_SUCCESS) {
            tag.release();
            // CreateIAPEDecompressEx2 keeps an info whose version it refuses,
            // so the version is checked first: 3.99 and older, and 4.11, as
            // its own check takes. TRAP: the SDK's float step runs on 32-bit
            // words whenever the float flag is set, whatever the width says.
            // On a 16-bit file it read twice the bytes decoded, past the
            // buffer (AudioFileHandleFuzzAPETests).
            int64 firstOutside = 0;
            int64 version = info->GetInfo(IAPEInfo::APE_INFO_FILE_VERSION);
            int64 bits = info->GetInfo(IAPEInfo::APE_INFO_BITS_PER_SAMPLE);
            int64 perFrame = info->GetInfo(IAPEInfo::APE_INFO_BLOCKS_PER_FRAME);
            bool isFloat = info->GetInfo(IAPEInfo::APE_INFO_FORMAT_FLAGS) & APE_FORMAT_FLAG_FLOATING_POINT;
            if (version > APE_FILE_VERSION_NUMBER && version != 4110) {
                code = VibeAPEErrorUnsupportedVersion;
            } else if (bits != 8 && bits != 16 && bits != 24 && bits != 32) {
                code = VibeAPEErrorUnsupportedDepth;
            } else if (isFloat && bits != 32) {
                code = VibeAPEErrorUnsupportedDepth;
            } else if (perFrame > kVibeAPELargestFrame
                    || perFrame * info->GetInfo(IAPEInfo::APE_INFO_BLOCK_ALIGN) > kVibeAPELargestFrameBytes) {
                code = VibeAPEErrorFrameTooLarge;
            } else if (!VibeAPESeekTableHolds(info.get(), size, &firstOutside)) {
                code = VibeAPEErrorBadSeekTable;
            } else {
                decoder->facts.isFloat = isFloat;
                // A file cut short: its reads end where its frames' bytes do.
                decoder->end = firstOutside * perFrame;
                // It takes the info, and deletes it with itself.
                decoder->decompress = CreateIAPEDecompressEx2(info.release(), -1, -1, &code);
            }
        }
    } catch (...) {
        code = APE_ERROR_INSUFFICIENT_MEMORY;
    }
    if (decoder && decoder->decompress && code == APE_ERROR_SUCCESS && !decoder->io->failed()) {
        IAPEDecompress *decompress = decoder->decompress;
        VibeAPEFacts &facts = decoder->facts;
        facts.sampleRate = static_cast<uint32_t>(decompress->GetInfo(IAPEInfo::APE_INFO_SAMPLE_RATE));
        facts.channels = static_cast<uint32_t>(decompress->GetInfo(IAPEInfo::APE_INFO_CHANNELS));
        facts.bitsPerSample = static_cast<uint32_t>(decompress->GetInfo(IAPEInfo::APE_INFO_BITS_PER_SAMPLE));
        facts.blocksPerFrame = static_cast<uint32_t>(decompress->GetInfo(IAPEInfo::APE_INFO_BLOCKS_PER_FRAME));
        facts.length = std::max<int64_t>(0, decompress->GetInfo(IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS));
        try {
            facts.channelMask = VibeAPEChannelMask(decompress);
            // The SDK writes a read at its own frame size into the scratch
            // buffer: the same, since the width is a whole number of bytes.
            decoder->blockAlign = decompress->GetInfo(IAPEInfo::APE_INFO_BLOCK_ALIGN);
            decoder->scratch.resize(static_cast<size_t>(kVibeAPEChunk * decoder->blockAlign));
            return decoder;
        } catch (...) {
            code = APE_ERROR_INSUFFICIENT_MEMORY;
        }
    }
    VibeAPEDecoderClose(decoder);
    if (error) {
        *error = code != APE_ERROR_SUCCESS ? code : APE_ERROR_IO_READ;
    }
    return nullptr;
}

extern "C" void VibeAPEDecoderClose(VibeAPEDecoder *decoder) {
    if (decoder) {
        VibeAPEDecoderCloseNow(decoder);
    }
}

extern "C" void VibeAPEDecoderCloseLater(VibeAPEDecoder *decoder) {
    if (!decoder) {
        return;
    }
    // Nothing the close does reads, and from here no read reaches the
    // caller, which may be gone by the time the worker is joined.
    decoder->io->detach();
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), decoder, VibeAPEDecoderCloseNow);
}

extern "C" VibeAPEFacts VibeAPEDecoderFacts(const VibeAPEDecoder *decoder) {
    return decoder->facts;
}

extern "C" int64_t VibeAPEDecoderPosition(const VibeAPEDecoder *decoder) {
    return decoder->position;
}

// The SDK's samples, interleaved, as float32: unsigned 8-bit, signed
// little-endian 16, 24, and 32-bit, or float, whatever the source's order.
// Every scale is a power of two, so the floats are exact but for 32-bit
// integers, which round to float's 24 bits.
static void VibeAPEConvert(const VibeAPEDecoder *decoder, const unsigned char *from, int64_t frames,
                           float *const *planes, bool interleaved, int64_t at) {
    const vDSP_Length count = static_cast<vDSP_Length>(frames);
    const uint32_t channels = decoder->facts.channels, bits = decoder->facts.bitsPerSample;
    if (count == 0) {
        return;
    }
    // Interleaved, one pass over every sample. Planar, one strided pass a channel.
    const uint32_t passes = interleaved ? 1 : channels;
    const vDSP_Stride stride = interleaved ? 1 : channels;
    const vDSP_Length n = interleaved ? count * channels : count;
    for (uint32_t c = 0; c < passes; c++) {
        float *to = interleaved ? planes[0] + at * channels : planes[c] + at;
        switch (bits) {
            case 8: {
                const float scale = 1.0f / 128, offset = -1.0f;
                vDSP_vfltu8(from + c, stride, to, 1, n);
                vDSP_vsmsa(to, 1, &scale, &offset, to, 1, n);
                break;
            }
            case 16: {
                const float scale = 1.0f / 32768;
                vDSP_vflt16(reinterpret_cast<const short *>(from) + c, stride, to, 1, n);
                vDSP_vsmul(to, 1, &scale, to, 1, n);
                break;
            }
            case 24: {
                const float scale = 1.0f / 8388608;
                vDSP_vflt24(reinterpret_cast<const vDSP_int24 *>(from) + c, stride, to, 1, n);
                vDSP_vsmul(to, 1, &scale, to, 1, n);
                break;
            }
            default:
                if (decoder->facts.isFloat) {
                    const float one = 1;
                    vDSP_vsmul(reinterpret_cast<const float *>(from) + c, stride, &one, to, 1, n);
                } else {
                    const float scale = 1.0f / 2147483648.0f;
                    vDSP_vflt32(reinterpret_cast<const int *>(from) + c, stride, to, 1, n);
                    vDSP_vsmul(to, 1, &scale, to, 1, n);
                }
                break;
        }
    }
}

// Silence for `frames` frames from `at`.
static void VibeAPESilence(const VibeAPEDecoder *decoder, float *const *planes, bool interleaved, int64_t at, int64_t frames) {
    const uint32_t channels = decoder->facts.channels;
    if (interleaved) {
        memset(planes[0] + at * channels, 0, static_cast<size_t>(frames) * channels * sizeof(float));
        return;
    }
    for (uint32_t c = 0; c < channels; c++) {
        memset(planes[c] + at, 0, static_cast<size_t>(frames) * sizeof(float));
    }
}

// One SDK read, of `want` frames, never past the file's frame it starts in.
// TRAP: its return code can speak for the frame after the one it delivers,
// whose bytes it reads ahead, and a damaged frame's silence runs about 64
// frames past the frame's end. Within one frame, the code says which it was.
// A C++ exception, such as an allocation that failed, is
// APE_ERROR_INSUFFICIENT_MEMORY.
static int VibeAPEGetData(VibeAPEDecoder *decoder, int64_t want, int64_t *retrieved) {
    int64 got = 0;
    int code = APE_ERROR_INSUFFICIENT_MEMORY;
    // Float processing only, playback's default. The SDK stores an AIFF's
    // samples little-endian and signed 8-bit ones unsigned, as a WAV's. Its
    // other two steps turn them back, for writing the AIFF out again.
    IAPEDecompress::APE_GET_DATA_PROCESSING processing = {true, false, false};
    try {
        code = decoder->decompress->GetData(decoder->scratch.data(), want, &got, &processing);
    } catch (...) {
        got = 0;
    }
    *retrieved = std::max<int64_t>(0, std::min<int64_t>(got, want));
    return code;
}

// Moves the SDK to `frame`. false when a read failed or the SDK threw. A
// frame with no bytes on disk, in a file cut short, ends the reads where its
// bytes do.
static bool VibeAPESeekSDK(VibeAPEDecoder *decoder, int64_t frame) {
    int code = APE_ERROR_UNDEFINED;
    try {
        code = decoder->decompress->Seek(frame);
    } catch (...) {
        return false;
    }
    if (decoder->io->failed()) {
        return false;
    }
    if (code != APE_ERROR_SUCCESS) {
        decoder->end = std::min(decoder->end, frame - frame % decoder->facts.blocksPerFrame);
    }
    return true;
}

extern "C" int64_t VibeAPEDecoderRead(VibeAPEDecoder *decoder, float *const *planes, bool interleaved, int64_t frames, bool *failed) {
    *failed = decoder->io->failed();
    const int64_t perFrame = decoder->facts.blocksPerFrame;
    int64_t got = 0;
    while (got < frames && !*failed) {
        const int64_t stop = std::min(decoder->facts.length, decoder->end);
        int64_t &position = decoder->position;
        if (position >= stop) {
            break;
        }
        if (position < decoder->silenceEnd) {
            int64_t silent = std::min(frames - got, decoder->silenceEnd - position);
            VibeAPESilence(decoder, planes, interleaved, got, silent);
            got += silent;
            position += silent;
            continue;
        }
        int64_t want = std::min({frames - got, kVibeAPEChunk, stop - position, perFrame - position % perFrame});
        int64_t retrieved = 0;
        int code = VibeAPEGetData(decoder, want, &retrieved);
        // The end of the file's frame this read was in.
        const int64_t frameEnd = position - position % perFrame + perFrame;
        if (decoder->io->failed() || code == APE_ERROR_INSUFFICIENT_MEMORY) {
            // The read that failed is the next frame's, or this one's, which
            // then delivered nothing. What came before it is good. An
            // allocation that failed is a failure too, never damage.
            VibeAPEConvert(decoder, decoder->scratch.data(), retrieved, planes, interleaved, got);
            got += retrieved;
            position += retrieved;
            *failed = true;
        } else if (code == APE_ERROR_INPUT_FILE_TOO_SMALL) {
            // The bytes ran out in the next frame, or in this one.
            VibeAPEConvert(decoder, decoder->scratch.data(), retrieved, planes, interleaved, got);
            got += retrieved;
            position += retrieved;
            decoder->end = std::min(decoder->end, retrieved > 0 ? frameEnd : position);
        } else if (code != APE_ERROR_SUCCESS) {
            // A damaged frame. The SDK fills it with its own silence, which
            // for 8-bit samples is one step below zero, and runs past the
            // frame. All of the frame is silence here, and the SDK starts
            // afresh at the next one.
            decoder->silenceEnd = std::min(stop, frameEnd);
            if (frameEnd < decoder->facts.length && !VibeAPESeekSDK(decoder, frameEnd)) {
                *failed = true;
            }
        } else if (retrieved == 0) {
            break;
        } else {
            VibeAPEConvert(decoder, decoder->scratch.data(), retrieved, planes, interleaved, got);
            got += retrieved;
            position += retrieved;
        }
    }
    return got;
}

extern "C" bool VibeAPEDecoderSeek(VibeAPEDecoder *decoder, int64_t frame) {
    int64_t target = std::min(std::max<int64_t>(0, frame), decoder->facts.length);
    // The waveform's detail pass seeks before each block it reads. A seek to
    // where the decoder is would make the SDK drop the frame it decoded ahead
    // and decode its frame again from the start: up to 1.2 million frames at
    // Insane, for each block.
    if (target == decoder->position && !decoder->io->failed()) {
        return true;
    }
    decoder->io->clearFailure();
    decoder->silenceEnd = 0;
    decoder->position = target;
    if (target >= std::min(decoder->facts.length, decoder->end)) {
        // Reads deliver nothing here. The SDK's own seek would clamp to the
        // last frame. The next seek inside the audio moves it.
        return true;
    }
    // TRAP: the SDK goes to the start of the target's frame, and the reads
    // here skip to the target. The SDK's own skip takes a damaged frame's
    // silence past the frame's end, which would move every later frame.
    const int64_t start = target - target % decoder->facts.blocksPerFrame;
    decoder->position = start;
    if (!VibeAPESeekSDK(decoder, start)) {
        return false;
    }
    if (target == start) {
        return true;
    }
    try {
        const uint32_t channels = decoder->facts.channels;
        std::vector<float> discard(static_cast<size_t>(kVibeAPEChunk) * channels);
        std::vector<float *> planes(channels);
        for (uint32_t c = 0; c < channels; c++) {
            planes[c] = discard.data() + static_cast<size_t>(c) * kVibeAPEChunk;
        }
        bool failed = false;
        while (decoder->position < target && !failed) {
            if (VibeAPEDecoderRead(decoder, planes.data(), false, std::min(kVibeAPEChunk, target - decoder->position), &failed) == 0) {
                break;
            }
        }
        if (failed) {
            return false;
        }
    } catch (...) {
        return false;
    }
    // A file cut short before the target ends there.
    decoder->position = std::max(decoder->position, target);
    return true;
}
