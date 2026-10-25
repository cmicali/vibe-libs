//
//  Waveform.mm
//
//  Summarizes a second of a 1 kHz tone at half scale, fed in blocks as a
//  decode would. Reads its peaks and level back, round-trips it through the
//  archive and through the cache entry an app files, and draws it 64 pixels
//  wide as a coverage mask. Writes the tone as a WAV, loads it into a summary
//  through the waveform loader, and reads its length and peaks back. Roots a
//  waveform cache of its own, with an observer of its own on the decode, and
//  loads the tone through it. Once the load says its entry is filed, a
//  cache-only lookup hits at once. A second load is a hit that decodes
//  nothing, which the cache's seam reports. A CUE window of the tone then
//  loads through the seam twice, and its second load is a hit too.
//

#import <Foundation/Foundation.h>
#import "AudioWaveform.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioWaveformLoader.h"
#import "AudioWaveformObserver.h"
#import "ConsumerTrack.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include "WaveformRaster.hpp"
#include "WaveformSummary.hpp"

extern "C" BOOL ConsumerWaveformHolds(void);
extern "C" BOOL ConsumerLoadsAWaveform(void);
extern "C" BOOL ConsumerHitsTheWaveformCache(void);

BOOL ConsumerWaveformHolds(void) {
    const double rate = 44100;
    const size_t frames = 44100;
    std::vector<float> tone(frames);
    for (size_t i = 0; i < frames; i++) {
        tone[i] = float(0.5 * std::sin(2 * M_PI * 1000 * double(i) / rate));
    }
    wavecore::SummaryBuilder builder(true, int64_t(frames), rate);
    for (size_t at = 0; at < frames; at += 4096) {
        builder.append(tone.data() + at, std::min<size_t>(4096, frames - at));
    }
    std::unique_ptr<wavecore::Summary> summary = builder.finish(true);
    wavecore::Column whole = summary->column(0, double(frames));
    if (std::fabs(whole.hi - 0.5f) > 0.002f || std::fabs(whole.lo + 0.5f) > 0.002f
            || std::fabs(whole.loudest - 0.5f / std::sqrt(2.0f)) > 0.01f) {
        fprintf(stderr, "consumer: the tone reads %.4f to %.4f, level %.4f\n", whole.lo, whole.hi, whole.loudest);
        return NO;
    }
    std::vector<uint8_t> bytes = summary->encode();
    std::unique_ptr<wavecore::Summary> restored = wavecore::Summary::decode(bytes.data(), bytes.size());
    wavecore::Column back = restored ? restored->column(0, double(frames)) : wavecore::Column();
    if (!restored || back.lo != whole.lo || back.hi != whole.hi) {
        fprintf(stderr, "consumer: the archive of %zu bytes read back %.4f to %.4f\n", bytes.size(), back.lo, back.hi);
        return NO;
    }
    CodableAudioWaveform *entry = [[CodableAudioWaveform alloc] initWithWaveform:std::move(restored)];
    entry.results = @{@"tone": @1000};
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:entry requiringSecureCoding:NO error:NULL];
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:archived error:NULL];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *filed = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    if (!filed || filed.waveform->column(0, double(frames)).hi != whole.hi || ![filed.results isEqual:entry.results]) {
        fprintf(stderr, "consumer: the cache entry of %lu bytes did not read back\n", (unsigned long)archived.length);
        return NO;
    }

    // Each pixel's extent is its columns' by their shares, the two steps
    // crossfaded, drawn centred on a 32-row column.
    const int width = 64;
    const int height = 32;
    const double framesPerPixel = double(frames) / width;
    wavecore::StepWindow window = wavecore::StepWindowForPixels(summary->totalFrames(), framesPerPixel, 1, 0, width);
    std::vector<wavecore::Column> columns(window.columnCount());
    for (int p = 0; p < 2; p++) {
        const wavecore::StepPart &part = window.parts[p];
        if (part.count) {
            summary->columns(part.framesPerColumn(), part.first, part.count, columns.data() + window.offset(p));
        }
    }
    std::vector<uint32_t> pixels(size_t(width * height), 0);
    wavecore::ColumnCoverage coverage(height);
    coverage.draw(0, width, pixels.data(), width, [&](int x, auto add) {
        float extent = 0;
        for (int p = 0; p < 2; p++) {
            const wavecore::StepPart &part = window.parts[p];
            wavecore::ForEachColumnShare(x, framesPerPixel / part.framesPerColumn(), part.first, part.count,
                                         [&](size_t i, float share) {
                extent += window.weight(p) * share * columns[window.offset(p) + i].extent();
            });
        }
        add(height / 2.0 * (1 - extent), height / 2.0 * (1 + extent), 1.0f);
    });
    for (int x = 0; x < width; x++) {
        uint32_t edge = pixels[size_t(2 * width + x)];
        uint32_t centre = pixels[size_t(height / 2 * width + x)];
        if (edge != 0 || centre != 0xFFFFFFFFu) {
            fprintf(stderr, "consumer: pixel column %d draws %08x at its edge and %08x at its centre\n", x, edge, centre);
            return NO;
        }
    }
    return YES;
}

