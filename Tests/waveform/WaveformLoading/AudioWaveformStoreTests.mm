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
#import "AudioWaveformCacheInternal.h"
#import "LegacyCacheFixtures.h"
#import "NSURL+Hash.h"
#import "VibeTestVolumes.h"
#import "VibeTestTrack.h"
#import "VibeWaveformStore.h"
#import "WaveformLoadingTestSupport.h"


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
    return VibeLegacyCacheFolder(root, VibeWaveformStore.legacyName);
}

- (VibeTestTrack *)trackNamed:(NSString *)name seed:(uint32_t)seed {
    NSURL *url = VibeWriteNoiseWAV([_directory URLByAppendingPathComponent:name], 1.0, seed);
    XCTAssertNotNil(url);
    return [VibeTestTrack withURL:url];
}

// Decodes each track through a cache of its own, then files the waveforms in
// a PINCache store under root as the release before this one did. Returns
// each entry's bytes on disk by its key.
- (NSDictionary<NSString *, NSData *> *)legacyStoreUnder:(NSString *)root withTracks:(NSArray<VibeTestTrack *> *)tracks {
    return [self legacyStoreUnder:root withTracks:tracks keyedBy:^NSString *(VibeTestTrack *track) {
        return VibeWaveformEntryKey(track);
    }];
}

// The same, each entry under the key keyFor gives.
- (NSDictionary<NSString *, NSData *> *)legacyStoreUnder:(NSString *)root
                                              withTracks:(NSArray<VibeTestTrack *> *)tracks
                                                 keyedBy:(NSString *(^)(VibeTestTrack *track))keyFor {
    StoreTestRecorder *recorder = [StoreTestRecorder new];
    AudioWaveformCache *decoder = [[AudioWaveformCache alloc] initWithRootPath:[self rootNamed:@"decoder"]];
    decoder.delegate = recorder;
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    for (VibeTestTrack *track in tracks) {
        NSUInteger before = recorder.complete.count;
        [decoder loadWaveformForTrack:track];
        XCTAssertTrue(WaveformSpinUntil(^BOOL { return recorder.complete.count > before; }));
        NSString *key = keyFor(track);
        NSData *bytes = VibeWriteLegacyCacheEntry(root, VibeWaveformStore.legacyName, key, recorder.complete.lastObject);
        XCTAssertGreaterThan(bytes.length, 0u);
        files[key] = bytes;
    }
    return files;
}

// CH19: every entry of the old store reads back the same, with no decode,
// and the old store and the ones before it are gone at the end, leaving only
// the new store and a folder of another kind.
- (void)testTheImportBringsEveryEntryOverAndRemovesTheOldStores {
    NSString *root = [self rootNamed:@"caches"];
    NSArray<VibeTestTrack *> *tracks = @[[self trackNamed:@"a.wav" seed:1], [self trackNamed:@"b.wav" seed:2],
                                         [self trackNamed:@"c.wav" seed:3]];
    NSDictionary<NSString *, NSData *> *files = [self legacyStoreUnder:root withTracks:tracks];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *older = [root stringByAppendingPathComponent:@"com.pinterest.PINDiskCache.audio_waveform_cache_v6"];
    NSString *other = [root stringByAppendingPathComponent:@"com.pinterest.PINDiskCache.audio_track_metadata_v11"];
    for (NSString *path in @[older, other]) {
        XCTAssertTrue([fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]);
    }

    AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];
    VibeWaveformStore *store = [VibeWaveformStore storeUnderRoot:root];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return !store.importing; }));
    XCTAssertTrue(WaveformSpinUntil(^BOOL {
        return ![fileManager fileExistsAtPath:[self legacyUnder:root]] && ![fileManager fileExistsAtPath:older];
    }));
    XCTAssertTrue(WaveformSpinUntil(^BOOL {
        NSArray<NSString *> *left = [fileManager contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:VibeWaveformStore.name] error:nil];
        return [left filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'Files removed'"]].count == 0;
    }), @"the old folder, moved into the store to be removed, is gone");
    NSArray<NSString *> *kept = [[fileManager contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)];
    XCTAssertEqualObjects(kept, (@[VibeWaveformStore.name, other.lastPathComponent]));
    XCTAssertEqual(store.entries.usage.entries, tracks.count);
    for (VibeTestTrack *track in tracks) {
        NSString *key = VibeWaveformEntryKey(track);
        XCTAssertEqualObjects([store dataForKey:key], files[key], @"the file is listed as it was");
        XCTAssertTrue(WaveformEventuallyCached(cache, track));
        XCTAssertTrue(WaveformWasCached(cache, track), @"a hit, so nothing decoded");
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
    XCTAssertFalse(WaveformWasCached(cache, track));
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
        XCTAssertFalse(WaveformWasCached(cache, track), @"format %@ decoded again", format);
        XCTAssertNotNil([store.entries hitForKey:key format:kCodableAudioWaveformVersion], @"and the decode replaced it");
        XCTAssertTrue(WaveformWasCached(cache, track));
    }
    XCTAssertEqual(store.entries.usage.entries, 1u);
}

// CH33: the release before keyed each waveform by its file's previous key, a
// cue row's with its window after it. A lookup finds each there once the
// import has brought it over, and moves it to its key, so nothing decodes.
- (void)testAWaveformUnderItsPreviousKeyIsFoundAndMoved {
    VibeTestUseVolume(self, @"uuid-of-the-test-volume", @"/");
    NSString *root = [self rootNamed:@"caches"];
    VibeTestTrack *whole = [self trackNamed:@"a.wav" seed:8];
    NSURL *image = VibeWriteNoiseWAV([_directory URLByAppendingPathComponent:@"b.wav"], 2.0, 9);
    VibeTestTrack *row = [[VibeTestTrack alloc] initWithURL:image cueStart:75 cueEnd:150];
    NSArray<VibeTestTrack *> *tracks = @[whole, row];
    NSMutableDictionary<NSString *, NSString *> *previousKeys = [NSMutableDictionary dictionary];
    for (VibeTestTrack *track in tracks) {
        NSString *key = VibeWaveformEntryKey(track);
        previousKeys[key] = [track.url previousCacheKeyForKey:key];
        XCTAssertNotNil(previousKeys[key]);
        XCTAssertNotEqualObjects(previousKeys[key], key);
    }
    [self legacyStoreUnder:root withTracks:tracks keyedBy:^NSString *(VibeTestTrack *track) {
        return previousKeys[VibeWaveformEntryKey(track)];
    }];

    AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];
    VibeWaveformStore *store = [VibeWaveformStore storeUnderRoot:root];
    XCTAssertTrue(WaveformSpinUntil(^BOOL { return !store.importing; }));
    XCTAssertTrue([store.entries mayHoldEntriesFromBeforeMark:VibeCacheKeyPlaceMark],
                  @"the import filed its entries under previous keys");
    for (VibeTestTrack *track in tracks) {
        NSString *key = VibeWaveformEntryKey(track);
        XCTAssertTrue(WaveformEventuallyCached(cache, track));
        XCTAssertTrue(WaveformWasCached(cache, track), @"a hit, so nothing decoded");
        XCTAssertTrue([store.entries hasEntryForKey:key]);
        XCTAssertFalse([store.entries hasEntryForKey:previousKeys[key]], @"moved to its key");
    }
}

@end
