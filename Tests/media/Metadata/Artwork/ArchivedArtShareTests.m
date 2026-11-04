//
// The archived forms of a picture many files embed: made once while its
// bytes recur, by one parse, while the others wait.
//

#import <XCTest/XCTest.h>

#import "ArchivedArtShare.h"

#import <stdatomic.h>

@interface ArchivedArtShareTests : XCTestCase
@end

@implementation ArchivedArtShareTests

- (void)setUp {
    VibeArchivedArtShareResetForTesting();
}

- (void)tearDown {
    VibeArchivedArtShareResetForTesting();
}

static NSData *ArtBytes(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// The forms of a picture, made by a maker that counts its runs and takes
// its time.
static void Forms(NSData *picture, atomic_int *made, useconds_t delay, NSData **thumbnail, NSData **rendition) {
    VibeArchivedArtOfPicture(picture, ^(NSData **madeThumbnail, NSData **madeRendition) {
        atomic_fetch_add(made, 1);
        usleep(delay);
        *madeThumbnail = picture;
        *madeRendition = picture;
    }, thumbnail, rendition);
}

- (void)testAPictureIsMadeOnceWhileItRecurs {
    atomic_int made = 0;
    NSData *first = nil, *firstRendition = nil, *second = nil, *secondRendition = nil;
    Forms(ArtBytes(@"cover"), &made, 0, &first, &firstRendition);
    Forms(ArtBytes(@"cover"), &made, 0, &second, &secondRendition);
    XCTAssertEqual(atomic_load(&made), 1);
    XCTAssertEqualObjects(first, second);
    XCTAssertEqualObjects(firstRendition, secondRendition);
}

- (void)testAnotherPictureIsMadeApart {
    atomic_int made = 0;
    NSData *one = nil, *other = nil, *rendition = nil;
    Forms(ArtBytes(@"one"), &made, 0, &one, &rendition);
    Forms(ArtBytes(@"two"), &made, 0, &other, &rendition);
    XCTAssertEqual(atomic_load(&made), 2);
    XCTAssertNotEqualObjects(one, other);
}

// Parses that meet a picture another is making wait for its forms.
- (void)testParsesAtOnceMakeAPictureOnce {
    __block atomic_int made = 0;
    NSData *picture = ArtBytes(@"album");
    dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        NSData *thumbnail = nil, *rendition = nil;
        Forms(picture, &made, 50000, &thumbnail, &rendition);
        XCTAssertEqualObjects(thumbnail, picture);
    });
    XCTAssertEqual(atomic_load(&made), 1);
}

// A failed make is kept too: the same bytes fail the same way.
- (void)testAFailedMakeIsShared {
    __block atomic_int made = 0;
    NSData *thumbnail = ArtBytes(@"stale"), *rendition = ArtBytes(@"stale");
    for (int i = 0; i < 2; i++) {
        VibeArchivedArtOfPicture(ArtBytes(@"broken"), ^(NSData **madeThumbnail, NSData **madeRendition) {
            atomic_fetch_add(&made, 1);
        }, &thumbnail, &rendition);
    }
    XCTAssertEqual(atomic_load(&made), 1);
    XCTAssertNil(thumbnail);
    XCTAssertNil(rendition);
}

- (void)testTheOldestPictureIsForgotten {
    atomic_int made = 0;
    NSData *thumbnail = nil, *rendition = nil;
    for (NSUInteger i = 0; i <= kVibeArchivedArtShareCount; i++) {
        Forms(ArtBytes([NSString stringWithFormat:@"picture %lu", (unsigned long)i]), &made, 0, &thumbnail, &rendition);
    }
    XCTAssertEqual((NSUInteger)atomic_load(&made), kVibeArchivedArtShareCount + 1);
    Forms(ArtBytes(@"picture 0"), &made, 0, &thumbnail, &rendition);
    XCTAssertEqual((NSUInteger)atomic_load(&made), kVibeArchivedArtShareCount + 2, @"made again");
    Forms(ArtBytes([NSString stringWithFormat:@"picture %lu", (unsigned long)kVibeArchivedArtShareCount]), &made, 0,
          &thumbnail, &rendition);
    XCTAssertEqual((NSUInteger)atomic_load(&made), kVibeArchivedArtShareCount + 2, @"still kept");
}

@end