static const uint32_t kToneRate = 44100;
static const uint32_t kToneFrames = 44100;

// A second of the tone as a 16-bit mono WAV at path, its bytes written here.
static BOOL WriteToneWAV(NSString *path) {
    const uint32_t rate = kToneRate;
    const uint32_t frames = kToneFrames;
    NSMutableData *wav = [NSMutableData dataWithBytes:"RIFF" length:4];
    uint32_t chunk = 36 + frames * 2, fmtSize = 16, byteRate = rate * 2, dataSize = frames * 2;
    uint16_t pcm = 1, channels = 1, align = 2, bits = 16;
    [wav appendBytes:&chunk length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&pcm length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&rate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&align length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    for (uint32_t i = 0; i < frames; i++) {
        int16_t sample = int16_t(std::lround(16384 * std::sin(2 * M_PI * 1000 * double(i) / rate)));
        [wav appendBytes:&sample length:sizeof sample];
    }
    return [wav writeToFile:path atomically:YES];
}

// The tone loaded through the loader as an app's cache would load it.
BOOL ConsumerLoadsAWaveform(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    WriteToneWAV(path);
    CodableAudioWaveform *loaded = [[[AudioWaveformLoader alloc] init] load:path];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    AudioWaveform *summary = loaded.waveform;
    wavecore::Column whole = summary ? summary->column(0, double(kToneFrames)) : wavecore::Column();
    if (!summary || !summary->isComplete() || summary->totalFrames() != kToneFrames
            || summary->sampleRate() != kToneRate
            || std::fabs(whole.hi - 0.5f) > 0.002f || std::fabs(whole.lo + 0.5f) > 0.002f) {
        fprintf(stderr, "consumer: the loader read %lld frames, %.4f to %.4f\n",
                summary ? (long long)summary->totalFrames() : -1LL, whole.lo, whole.hi);
        return NO;
    }
    return YES;
}

// The observer's sink: it counts the frames a decode feeds it.
@interface ConsumerFrameSink : NSObject <AudioWaveformSink>
@end

@implementation ConsumerFrameSink {
    NSUInteger _frames;
}
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    _frames += frameCount;
}
- (id)waveformResult {
    return @(_frames);
}
@end

// The cache's deliveries, on main: the rows a complete waveform reached, and
// each result with its row. It also counts the sinks the observer made, which
// is the decodes that ran.
@interface ConsumerWaveformListener : NSObject <AudioWaveformCacheDelegate>
@property (nonatomic) NSMutableArray<id<VibePlayableItem>> *completed;
@property (nonatomic) NSMutableArray<id<VibePlayableItem>> *resultTracks;
@property (nonatomic) NSMutableArray<NSDictionary *> *results;
@property (atomic) NSUInteger sinks;
@end

