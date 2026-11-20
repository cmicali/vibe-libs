//
//  TailWindowMath.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The bytes at a file's end its open reads, with room, for a stream to fetch
// ahead of its download (a placeholder store's tail window); 0 for none. Every
// open that reads past its head reads one region at the end (measured,
// docs/future/streaming-any-source.md). CoreAudio's parser opens an MP3 the
// MPEG open refuses. Its ID3v1 check reads 4–128 bytes, and an APE footer a
// few KB more. dr_mp3's open reads none. A FLAC with no length or an Ogg
// Vorbis file reads 64 KB. 128 KB is twice the largest. A container of chunks reads further.
// Its open walks every chunk header to the end, so the window must reach the
// last one. In an MP4 that is the moov, which grows with the length: 4 bytes
// per 1024-sample AAC frame,
// ~10 KB a minute (61 KB at 6 minutes, 608 KB at 60), against 960 KB a minute
// of 128 kbps audio. A 32nd of the file then holds the index of any AAC at
// 43 kbps or more. In an AIFF, a WAV, a W64, or a CAF it is any chunk after
// the audio, most often a tag with its cover (235 KB on a measured AIFF).
// dr_wav's open of a WAV or W64 stops at the data chunk, as dr_mp3's of MP3
// in a WAV does. Any other file dr_wav refuses goes to CoreAudio's parser,
// which walks to the end.
// The floor is about twice that, and room for a short track's moov with its
// cover. The cap is a two-hour mix's 1.2 MB with a quarter's headroom,
// reached from 48 MB. A longer index-last M4A, or a larger chunk on a shorter
// file, waits for its download. A file no bigger than twice its window takes
// none: a download from its start reaches the tail as soon.
// A WavPack file that states its length reads nothing at its end. One that
// never stated it, as an encoder writing to a pipe leaves it, reads its last
// 1 MB at open to find the last block (libwavpack's seek_eof_information).
// Its window is that, with room for a header that straddles it. A larger APE
// tag after the audio sends libwavpack 2 MB further back, and waits for the
// download.
static inline uint64_t VibeAudioFileTailWindowBytes(NSString *extension, uint64_t size) {
    static const uint64_t kSmall = 128 * 1024, kChunkedFloor = 512 * 1024, kChunkedCap = 1536 * 1024;
    static const uint64_t kWavPack = 1024 * 1024 + 64 * 1024;
    NSString *lowered = extension.lowercaseString;
    BOOL chunked = [@[@"m4a", @"m4b", @"m4r", @"mp4", @"qta", @"aif", @"aiff", @"wav", @"wave", @"bwf", @"w64", @"caf",
                      @"aifc", @"afc"] containsObject:lowered];
    uint64_t window = chunked ? MIN(kChunkedCap, MAX(kChunkedFloor, size / 32))
            : [lowered isEqualToString:@"wv"] ? kWavPack : kSmall;
    return size > 2 * window ? window : 0;
}

NS_ASSUME_NONNULL_END
