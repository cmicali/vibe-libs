//
//  AudioWaveformStoreTests.mm
//  vibe-libs
//
//  The waveform cache's store: the import of the PINCache store before it,
//  a lookup during the import, an import that a quit cut short, and an entry
//  of another format. Each test roots its stores in a temporary directory,
//  and decodes WAV files it writes.
//

#import <XCTest/XCTest.h>

#import "AudioFileFixtures.h"
#import "AudioWaveform.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioWaveformCacheInternal.h"
#import "PINCache+VibeAudioCache.h"
#import "VibeTestTrack.h"
#import "VibeWaveformStore.h"
#import "WaveformLoadingTestSupport.h"

#include <cmath>

// The cache's complete deliveries.
@interface StoreTestRecorder : NSObject <AudioWaveformCacheDelegate>
@property (nonatomic) NSMutableArray<CodableAudioWaveform *> *complete;
@end

@implementation StoreTestRecorder

- (instancetype)init {
    if ((self = [super init])) {
        _complete = [NSMutableArray array];
    }
    return self;
}

- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded forTrack:(id<VibePlayableItem>)track {
    if (percentLoaded >= 1) {
        [_complete addObject:waveform];
    }
}

@end

@interface AudioWaveformStoreTests : XCTestCase
@end

@implementation AudioWaveformStoreTests {
    NSURL *_directory;
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)tearDown {
    [VibeWaveformStore holdImportsForTesting:NO];
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    [super tearDown];
}

- (NSString *)rootNamed:(NSString *)name {
    return [_directory URLByAppendingPathComponent:name].path;
}

- (NSString *)legacyUnder:(NSString *)root {
    return [root stringByAppendingPathComponent:
            [@"com.pinterest.PINDiskCache." stringByAppendingString:VibeWaveformStore.legacyName]];
}

// Whether the seam's lookup-or-decode found the entry filed, so no decode ran.
static BOOL WasCached(AudioWaveformCache *cache, id<VibePlayableItem> track) {
    __block BOOL answered = NO, cached = NO;
    [cache cacheWaveformForTrack:track completion:^(BOOL ok, BOOL wasCached, NSDictionary *results) {
        cached = ok && wasCached;
        answered = YES;
    }];
    WaveformSpinUntil(^BOOL { return answered; });
    return cached;
}

// A second of 16-bit stereo noise, a different one for each seed.
- (VibeTestTrack *)trackNamed:(NSString *)name seed:(uint32_t)seed {
    uint32_t frames = 44100;
    NSMutableData *samples = [NSMutableData dataWithLength:(NSUInteger)frames * 4];
    int16_t *out = (int16_t *)samples.mutableBytes;
    uint32_t state = seed;
    for (NSUInteger i = 0; i < (NSUInteger)frames * 2; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = (int16_t)(sin((double)i * 0.00071) * 16000.0 + (double)(int16_t)(state >> 16) * 0.4);
    }
    NSURL *url = [_directory URLByAppendingPathComponent:name];
    XCTAssertNotNil(VibeWriteWAV(url, samples, 44100, 2, 16, frames * 4));
    return [VibeTestTrack withURL:url];
}

// Decodes each track through a cache of its own, then files the waveforms in
// a PINCache store under root as the release before this one did. Returns
// each entry's bytes on disk by its key.
- (NSDictionary<NSString *, NSData *> *)legacyStoreUnder:(NSString *)root withTracks:(NSArray<VibeTestTrack *> *)tracks {
    StoreTestRecorder *recorder = [StoreTestRecorder new];
    AudioWaveformCache *decoder = [[AudioWaveformCache alloc] initWithRootPath:[self rootNamed:@"decoder"]];
    decoder.delegate = recorder;
    PINCache *legacy = [PINCache audioCacheWithName:VibeWaveformStore.legacyName rootPath:root];
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    for (VibeTestTrack *track in tracks) {
        NSUInteger before = recorder.complete.count;
        [decoder loadWaveformForTrack:track];
        XCTAssertTrue(WaveformSpinUntil(^BOOL { return recorder.complete.count > before; }));
        NSString *key = VibeWaveformEntryKey(track);
        [legacy.diskCache setObject:recorder.complete.lastObject forKey:key];
        NSData *bytes = [NSData dataWithContentsOfURL:[legacy.diskCache fileURLForKey:key]];
        XCTAssertGreaterThan(bytes.length, 0u);
        files[key] = bytes;
    }
    return files;
}

