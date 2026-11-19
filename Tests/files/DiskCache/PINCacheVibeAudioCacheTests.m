//
// What is left of the PINCache stores of the releases before VibeCacheStore:
// the removal of the stores other versions left, which came from Vibe, the
// names an import reads an old store by, and the default age.
//

#import <XCTest/XCTest.h>

#import "PINCache+VibeAudioCache.h"
#import "VibeLegacyCacheNames.h"
#import "VibeCacheStore.h"

@interface PINCacheVibeAudioCacheTests : XCTestCase
@end

@implementation PINCacheVibeAudioCacheTests {
    NSString *_root;
}

- (void)setUp {
    [super setUp];
    _root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtPath:_root error:nil];
    [super tearDown];
}

#pragma mark - The old stores' names

// The folder and the file name, as PINDiskCache's default key encoder named
// them: only the four characters it escaped are escaped.
- (void)testAnOldEntryIsNamedAsPINDiskCacheNamedIt {
    XCTAssertEqualObjects(VibeLegacyCacheFolder(@"/caches", @"Audio Track Metadata v11"),
                          @"/caches/com.pinterest.PINDiskCache.Audio Track Metadata v11");
    XCTAssertEqualObjects(VibeLegacyCacheFileName(@"3-1700000000-/Music/a b:c.flac%"),
                          @"3-1700000000-%2FMusic%2Fa b%3Ac%2Eflac%25");
    XCTAssertNil(VibeLegacyCacheFileName(@""));
}

// An app that keeps the default age passes the store's.
- (void)testTheDefaultAgeIsTheStoresDefault {
    XCTAssertEqual(VibeAudioCacheDefaultAgeLimit, VibeCacheStore.defaultAgeLimit);
}

#pragma mark - Other versions' stores

- (void)makeStores:(NSArray<NSString *> *)names {
    for (NSString *name in names) {
        NSString *store = [_root stringByAppendingPathComponent:name];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES
                                                               attributes:nil error:nil]);
        [NSData.data writeToFile:[store stringByAppendingPathComponent:@"entry"] atomically:NO];
    }
}

- (NSSet<NSString *> *)remaining {
    return [NSSet setWithArray:[NSFileManager.defaultManager contentsOfDirectoryAtPath:_root error:nil] ?: @[]];
}

- (void)removeOtherVersionsKeeping:(NSArray<NSString *> *)names under:(NSString *)root {
    XCTestExpectation *removed = [self expectationWithDescription:@"removed"];
    [PINCache removeOtherAudioCacheVersionsKeeping:names rootPath:root completion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// Every name a release shipped, with the next bump's current names standing in.
- (void)testRemovesEveryOtherVersionAndKeepsTheCurrentStores {
    NSMutableArray<NSString *> *legacy = [NSMutableArray array];
    for (NSString *name in @[@"Audio Track Metadata", @"Audio Track Metadata v2", @"Audio Track Metadata v3",
                             @"Audio Track Metadata v4", @"Audio Track Metadata v5", @"Audio Track Metadata v7",
                             @"Audio Track Metadata v10", @"audio_waveform_cache", @"audio_waveform_cache_v2",
                             @"audio_waveform_cache_v4", @"audio_waveform_cache_v5", @"audio_waveform_cache_v6"]) {
        [legacy addObject:[@"com.pinterest.PINDiskCache." stringByAppendingString:name]];
    }
    NSArray<NSString *> *kept = @[@"com.pinterest.PINDiskCache.Audio Track Metadata v8",
                                  @"com.pinterest.PINDiskCache.audio_waveform_cache_v7",
                                  // Another store, and a directory that is no store.
                                  @"com.pinterest.PINDiskCache.Audio Track Metadata Art v1",
                                  @"Audio Track Metadata v5"];
    [self makeStores:[legacy arrayByAddingObjectsFromArray:kept]];

    [self removeOtherVersionsKeeping:@[@"Audio Track Metadata v8", @"audio_waveform_cache_v7"] under:_root];

    XCTAssertEqualObjects(self.remaining, [NSSet setWithArray:kept]);
}

// Two kept names of one family both stay, as a store and the older one it
// imports do, and the family's other versions go.
- (void)testKeepsEveryCurrentNameOfOneFamily {
    NSArray<NSString *> *kept = @[@"com.pinterest.PINDiskCache.Audio Track Metadata",
                                  @"com.pinterest.PINDiskCache.Audio Track Metadata v11"];
    [self makeStores:[kept arrayByAddingObject:@"com.pinterest.PINDiskCache.Audio Track Metadata v10"]];

    [self removeOtherVersionsKeeping:@[@"Audio Track Metadata", @"Audio Track Metadata v11"] under:_root];

    XCTAssertEqualObjects(self.remaining, [NSSet setWithArray:kept]);
}

- (void)testAMissingDirectoryIsANoOp {
    [self removeOtherVersionsKeeping:@[@"Audio Track Metadata v8"]
                               under:[_root stringByAppendingPathComponent:@"absent"]];
    XCTAssertEqualObjects(self.remaining, [NSSet set]);
}

@end
