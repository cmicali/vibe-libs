//
//  WavpackTests.m
//
//  The vendored libwavpack builds and links on its own: it names its version,
//  and its open refuses bytes that are not WavPack.
//

#import <XCTest/XCTest.h>

// wavpack.h's ChunkHeader would clash with CoreServices' (third_party/wavpack/AGENTS.md).
#define ChunkHeader VibeWavPackChunkHeader
#include <wavpack.h>
#undef ChunkHeader

@interface WavpackTests : XCTestCase
@end

@implementation WavpackTests

- (void)testNamesItsVersion {
    XCTAssertEqual(WavpackGetLibraryVersion() >> 16, 5u);
    XCTAssertTrue(strlen(WavpackGetLibraryVersionString()) > 0);
}

static int32_t ReadNothing(void *id, void *data, int32_t count) { return 0; }
static int64_t PositionZero(void *id) { return 0; }
static int SetNothing(void *id, int64_t position) { return -1; }
static int MoveNothing(void *id, int64_t delta, int mode) { return -1; }
static int PushNothing(void *id, int c) { return c; }
static int CannotSeek(void *id) { return 0; }

- (void)testRefusesAnEmptyStream {
    WavpackStreamReader64 reader = {
        .read_bytes = ReadNothing, .get_pos = PositionZero, .set_pos_abs = SetNothing, .set_pos_rel = MoveNothing,
        .push_back_byte = PushNothing, .get_length = PositionZero, .can_seek = CannotSeek,
    };
    char error[80] = {0};
    XCTAssertTrue(WavpackOpenFileInputEx64(&reader, NULL, NULL, error, 0, 0) == NULL);
    XCTAssertTrue(strlen(error) > 0);
}

@end