@implementation ConsumerWaveformListener
- (instancetype)init {
    if ((self = [super init])) {
        _completed = [NSMutableArray array];
        _resultTracks = [NSMutableArray array];
        _results = [NSMutableArray array];
    }
    return self;
}
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded
             forTrack:(id<VibePlayableItem>)track {
    if (percentLoaded >= 1) {
        [_completed addObject:track];
    }
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache
            didLoadResults:(NSDictionary<NSString *, id> *)results
                  forTrack:(id<VibePlayableItem>)track {
    [_resultTracks addObject:track];
    [_results addObject:results];
}
@end

static BOOL Spin(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

// The tone through a cache rooted in a temporary directory. The first load
// decodes it, and the observer counts its frames. The entry is filed after
// that delivery, and the load's waiter says when. A cache-only lookup then
// hits on its first try. The second load, of a fresh row of the same file, asks the cache's seam. It
// is a hit, it hands back the filed count, and no second sink is made. Then a
// row that is a third of a second of the file loads through the seam. It
// decodes only its window, and a fresh row of that window is a hit.
BOOL ConsumerHitsTheWaveformCache(void) {
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                               NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
    NSURL *url = [directory URLByAppendingPathComponent:@"tone.wav"];
    WriteToneWAV(url.path);
    ConsumerWaveformListener *listener = [ConsumerWaveformListener new];
    AudioWaveformObserver *frames = [[AudioWaveformObserver alloc] initWithIdentifier:@"consumer.frames"
            sinkFactory:^id<AudioWaveformSink>(double sampleRate, NSRange window) {
        listener.sinks++;
        return [ConsumerFrameSink new];
    }];
    AudioWaveformCache *cache = [[AudioWaveformCache alloc]
            initWithRootPath:[directory URLByAppendingPathComponent:@"cache"].path];
    cache.delegate = listener;
    cache.analysisProvider = ^VibeWaveformAnalysis {
        return (VibeWaveformAnalysis){.bands = NO, .observers = @[frames]};
    };
    NSDictionary *counted = @{@"consumer.frames": @(kToneFrames)};

    ConsumerTrack *row = [ConsumerTrack withURL:url];
    __block NSUInteger waits = 0;
    __block BOOL written = NO;
    [cache loadWaveformForTrack:row filed:^(BOOL filed) {
        written = filed;
        waits++;
    }];
    BOOL decoded = Spin(^BOOL { return waits > 0; }) && written
            && listener.resultTracks.firstObject == row && [listener.results.firstObject isEqual:counted]
            && [listener.completed indexOfObjectIdenticalTo:row] != NSNotFound;
    cache.delegate = nil;
    __block BOOL filed = NO, looked = NO;
    if (decoded) {
        [cache cachedWaveformForTrack:[ConsumerTrack withURL:url]
                           completion:^(CodableAudioWaveform *waveform) {
            filed = waveform != nil;
            looked = YES;
        }];
        Spin(^BOOL { return looked; });
    }
    __block BOOL ok = NO, wasCached = NO;
    __block NSDictionary *results = nil;
    // Asks the cache's seam for a row. YES once it answers.
    BOOL (^ask)(ConsumerTrack *) = ^BOOL(ConsumerTrack *track) {
        __block BOOL answered = NO;
        [cache cacheWaveformForTrack:track
                          completion:^(BOOL loaded, BOOL hit, NSDictionary<NSString *, id> *entry) {
            ok = loaded;
            wasCached = hit;
            results = entry;
            answered = YES;
        }];
        return Spin(^BOOL { return answered; });
    };
    BOOL hit = filed && ask([ConsumerTrack withURL:url]) && ok && wasCached && [results isEqual:counted];
    // CD frames 25 to 50 of the second's 75.
    NSDictionary *windowCounted = @{@"consumer.frames": @(kToneFrames / 3)};
    BOOL windowDecoded = hit && ask([[ConsumerTrack alloc] initWithURL:url cueStart:25 cueEnd:50])
            && ok && !wasCached && [results isEqual:windowCounted];
    BOOL windowHit = windowDecoded && ask([[ConsumerTrack alloc] initWithURL:url cueStart:25 cueEnd:50])
            && ok && wasCached && [results isEqual:windowCounted];
    [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    if (!windowHit || listener.sinks != 2 || waits != 1) {
        fprintf(stderr, "consumer: the waveform cache decoded %d, filed %d, hit %d, decoded the window %d, "
                "then answered %d, hit %d, with %s, after %lu decodes and %lu filed waits\n", decoded, filed, hit,
                windowDecoded, ok, wasCached, results.description.UTF8String, (unsigned long)listener.sinks,
                (unsigned long)waits);
        return NO;
    }
    return YES;
}
