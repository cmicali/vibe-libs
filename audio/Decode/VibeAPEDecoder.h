//
//  VibeAPEDecoder.h
//  vibe-libs
//
//  Monkey's Audio's decode (third_party/monkeys_audio) behind a C surface.
//  The SDK is C++, and its headers define BOOL, TRUE, and Windows' types, so
//  only VibeAPEDecoder.cpp includes them. The decoder reads through the
//  caller's read function, never a file of its own.
//

#ifndef VibeAPEDecoder_h
#define VibeAPEDecoder_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeAPEDecoder VibeAPEDecoder;

// Reads up to `count` bytes at `position` into `buffer`, and returns the
// bytes read: short only at the file's end. -1 for a read that failed or
// was lost, which reads nothing.
typedef int64_t (*VibeAPEReadFunction)(void *user, int64_t position, void *buffer, int64_t count);

typedef struct {
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t bitsPerSample;    // 8, 16, 24, or 32
    bool isFloat;              // 32-bit float samples
    uint32_t blocksPerFrame;   // the audio frames in one of the file's frames
    uint32_t version;          // the file's version × 1000: 3990 for 3.99
    uint32_t compressionLevel; // 1000 (Fast) to 5000 (Insane)
    uint32_t channelMask;      // the source WAV's extensible mask, or 0
    int64_t length;            // in audio frames
} VibeAPEFacts;

// The SDK's refusals the open adds, beside its own error codes.
enum {
    VibeAPEErrorUnsupportedVersion = 1014, // the SDK's APE_ERROR_UNSUPPORTED_FILE_VERSION
    VibeAPEErrorFrameTooLarge = 90001,     // a frame larger than any encoder writes
    VibeAPEErrorUnsupportedDepth = 90002,  // a sample width the SDK does not decode
};

// Opens the file whose `size` bytes `read` reads. Reads only the head: any
// ID3v2 tags, the descriptor, the header, the seek table, and the source
// WAV's header. NULL when the file is refused, with the reason in `*error`.
VibeAPEDecoder *VibeAPEDecoderOpen(VibeAPEReadFunction read, void *user, int64_t size, int *error);
void VibeAPEDecoderClose(VibeAPEDecoder *decoder);
VibeAPEFacts VibeAPEDecoderFacts(const VibeAPEDecoder *decoder);

// The audio frame the next read delivers.
int64_t VibeAPEDecoderPosition(const VibeAPEDecoder *decoder);

// Decodes up to `frames` audio frames as float32: a channel to each plane,
// or all interleaved in planes[0]. Returns the frames delivered, short only
// at the end of the audio or of the file's bytes. `*failed` is set when a
// read failed. The frames before it are still delivered, and the decoder
// then delivers nothing until a seek. A frame the decoder finds damaged
// plays as silence, and the decode goes on from the next one.
int64_t VibeAPEDecoderRead(VibeAPEDecoder *decoder, float *const *planes, bool interleaved, int64_t frames, bool *failed);

// Moves to `frame`, clamped to the audio. Restarts the decode at the file's
// frame that holds it, decoding up to it, so it also recovers from a failed
// read. false when a read failed.
bool VibeAPEDecoderSeek(VibeAPEDecoder *decoder, int64_t frame);

#ifdef __cplusplus
}
#endif

#endif /* VibeAPEDecoder_h */
