//
//  AudioTrackMetadataCacheTests.mm
//
//  The cache over a store of its own, with the real loader, parse and
//  coordinator. Objective-C++, since the tag fixtures are C++.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "MetadataLoaderTestFakes.h"
#import "PINCache+VibeAudioCache.h"
#import "VibeTestNegativeWindow.h"

@interface AudioTrackMetadataCacheTests : XCTestCase
@end

@implementation AudioTrackMetadataCacheTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [@"vibe-metadata-cache-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]]
                      isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

- (BOOL)waitFor:(BOOL (^)(void))condition within:(NSTimeInterval)seconds {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

// The store's build is held at a gate, so the load is issued before the
// store exists. The load waits for the store rather than parsing uncached.
// Once the gate opens it is delivered and filed, so a second cache over the
// same root hits from the disk alone.
- (void)testALoadIssuedBeforeTheStoreExistsIsFiled {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureWAVID3, nil, NULL);
    XCTAssertNotNil(url);
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    dispatch_semaphore_t building = dispatch_semaphore_create(0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    SEL selector = @selector(audioCacheWithName:rootPath:);
    Method method = class_getClassMethod(PINCache.class, selector);
    IMP original = method_getImplementation(method);
    IMP held = imp_implementationWithBlock(^PINCache *(Class cls, NSString *name, NSString *rootPath) {
        dispatch_semaphore_signal(building);
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW,
                                                    (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        PINCache *store = ((PINCache *(*)(Class, SEL, NSString *, NSString *))original)(cls, selector, name,
                                                                                         rootPath);
        dispatch_semaphore_signal(returned);
        return store;
    });
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    VibeLoaderTestTrack *track = [VibeLoaderTestTrack withURL:url];
    AudioTrackMetadataCache *cache = nil;
    method_setImplementation(method, held);
    @try {
        cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
        cache.delegate = delegate;
        XCTAssertEqual(dispatch_semaphore_wait(building, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0, @"the store's build never started");
        [cache loadMetadataNow:track];
        XCTAssertFalse([self waitFor:^BOOL { return delegate.deliveredTracks.count > 0; }
                              within:kVibeTestNegativeWindow],
                       @"the load parsed without its store");
    }
    @finally {
        dispatch_semaphore_signal(gate);
        method_setImplementation(method, original);
        // TRAP: the held block is still running on the cache's queue when
        // the gate opens. imp_removeBlock frees it, so removing it before
        // the block returns crashes.
        if (dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0) {
            imp_removeBlock(held);
        }
    }
    XCTAssertTrue([self waitFor:^BOOL { return delegate.deliveredTracks.count > 0; }
                         within:VIBE_TEST_HANG_TIMEOUT]);
    XCTAssertTrue(track.metadata.parsedOK);
    XCTAssertEqualObjects(track.metadata.title, kVibeTagTitle);

    AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataLoaderDelegate *hits = [[VibeMetadataLoaderDelegate alloc] init];
    reopened.delegate = hits;
    VibeLoaderTestTrack *again = [VibeLoaderTestTrack withURL:url];
    [reopened loadCachedMetadata:@[again]];
    XCTAssertTrue([self waitFor:^BOOL { return hits.deliveredTracks.count > 0; } within:VIBE_TEST_HANG_TIMEOUT],
                  @"the load before the store was not filed");
    XCTAssertEqualObjects(again.metadata.title, kVibeTagTitle);
    cache.delegate = nil;
    reopened.delegate = nil;
}

// The store's name carries its version as DiskCache's removal reads it, so a
// format bump removes the old store and keeps the current one.
- (void)testTheStoreNameFollowsTheVersionRule {
    NSString *root = [_dir URLByAppendingPathComponent:@"stores"].path;
    NSString *current = [@"com.pinterest.PINDiskCache." stringByAppendingString:AudioTrackMetadataCache.cacheName];
    for (NSString *store in @[current, @"com.pinterest.PINDiskCache.Audio Track Metadata v1"]) {
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:store]
                                              withIntermediateDirectories:YES attributes:nil error:nil]);
    }
    XCTestExpectation *removed = [self expectationWithDescription:@"removed"];
    [PINCache removeOtherAudioCacheVersionsKeeping:@[AudioTrackMetadataCache.cacheName] rootPath:root completion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects([NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil], @[current]);
}

@end
