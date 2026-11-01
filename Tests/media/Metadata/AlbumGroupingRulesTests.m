//
//  AlbumGroupingRulesTests.m
//  vibe-libs
//
//  One case per rule of the plan's album grouping (docs/plan.md, Phase 4).
//  Each track is the tags the parse would read from its file.
//

#import <XCTest/XCTest.h>

#import "AlbumGroupingRules.h"

@interface AlbumGroupingRulesTests : XCTestCase
@end

// A track's tags, in VibeAlbumGroupKey's order.
typedef struct {
    NSString *_Nullable releaseID;
    NSString *_Nullable album;
    NSString *_Nullable albumArtist;
    NSString *_Nullable artist;
    NSInteger year;
    BOOL compilation;
} Track;

static NSString *_Nullable Key(Track track) {
    return VibeAlbumGroupKey(track.releaseID, track.album, track.albumArtist, track.artist, track.year,
                             track.compilation);
}

static NSString *const kRelease = @"f5093c06-23e3-404f-aeaa-40f72885ee3a";

@implementation AlbumGroupingRulesTests

- (void)assertTogether:(Track)a and:(Track)b because:(NSString *)reason {
    XCTAssertNotNil(Key(a), @"%@", reason);
    XCTAssertEqualObjects(Key(a), Key(b), @"%@", reason);
}

- (void)assertApart:(Track)a and:(Track)b because:(NSString *)reason {
    XCTAssertNotNil(Key(a), @"%@", reason);
    XCTAssertNotNil(Key(b), @"%@", reason);
    XCTAssertNotEqualObjects(Key(a), Key(b), @"%@", reason);
}

// The release identifier is the key wherever it is present.
- (void)testOneReleaseGroupsWhateverItsOtherTagsSay {
    [self assertTogether:(Track){kRelease, @"Abbey Road", @"The Beatles", @"The Beatles", 1969, NO}
                     and:(Track){kRelease.uppercaseString, @"Abbey Road (Remastered)", nil, @"Paul McCartney", 2019,
                                 YES}
                 because:@"one release, retagged"];
    [self assertTogether:(Track){kRelease, nil, nil, nil, 0, NO}
                     and:(Track){kRelease, @"Abbey Road", nil, nil, 0, NO}
                 because:@"a release needs no album title"];
}

- (void)testTwoReleasesNeverMerge {
    [self assertApart:(Track){kRelease, @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
                  and:(Track){@"0e3b9c4c-0000-4000-8000-000000000001", @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
              because:@"two pressings with their own releases"];
    [self assertApart:(Track){kRelease, @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
                  and:(Track){nil, @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
              because:@"a release's key never equals a tagged album's"];
}

// Otherwise the album artist, the album, and the year.
- (void)testTheAlbumTitleAloneNeverMerges {
    [self assertApart:(Track){nil, @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
                  and:(Track){nil, @"Greatest Hits", @"ABBA", @"ABBA", 1981, NO}
              because:@"two artists' Greatest Hits"];
    [self assertApart:(Track){nil, @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
                  and:(Track){nil, @"Greatest Hits", @"Queen", @"Queen", 2011, NO}
              because:@"one artist's two years"];
    [self assertApart:(Track){nil, @"Greatest Hits", @"Queen", @"Queen", 1981, NO}
                  and:(Track){nil, @"Greatest Hits II", @"Queen", @"Queen", 1981, NO}
              because:@"two titles"];
}

- (void)testTheAlbumArtistGroupsTracksOfManyArtists {
    [self assertTogether:(Track){nil, @"Duets", @"Frank Sinatra", @"Frank Sinatra", 1993, NO}
                     and:(Track){nil, @"Duets", @"Frank Sinatra", @"Frank Sinatra & Bono", 1993, NO}
                 because:@"a featured artist stays on the album"];
}

// The track artist stands in when the album artist is missing.
- (void)testTheTrackArtistStandsInForAMissingAlbumArtist {
    [self assertTogether:(Track){nil, @"Blue", nil, @"Joni Mitchell", 1971, NO}
                     and:(Track){nil, @"Blue", nil, @"Joni Mitchell", 1971, NO}
                 because:@"one artist, no album artist"];
    [self assertApart:(Track){nil, @"Blue", nil, @"Joni Mitchell", 1971, NO}
                  and:(Track){nil, @"Blue", nil, @"Weezer", 1971, NO}
              because:@"two artists' Blue"];
    [self assertTogether:(Track){nil, @"Blue", @"Joni Mitchell", @"Joni Mitchell", 1971, NO}
                     and:(Track){nil, @"Blue", nil, @"Joni Mitchell", 1971, NO}
                 because:@"a stand-in matches the album artist it stands for"];
    [self assertTogether:(Track){nil, @"Blue", @"", @"Joni Mitchell", 1971, NO}
                     and:(Track){nil, @"Blue", nil, @"Joni Mitchell", 1971, NO}
                 because:@"an empty album artist is missing"];
}

// A compilation groups by its album under one album artist.
- (void)testACompilationNeverSplitsByTrackArtist {
    [self assertTogether:(Track){nil, @"Now 42", nil, @"Robbie Williams", 1999, YES}
                     and:(Track){nil, @"Now 42", nil, @"Britney Spears", 1999, YES}
                 because:@"no album artist"];
    [self assertTogether:(Track){nil, @"Now 42", @"Various Artists", @"Robbie Williams", 1999, YES}
                     and:(Track){nil, @"Now 42", @"Various Artists", @"Britney Spears", 1999, YES}
                 because:@"one album artist"];
    [self assertApart:(Track){nil, @"Now 42", nil, @"Robbie Williams", 1999, YES}
                  and:(Track){nil, @"Now 43", nil, @"Robbie Williams", 1999, YES}
              because:@"two compilations"];
    [self assertApart:(Track){nil, @"Now 42", nil, @"Robbie Williams", 1999, YES}
                  and:(Track){nil, @"Now 42", nil, @"Robbie Williams", 1999, NO}
              because:@"a track not marked as one keeps its artist"];
}

- (void)testATrackWithoutAnAlbumHasNoGroup {
    XCTAssertNil(Key((Track){nil, nil, @"Queen", @"Queen", 1981, NO}));
    XCTAssertNil(Key((Track){@"", @"", nil, @"Queen", 0, YES}));
}

- (void)testTheSeparatorKeepsFieldsApart {
    [self assertApart:(Track){nil, @"bc", @"a", nil, 0, NO}
                  and:(Track){nil, @"c", @"ab", nil, 0, NO}
              because:@"the same letters split differently"];
}

// The group artist is the album artist, else the track artist, but never a
// compilation's track artist, and it groups the key.
- (void)testTheGroupArtistIsTheKeysOwn {
    XCTAssertEqualObjects(VibeAlbumGroupArtist(@"Burial", @"Kode9", NO), @"Burial");
    XCTAssertEqualObjects(VibeAlbumGroupArtist(@"Burial", @"Kode9", YES), @"Burial");
    XCTAssertEqualObjects(VibeAlbumGroupArtist(nil, @"Kode9", NO), @"Kode9");
    XCTAssertEqualObjects(VibeAlbumGroupArtist(@"", @"Kode9", NO), @"Kode9");
    XCTAssertNil(VibeAlbumGroupArtist(nil, @"Kode9", YES));
    XCTAssertNil(VibeAlbumGroupArtist(nil, nil, NO));
    [self assertTogether:(Track){nil, @"Untrue", nil, @"Burial", 2007, NO}
                     and:(Track){nil, @"Untrue", @"Burial", @"Kode9", 2007, NO}
                 because:@"the same group artist, by either tag"];
}

@end