// CH19: every entry of the old store reads back the same, with no decode,
// and the old store, the ones before it, and one a quit left renamed aside
// are gone at the end. A folder of another kind stays.
- (void)testTheImportBringsEveryEntryOverAndRemovesTheOldStores {
    NSString *root = [self rootNamed:@"caches"];
    NSArray<VibeTestTrack *> *tracks = @[[self trackNamed:@"a.wav" seed:1], [self trackNamed:@"b.wav" seed:2],
                                         [self trackNamed:@"c.wav" seed:3]];
    NSDictionary<NSString *, NSData *> *files = [self legacyStoreUnder:root withTracks:tracks];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *older = [root stringByAppendingPathComponent:@"com.pinterest.PINDiskCache.audio_waveform_cache_v6"];
    NSString *left = [[self legacyUnder:root] stringByAppendingString:@" removed 0F0E5B4C-0000-4000-8000-000000000000"];
    NSString *other = [root stringByAppendingPathComponent:@"com.pinterest.PINDiskCache.audio_track_metadata_v11"];
    for (NSString *path in @[older, left, other]) {
        XCTAssertTrue([fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]);
    }

    AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];
    VibeWaveformStore *store = [VibeWaveformStore storeUnderRoot:root];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return !store.importing; }));
    XCTAssertTrue(WaveformSpinUntil(^BOOL {
        return ![fileManager fileExistsAtPath:[self legacyUnder:root]] && ![fileManager fileExistsAtPath:older]
                && ![fileManager fileExistsAtPath:left];
    }));
    XCTAssertTrue([fileManager fileExistsAtPath:other]);
    XCTAssertEqual(store.entries.usage.entries, tracks.count);
    for (VibeTestTrack *track in tracks) {
        NSString *key = VibeWaveformEntryKey(track);
        XCTAssertEqualObjects([store dataForKey:key], files[key], @"the file is listed as it was");
        XCTAssertTrue(WaveformEventuallyCached(cache, track));
        XCTAssertTrue(WasCached(cache, track), @"a hit, so nothing decoded");
    }
}

// A lookup during the import reads the old store's entry, which moves to the
// new store then. An import cut short, as by a quit, carries on at the next
// open.
- (void)testALookupDuringTheImportFindsTheOldEntryAndAQuitResumesIt {
    NSString *root = [self rootNamed:@"caches"];
    NSArray<VibeTestTrack *> *tracks = @[[self trackNamed:@"a.wav" seed:4], [self trackNamed:@"b.wav" seed:5],
                                         [self trackNamed:@"c.wav" seed:6]];
    NSDictionary<NSString *, NSData *> *files = [self legacyStoreUnder:root withTracks:tracks];
    NSString *first = VibeWaveformEntryKey(tracks.firstObject);
    NSString *legacy = [self legacyUnder:root];
    [VibeWaveformStore holdImportsForTesting:YES];
    @autoreleasepool {
        VibeWaveformStore *store = [VibeWaveformStore storeUnderRoot:root];
        XCTAssertTrue(store.importing);
        XCTAssertEqualObjects([store dataForKey:first], files[first]);
        XCTAssertEqual(store.entries.usage.entries, 1u);
        XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:legacy error:nil].count,
                       tracks.count - 1, @"the entry found moved over");
    }
    // That store closed with its import held, as at a quit.
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:legacy]);
    [VibeWaveformStore holdImportsForTesting:NO];

    VibeWaveformStore *store = [VibeWaveformStore storeUnderRoot:root];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return !store.importing; }));
    XCTAssertEqual(store.entries.usage.entries, tracks.count);
    for (NSString *key in files) {
        XCTAssertEqualObjects([store dataForKey:key], files[key]);
    }
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return ![NSFileManager.defaultManager fileExistsAtPath:legacy]; }));
}

// CH15: the format is on the row, so an entry of an older or a newer format
// is a miss without a rename of the store, and the decode replaces it.
- (void)testAnEntryOfAnotherFormatIsAMiss {
    NSString *root = [self rootNamed:@"caches"];
    VibeTestTrack *track = [self trackNamed:@"a.wav" seed:7];
    AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];
    XCTAssertFalse(WasCached(cache, track));
    VibeWaveformStore *store = [VibeWaveformStore storeUnderRoot:root];
    NSString *key = VibeWaveformEntryKey(track);
    NSData *archive = [store.entries hitForKey:key format:kCodableAudioWaveformVersion].data;
    XCTAssertNotNil(archive);

    for (NSNumber *format in @[@(kCodableAudioWaveformVersion - 1), @(kCodableAudioWaveformVersion + 1)]) {
        [store.entries setData:archive forKey:key format:format.integerValue sharedName:nil];
        __block BOOL answered = NO;
        __block CodableAudioWaveform *found = nil;
        [cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
            found = waveform;
            answered = YES;
        }];
        XCTAssertTrue(WaveformSpinUntil(^BOOL { return answered; }));
        XCTAssertNil(found, @"format %@ is a miss", format);
        XCTAssertFalse(WasCached(cache, track), @"format %@ decoded again", format);
        XCTAssertNotNil([store.entries hitForKey:key format:kCodableAudioWaveformVersion], @"and the decode replaced it");
        XCTAssertTrue(WasCached(cache, track));
    }
    XCTAssertEqual(store.entries.usage.entries, 1u);
}

@end
