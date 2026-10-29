
#import <XCTest/XCTest.h>

#import "VibePlaylist.h"
#import "VibePlaylistTestSupport.h"

@interface VibePlaylistRepeatAndShuffleTests : XCTestCase
@end

@implementation VibePlaylistRepeatAndShuffleTests

#pragma mark - Repeat

static VibePlaylist *NumberedPlaylist(NSUInteger count) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [names addObject:[NSString stringWithFormat:@"%02lu.mp3", (unsigned long)i]];
    }
    return PlaylistWithFiles(names);
}

- (void)testRepeatModesAnswerNextAndTrackEndAtTheLastRow {
    VibePlaylist *playlist = NumberedPlaylist(3);
    playlist.currentIndex = 2;
    TestRow *last = playlist.currentTrack;

    XCTAssertNil(playlist.nextTrack);
    XCTAssertNil(playlist.trackEndSuccessor);
    XCTAssertFalse(playlist.hasNextTrack);

    playlist.repeatMode = VibeRepeatModeAll;
    XCTAssertEqual(playlist.nextTrack, [playlist trackAtIndex:0]);
    XCTAssertEqual(playlist.trackEndSuccessor, [playlist trackAtIndex:0]);
    XCTAssertTrue(playlist.hasNextTrack);

    // One changes only the track end: Next behaves as under Off.
    playlist.repeatMode = VibeRepeatModeOne;
    XCTAssertNil(playlist.nextTrack);
    XCTAssertFalse(playlist.hasNextTrack);
    XCTAssertEqual(playlist.trackEndSuccessor, last);
}

- (void)testPreviousNeverWraps {
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        VibePlaylist *playlist = NumberedPlaylist(3);
        playlist.repeatMode = mode.integerValue;
        XCTAssertFalse(playlist.hasPreviousTrack);
        XCTAssertFalse([playlist previous]);
        XCTAssertEqual(playlist.currentIndex, 0u);
    }
}

- (void)testAdvanceAtTrackEndParksWrapsOrReplays {
    VibePlaylist *playlist = NumberedPlaylist(2);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    playlist.currentIndex = 1;
    [observer.events removeAllObjects];

    XCTAssertFalse([playlist advanceAtTrackEnd]);
    XCTAssertEqual(observer.events.count, 0u);

    playlist.repeatMode = VibeRepeatModeAll;
    XCTAssertTrue([playlist advanceAtTrackEnd]);
    XCTAssertEqual(playlist.currentIndex, 0u);

    // One stays on the row and still notifies, as a replay of a row does.
    playlist.repeatMode = VibeRepeatModeOne;
    [observer.events removeAllObjects];
    XCTAssertTrue([playlist advanceAtTrackEnd]);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects(observer.events, @[@"index 0->0"]);

    // Next under One walks on, and parks at the end.
    XCTAssertTrue([playlist next]);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertFalse([playlist next]);
}

- (void)testPauseAtTrackEndOutranksEveryMode {
    VibePlaylist *playlist = NumberedPlaylist(3);
    playlist.currentIndex = 0;
    TestRow *first = playlist.currentTrack, *second = [playlist trackAtIndex:1];
    XCTAssertEqual(playlist.trackEndSuccessor, second);
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        playlist.repeatMode = mode.integerValue;
        playlist.pauseAtTrackEnd = YES;
        XCTAssertNil(playlist.trackEndSuccessor);
        XCTAssertFalse([playlist advanceAtTrackEnd]);
        XCTAssertFalse([playlist advanceFromTrack:first toTrack:second]);
        XCTAssertFalse([playlist advanceFromTrack:first toTrack:first]);
        XCTAssertEqual(playlist.currentIndex, 0u);
        playlist.pauseAtTrackEnd = NO;
        XCTAssertNotNil(playlist.trackEndSuccessor);
    }
    playlist.repeatMode = VibeRepeatModeOff;
    playlist.pauseAtTrackEnd = YES;
    XCTAssertTrue([playlist next]);
    XCTAssertEqual(playlist.currentTrack, second);
}

- (void)testGaplessAdoptionFollowsTheTrackEndSuccessor {
    VibePlaylist *playlist = NumberedPlaylist(3);
    playlist.currentIndex = 2;
    TestRow *last = playlist.currentTrack;
    TestRow *first = [playlist trackAtIndex:0];

    XCTAssertFalse([playlist advanceFromTrack:last toTrack:first]);
    playlist.repeatMode = VibeRepeatModeAll;
    XCTAssertTrue([playlist advanceFromTrack:last toTrack:first]);
    XCTAssertEqual(playlist.currentTrack, first);

    // Under One the splice is into the track itself, never its neighbor.
    playlist.repeatMode = VibeRepeatModeOne;
    XCTAssertFalse([playlist advanceFromTrack:first toTrack:[playlist trackAtIndex:1]]);
    XCTAssertTrue([playlist advanceFromTrack:first toTrack:first]);
    XCTAssertEqual(playlist.currentTrack, first);
}

- (void)testRepeatOnEmptyAndSingleRowPlaylists {
    VibePlaylist *empty = NewPlaylist();
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        empty.repeatMode = mode.integerValue;
        XCTAssertNil(empty.nextTrack);
        XCTAssertNil(empty.trackEndSuccessor);
        XCTAssertFalse([empty advanceAtTrackEnd]);
    }
    VibePlaylist *single = NumberedPlaylist(1);
    TestRow *only = single.currentTrack;
    single.repeatMode = VibeRepeatModeAll;
    XCTAssertEqual(single.nextTrack, only);
    XCTAssertTrue([single next]);
    XCTAssertEqual(single.currentTrack, only);
}

// A removal is not a track end: the landing never wraps.
- (void)testRemovingThePlayingLastRowUnderRepeatAllParksBackward {
    VibePlaylist *playlist = NumberedPlaylist(3);
    playlist.repeatMode = VibeRepeatModeAll;
    playlist.currentIndex = 2;
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:RowSet(2)]);
    [playlist removeTracksAtIndexes:RowSet(2)];
    XCTAssertEqual(playlist.currentIndex, 1u);
}

#pragma mark - Shuffle

// A deterministic stream for the order: a 64-bit LCG, high bits out.
static uint32_t (^SeededRandom(uint64_t seed))(uint32_t) {
    __block uint64_t state = seed * 2654435761u + 1;
    return ^uint32_t(uint32_t upperBound) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        return (uint32_t)((state >> 33) % upperBound);
    };
}

static VibePlaylist *ShuffledPlaylist(NSUInteger count, uint64_t seed) {
    VibePlaylist *playlist = NumberedPlaylist(count);
    playlist.randomBelow = SeededRandom(seed);
    playlist.shuffleEnabled = YES;
    return playlist;
}

// The current track, then every track next lands on, up to limit.
static NSArray<TestRow *> *WalkNext(VibePlaylist *playlist, NSUInteger limit) {
    NSMutableArray<TestRow *> *walk = [NSMutableArray arrayWithObject:playlist.currentTrack];
    while (walk.count < limit) {
        TestRow *peek = playlist.nextTrack;
        if (![playlist next]) {
            XCTAssertNil(peek);
            break;
        }
        // The peek is where next lands: the gapless splice arms on it.
        XCTAssertEqual(playlist.currentTrack, peek);
        [walk addObject:playlist.currentTrack];
    }
    return walk;
}

static void AssertPermutation(VibePlaylist *playlist, NSArray<TestRow *> *walk) {
    XCTAssertEqual(walk.count, playlist.count);
    XCTAssertEqual([NSSet setWithArray:walk].count, playlist.count);
    XCTAssertTrue([[NSSet setWithArray:walk] isEqualToSet:[NSSet setWithArray:playlist.tracks]]);
}

- (void)testShuffleVisitsEveryRowOnceFromTheCurrentOneThenParks {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = NumberedPlaylist(12);
        playlist.randomBelow = SeededRandom(seed);
        playlist.currentIndex = 5;
        TestRow *playing = playlist.currentTrack;
        playlist.shuffleEnabled = YES;
        XCTAssertEqual(playlist.currentTrack, playing);
        XCTAssertFalse(playlist.hasPreviousTrack);
        NSArray<TestRow *> *walk = WalkNext(playlist, 100);
        AssertPermutation(playlist, walk);
        XCTAssertEqual(walk.firstObject, playing);
        XCTAssertFalse(playlist.hasNextTrack);
        XCTAssertNil(playlist.trackEndSuccessor);
    }
}

- (void)testShuffleLeavesTheRowsInTheirOrder {
    VibePlaylist *playlist = NumberedPlaylist(8);
    NSArray<TestRow *> *rows = playlist.tracks;
    playlist.randomBelow = SeededRandom(3);
    playlist.shuffleEnabled = YES;
    WalkNext(playlist, 4);
    XCTAssertEqualObjects(playlist.tracks, rows);
}

- (void)testRepeatAllReshufflesEachCycleWithoutRepeatingAcrossTheSeam {
    for (NSUInteger count = 1; count <= 6; count++) {
        for (uint64_t seed = 1; seed <= 40; seed++) {
            VibePlaylist *playlist = ShuffledPlaylist(count, seed);
            playlist.repeatMode = VibeRepeatModeAll;
            NSArray<TestRow *> *walk = WalkNext(playlist, count * 4);
            XCTAssertEqual(walk.count, count * 4);
            for (NSUInteger cycle = 0; cycle < 4; cycle++) {
                AssertPermutation(playlist, [walk subarrayWithRange:NSMakeRange(cycle * count, count)]);
            }
            for (NSUInteger i = 1; count > 1 && i < walk.count; i++) {
                XCTAssertNotEqual(walk[i], walk[i - 1], @"back-to-back at %lu, %lu rows, seed %llu",
                                  (unsigned long)i, (unsigned long)count, seed);
            }
        }
    }
}

- (void)testTheNextCycleIsKeptOnceAsked {
    VibePlaylist *playlist = ShuffledPlaylist(5, 7);
    playlist.repeatMode = VibeRepeatModeAll;
    WalkNext(playlist, 5);
    TestRow *peek = playlist.nextTrack;
    XCTAssertEqual(playlist.nextTrack, peek);
    XCTAssertEqual(playlist.trackEndSuccessor, peek);
    XCTAssertTrue([playlist advanceFromTrack:playlist.currentTrack toTrack:peek]);
    XCTAssertEqual(playlist.currentTrack, peek);
}

- (void)testShufflePreviousRetracesThePlayedOrder {
    VibePlaylist *playlist = ShuffledPlaylist(6, 11);
    NSArray<TestRow *> *walk = WalkNext(playlist, 4);
    for (NSInteger i = (NSInteger)walk.count - 2; i >= 0; i--) {
        XCTAssertTrue([playlist previous]);
        XCTAssertEqual(playlist.currentTrack, walk[(NSUInteger)i]);
    }
    XCTAssertFalse([playlist previous]);
    // Forward again retraces the same order.
    XCTAssertEqualObjects(WalkNext(playlist, 4), walk);
}

- (void)testPickingAnUnplayedRowContinuesWithoutRepeats {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(10, seed);
        NSMutableArray<TestRow *> *heard = [WalkNext(playlist, 3) mutableCopy];
        NSUInteger unplayed = 0;
        while ([heard containsObject:[playlist trackAtIndex:unplayed]]) {
            unplayed++;
        }
        playlist.currentIndex = unplayed;
        [heard addObjectsFromArray:WalkNext(playlist, 100)];
        AssertPermutation(playlist, heard);
    }
}

- (void)testPickingAPlayedRowReplaysItAndStillPlaysTheRest {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(10, seed);
        NSArray<TestRow *> *played = WalkNext(playlist, 4);
        playlist.currentIndex = (NSUInteger)[playlist getIndexForTrack:played[1]];
        NSArray<TestRow *> *rest = WalkNext(playlist, 100);
        XCTAssertEqual(rest.firstObject, played[1]);
        NSMutableSet<TestRow *> *heard = [NSMutableSet setWithArray:played];
        [heard addObjectsFromArray:rest];
        XCTAssertEqual(heard.count, playlist.count);
        // Only the replayed row is heard twice.
        XCTAssertEqual(played.count + rest.count, playlist.count + 1);
        // The history keeps the replay, not the slot it left.
        XCTAssertTrue([playlist previous]);
        XCTAssertNotEqual(playlist.currentTrack, played[1]);
    }
}

- (void)testAnOpenUnderShuffleStartsOnTheOrdersFirstRowAndMarksNothingPlayed {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = NumberedPlaylist(0);
        playlist.randomBelow = SeededRandom(seed);
        playlist.shuffleEnabled = YES;
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (NSUInteger i = 0; i < 9; i++) {
            [urls addObject:URLNamed([NSString stringWithFormat:@"%lu.mp3", (unsigned long)i])];
        }
        [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
        XCTAssertFalse(playlist.hasPreviousTrack);
        AssertPermutation(playlist, WalkNext(playlist, 100));

        [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:4];
        XCTAssertEqual(playlist.currentIndex, 4u);
        XCTAssertFalse(playlist.hasPreviousTrack);
        AssertPermutation(playlist, WalkNext(playlist, 100));
    }
}

- (void)testAnOpenWithShuffleOffLandsOnTheGivenRowOrTheFirst {
    VibePlaylist *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3")]) startingAtIndex:1];
    XCTAssertEqual(playlist.currentIndex, 1u);
    [playlist replaceAllWithTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3")]) startingAtIndex:7];
    XCTAssertEqual(playlist.currentIndex, 0u);
}

- (void)testAppendedRowsJoinTheUnplayedPart {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(6, seed);
        NSMutableArray<TestRow *> *heard = [WalkNext(playlist, 3) mutableCopy];
        [playlist appendTracks:Rows(@[URLNamed(@"x.mp3"), URLNamed(@"y.mp3"), URLNamed(@"z.mp3")])];
        [heard removeLastObject];
        [heard addObjectsFromArray:WalkNext(playlist, 100)];
        AssertPermutation(playlist, heard);
    }
}

- (void)testRemovingThePlayingRowLandsOnTheNextUnplayedOne {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(8, seed);
        NSMutableArray<TestRow *> *heard = [WalkNext(playlist, 3) mutableCopy];
        NSIndexSet *rows = RowSet(playlist.currentIndex);
        TestRow *forward = [playlist forwardTrackAfterRemovingTracksAtIndexes:rows];
        TestRow *peek = playlist.nextTrack;
        XCTAssertEqual(forward, peek);
        [playlist removeTracksAtIndexes:rows];
        XCTAssertEqual(playlist.currentTrack, forward);
        [heard removeLastObject];
        [heard addObjectsFromArray:WalkNext(playlist, 100)];
        AssertPermutation(playlist, heard);
    }
}

- (void)testRemovingThePlayingLastEntryLandsOnTheLastPlayed {
    VibePlaylist *playlist = ShuffledPlaylist(4, 5);
    NSArray<TestRow *> *walk = WalkNext(playlist, 100);
    NSIndexSet *rows = RowSet(playlist.currentIndex);
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:rows]);
    [playlist removeTracksAtIndexes:rows];
    XCTAssertEqual(playlist.currentTrack, walk[2]);
    XCTAssertFalse(playlist.hasNextTrack);
}

- (void)testRemovingOtherRowsAndUndoingKeepsEveryRowPlayingOnce {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(9, seed);
        NSMutableArray<TestRow *> *heard = [WalkNext(playlist, 4) mutableCopy];
        TestRow *playing = playlist.currentTrack;
        NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
        for (NSUInteger row = 0; row < playlist.count; row++) {
            if (row % 3 == 0 && row != playlist.currentIndex) {
                [rows addIndex:row];
            }
        }
        NSArray<TestRow *> *removed = [playlist removeTracksAtIndexes:rows];
        XCTAssertEqual(playlist.currentTrack, playing);
        [playlist insertTracks:removed atIndexes:rows];
        XCTAssertEqual(playlist.currentTrack, playing);
        // A restored row plays again only if it had not been heard.
        [heard removeLastObject];
        NSArray<TestRow *> *rest = WalkNext(playlist, 100);
        NSMutableSet<TestRow *> *all = [NSMutableSet setWithArray:heard];
        [all addObjectsFromArray:rest];
        XCTAssertEqual(all.count, playlist.count);
        for (TestRow *track in rest) {
            XCTAssertFalse([heard containsObject:track] && ![removed containsObject:track]);
        }
    }
}

- (void)testAMoveLeavesThePlayOrderAlone {
    VibePlaylist *a = ShuffledPlaylist(7, 9);
    VibePlaylist *b = ShuffledPlaylist(7, 9);
    WalkNext(a, 2);
    WalkNext(b, 2);
    XCTAssertTrue([a moveTracksAtIndexes:RowRange(0, 2) toIndexes:RowRange(5, 2)]);
    NSArray<TestRow *> *moved = WalkNext(a, 100);
    NSArray<TestRow *> *unmoved = WalkNext(b, 100);
    XCTAssertEqual(moved.count, unmoved.count);
    for (NSUInteger i = 0; i < moved.count; i++) {
        XCTAssertEqualObjects(moved[i].url, unmoved[i].url);
    }
}

- (void)testTheConvertSwapKeepsTheRowsPlaceInTheOrder {
    VibePlaylist *playlist = ShuffledPlaylist(6, 4);
    WalkNext(playlist, 2);
    TestRow *next = playlist.nextTrack;
    NSUInteger row = (NSUInteger)[playlist getIndexForTrack:next];
    TestRow *incoming = [next replacementAtURL:URLNamed(@"converted.flac")];
    XCTAssertTrue([playlist replaceTrackAtIndex:row withTrack:incoming]);
    XCTAssertEqual(playlist.nextTrack, incoming);
    NSArray<TestRow *> *rest = WalkNext(playlist, 100);
    XCTAssertEqual(rest.count, 5u);
    XCTAssertTrue([rest containsObject:incoming]);
}

// At a cycle's last entry under Repeat All, a gapless splice is armed on the
// next cycle's first. A file's replacement anywhere must not reshuffle that
// cycle out from under it. Replacing the armed row itself hands its slot on.
- (void)testTheConvertSwapKeepsTheNextCycleTheSpliceArmedOn {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(6, seed);
        playlist.repeatMode = VibeRepeatModeAll;
        WalkNext(playlist, 6);
        TestRow *armed = playlist.trackEndSuccessor;
        NSUInteger other = 0;
        while ([playlist trackAtIndex:other] == armed || other == playlist.currentIndex) {
            other++;
        }
        TestRow *converted = [TestRow withURL:URLNamed(@"other.flac")];
        [playlist replaceTrackAtIndex:other withTrack:converted];
        XCTAssertEqual(playlist.trackEndSuccessor, armed, @"seed %llu", seed);

        TestRow *incoming = [armed replacementAtURL:URLNamed(@"armed.flac")];
        [playlist replaceTrackAtIndex:(NSUInteger)[playlist getIndexForTrack:armed] withTrack:incoming];
        XCTAssertEqual(playlist.trackEndSuccessor, incoming, @"seed %llu", seed);
        XCTAssertTrue([playlist advanceFromTrack:playlist.currentTrack toTrack:incoming], @"seed %llu", seed);
        NSArray<TestRow *> *cycle = WalkNext(playlist, 6);
        AssertPermutation(playlist, cycle);
        XCTAssertTrue([cycle containsObject:converted], @"seed %llu", seed);
    }
}

- (void)testShuffleOffKeepsNoRowOfThePastOrders {
    VibePlaylist *playlist = nil;
    __weak TestRow *departed = nil;
    @autoreleasepool {
        playlist = ShuffledPlaylist(4, 3);
        playlist.repeatMode = VibeRepeatModeAll;
        WalkNext(playlist, 4);
        departed = playlist.nextTrack;
        XCTAssertNotNil(departed);
        playlist.shuffleEnabled = NO;
        [playlist replaceAllWithTracks:Rows(@[URLNamed(@"new.mp3")]) startingAtIndex:0];
    }
    XCTAssertNil(departed);
    XCTAssertEqual(playlist.count, 1u);
}

- (void)testShuffleOffResumesTheRowOrderFromTheCurrentRow {
    VibePlaylist *playlist = ShuffledPlaylist(8, 2);
    WalkNext(playlist, 3);
    NSUInteger row = playlist.currentIndex;
    playlist.shuffleEnabled = NO;
    XCTAssertEqual(playlist.currentIndex, row);
    XCTAssertEqual(playlist.nextTrack, [playlist trackAtIndex:row + 1]);
    XCTAssertEqual(playlist.hasPreviousTrack, row > 0);
}

- (void)testEnablingShuffleAgainKeepsTheOrder {
    VibePlaylist *playlist = ShuffledPlaylist(8, 6);
    TestRow *next = playlist.nextTrack;
    playlist.shuffleEnabled = YES;
    XCTAssertEqual(playlist.nextTrack, next);
}

- (void)testShuffledGaplessAdoptionRefusesTheRowNeighbor {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(6, seed);
        TestRow *current = playlist.currentTrack;
        TestRow *next = playlist.nextTrack;
        TestRow *neighbor = [playlist trackAtIndex:(playlist.currentIndex + 1) % 6];
        if (neighbor != next) {
            XCTAssertFalse([playlist advanceFromTrack:current toTrack:neighbor]);
        }
        XCTAssertTrue([playlist advanceFromTrack:current toTrack:next]);
        XCTAssertEqual(playlist.currentTrack, next);
    }
}

- (void)testAClearUnderShuffleStartsTheNextOpenFresh {
    VibePlaylist *playlist = ShuffledPlaylist(5, 8);
    WalkNext(playlist, 3);
    [playlist clear];
    XCTAssertNil(playlist.nextTrack);
    [playlist appendTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3"), URLNamed(@"c.mp3")])];
    XCTAssertEqual(playlist.currentIndex, 0u);
    AssertPermutation(playlist, WalkNext(playlist, 100));
}

#pragma mark - Saving and restoring the order

// A fresh queue holding playlist's rows and order, shuffled under another
// seed, so a fresh shuffle would differ from the saved one.
static VibePlaylist *RestoredPlaylist(VibePlaylist *playlist, uint64_t seed) {
    VibePlaylist *restored = NewPlaylist();
    restored.randomBelow = SeededRandom(seed + 1000);
    restored.shuffleEnabled = YES;
    restored.repeatMode = playlist.repeatMode;
    XCTAssertTrue([restored replaceAllWithTracks:playlist.tracks
                                       playOrder:playlist.playOrder
                                          cursor:playlist.playOrderCursor
                                   nextPlayOrder:playlist.nextPlayOrder]);
    return restored;
}

- (void)testARestoredOrderWalksAsTheSavedOneToTheCycleEnd {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(10, seed);
        NSArray<TestRow *> *played = WalkNext(playlist, 4);
        VibePlaylist *restored = RestoredPlaylist(playlist, seed);
        XCTAssertEqualObjects(restored.tracks, playlist.tracks);
        XCTAssertEqualObjects(restored.playOrder, playlist.playOrder);
        XCTAssertEqual(restored.playOrderCursor, 3u);
        XCTAssertEqual(restored.currentTrack, playlist.currentTrack);
        XCTAssertEqual(restored.currentIndex, playlist.currentIndex);

        NSArray<TestRow *> *rest = WalkNext(restored, 100);
        XCTAssertEqualObjects(rest, WalkNext(playlist, 100), @"seed %llu", seed);
        XCTAssertEqual(rest.count, 7u);
        // Played rows stay played: none of them comes round again this cycle.
        for (TestRow *row in [played subarrayWithRange:NSMakeRange(0, 3)]) {
            XCTAssertFalse([rest containsObject:row], @"seed %llu", seed);
        }
        XCTAssertNil(restored.nextTrack);
    }
}

- (void)testARestoredOrderRetracesItsHistory {
    VibePlaylist *playlist = ShuffledPlaylist(8, 5);
    NSArray<TestRow *> *played = WalkNext(playlist, 5);
    VibePlaylist *restored = RestoredPlaylist(playlist, 5);
    for (NSUInteger i = played.count - 1; i > 0; i--) {
        XCTAssertTrue([restored previous]);
        XCTAssertEqual(restored.currentTrack, played[i - 1]);
    }
    XCTAssertFalse(restored.hasPreviousTrack);
}

// At a cycle's last entry under Repeat All, a gapless splice is armed on the
// next cycle's first. The restore keeps that cycle, so the splice still lands.
- (void)testARestoredNextCycleKeepsTheArmedSplice {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(6, seed);
        playlist.repeatMode = VibeRepeatModeAll;
        XCTAssertNil(playlist.nextPlayOrder);
        WalkNext(playlist, 6);
        TestRow *armed = playlist.trackEndSuccessor;
        XCTAssertNotNil(playlist.nextPlayOrder);
        XCTAssertEqual(playlist.nextPlayOrder.firstObject, armed);

        VibePlaylist *restored = RestoredPlaylist(playlist, seed);
        XCTAssertEqualObjects(restored.nextPlayOrder, playlist.nextPlayOrder);
        XCTAssertEqual(restored.trackEndSuccessor, armed, @"seed %llu", seed);
        XCTAssertTrue([restored advanceFromTrack:restored.currentTrack toTrack:armed]);
        XCTAssertTrue([playlist advanceFromTrack:playlist.currentTrack toTrack:armed]);
        XCTAssertEqualObjects(WalkNext(restored, 6), WalkNext(playlist, 6), @"seed %llu", seed);
    }
}

- (void)testARestoreRefusesAnOrderThatIsNotThePermutationOfTheRows {
    VibePlaylist *playlist = ShuffledPlaylist(4, 2);
    WalkNext(playlist, 2);
    NSArray<TestRow *> *rows = playlist.tracks;
    NSArray<TestRow *> *order = playlist.playOrder;
    TestRow *stranger = [TestRow withURL:URLNamed(@"stranger.mp3")];
    // The same file, but another object: identity, not equality, decides.
    TestRow *lookalike = [TestRow withURL:order[0].url];
    NSArray<NSArray<TestRow *> *> *badOrders = @[
        [order subarrayWithRange:NSMakeRange(0, 3)],
        [order arrayByAddingObject:stranger],
        @[order[0], order[1], order[2], stranger],
        @[order[0], order[1], order[2], order[2]],
        @[lookalike, order[1], order[2], order[3]],
    ];

    VibePlaylist *restored = NewPlaylist();
    restored.randomBelow = SeededRandom(9);
    restored.shuffleEnabled = YES;
    NSArray<TestRow *> *kept = TracksNamed(@"a b c");
    [restored replaceAllWithTracks:kept startingAtIndex:1];
    NSArray<TestRow *> *keptOrder = restored.playOrder;
    RecordingObserver *observer = [RecordingObserver new];
    restored.observer = observer;
    NSUInteger generation = restored.structureGeneration;

    for (NSArray<TestRow *> *bad in badOrders) {
        XCTAssertFalse([restored replaceAllWithTracks:rows playOrder:bad cursor:1 nextPlayOrder:nil]);
    }
    XCTAssertFalse([restored replaceAllWithTracks:rows playOrder:order cursor:4 nextPlayOrder:nil]);
    XCTAssertFalse([restored replaceAllWithTracks:rows playOrder:order cursor:1
                                    nextPlayOrder:badOrders[3]]);
    XCTAssertFalse([restored replaceAllWithTracks:[rows arrayByAddingObject:rows[0]]
                                        playOrder:[order arrayByAddingObject:rows[0]]
                                           cursor:1 nextPlayOrder:nil]);
    XCTAssertFalse([restored replaceAllWithTracks:@[] playOrder:@[] cursor:1 nextPlayOrder:nil]);
    // Refused with shuffle off too.
    restored.shuffleEnabled = NO;
    XCTAssertFalse([restored replaceAllWithTracks:rows playOrder:badOrders[2] cursor:1 nextPlayOrder:nil]);
    restored.shuffleEnabled = YES;

    XCTAssertEqual(observer.events.count, 0u);
    XCTAssertEqual(restored.structureGeneration, generation);
    XCTAssertEqualObjects(restored.tracks, kept);
    XCTAssertEqual(restored.currentTrack, kept[1]);
    XCTAssertEqualObjects(restored.playOrder, keptOrder);
}

- (void)testARestoreWithShuffleOffLandsOnTheCursorRow {
    VibePlaylist *playlist = ShuffledPlaylist(5, 4);
    WalkNext(playlist, 3);
    TestRow *current = playlist.currentTrack;

    VibePlaylist *restored = NewPlaylist();
    RecordingObserver *observer = [RecordingObserver new];
    restored.observer = observer;
    XCTAssertTrue([restored replaceAllWithTracks:playlist.tracks
                                       playOrder:playlist.playOrder
                                          cursor:playlist.playOrderCursor
                                   nextPlayOrder:nil]);
    XCTAssertEqualObjects(observer.events, @[@"replaceAll"]);
    XCTAssertEqual(restored.currentTrack, current);
    XCTAssertNil(restored.playOrder);
    XCTAssertEqual(restored.playOrderCursor, 0u);
    XCTAssertEqual(restored.nextTrack, [restored trackAtIndex:restored.currentIndex + 1]);
}

- (void)testARestoreOfNoRowsEmptiesTheQueue {
    VibePlaylist *playlist = ShuffledPlaylist(3, 1);
    XCTAssertTrue([playlist replaceAllWithTracks:@[] playOrder:@[] cursor:0 nextPlayOrder:nil]);
    XCTAssertEqual(playlist.count, 0u);
    XCTAssertEqualObjects(playlist.playOrder, @[]);
    XCTAssertNil(playlist.nextTrack);
    [playlist appendTracks:TracksNamed(@"a b")];
    AssertPermutation(playlist, WalkNext(playlist, 100));
}


#pragma mark - Looking ahead

// Every step the lookahead answers, from 0 until its first nil or limit.
static NSArray<TestRow *> *LookAhead(VibePlaylist *playlist, NSUInteger limit) {
    NSMutableArray<TestRow *> *ahead = [NSMutableArray array];
    for (NSUInteger step = 0; step < limit; step++) {
        TestRow *track = [playlist trackAtStep:step];
        if (!track) {
            break;
        }
        [ahead addObject:track];
    }
    return ahead;
}

- (void)testLookingAheadReadsTheRowsAndMovesNothing {
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeOne)]) {
        VibePlaylist *playlist = NumberedPlaylist(4);
        playlist.repeatMode = mode.integerValue;
        playlist.currentIndex = 1;
        RecordingObserver *observer = [RecordingObserver new];
        playlist.observer = observer;

        // One changes only the track end, so the lookahead walks as under Off.
        XCTAssertEqualObjects(LookAhead(playlist, 10), [playlist.tracks subarrayWithRange:NSMakeRange(1, 3)]);
        XCTAssertEqual([playlist trackAtStep:1], playlist.nextTrack);
        XCTAssertNil([playlist trackAtStep:3]);
        XCTAssertNil([playlist trackAtStep:NSUIntegerMax]);
        XCTAssertEqual(playlist.currentIndex, 1u);
        XCTAssertEqual(observer.events.count, 0u);
    }
}

- (void)testRepeatAllLookAheadWrapsTheRowsWithoutEnd {
    VibePlaylist *playlist = NumberedPlaylist(3);
    playlist.repeatMode = VibeRepeatModeAll;
    playlist.currentIndex = 2;
    for (NSUInteger step = 0; step < 10; step++) {
        XCTAssertEqual([playlist trackAtStep:step], [playlist trackAtIndex:(2 + step) % 3]);
    }
    XCTAssertEqual([playlist trackAtStep:NSUIntegerMax], [playlist trackAtIndex:(2 + NSUIntegerMax % 3) % 3]);
    XCTAssertEqual(playlist.currentIndex, 2u);
}

- (void)testLookingAheadOnEmptyAndSingleRowQueues {
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        for (NSNumber *shuffle in @[@NO, @YES]) {
            VibePlaylist *empty = NumberedPlaylist(0);
            empty.repeatMode = mode.integerValue;
            empty.shuffleEnabled = shuffle.boolValue;
            XCTAssertNil([empty trackAtStep:0]);
            XCTAssertNil([empty trackAtStep:1]);

            VibePlaylist *single = NumberedPlaylist(1);
            single.repeatMode = mode.integerValue;
            single.shuffleEnabled = shuffle.boolValue;
            TestRow *only = single.currentTrack;
            XCTAssertEqual([single trackAtStep:0], only);
            if (mode.integerValue == VibeRepeatModeAll) {
                XCTAssertEqual([single trackAtStep:1], only);
            }
            else {
                XCTAssertNil([single trackAtStep:1]);
            }
        }
    }
}

- (void)testShuffledLookAheadReadsTheOrderAndMakesNoCycleItDoesNotReach {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(8, seed);
        WalkNext(playlist, 3);
        NSArray<TestRow *> *order = playlist.playOrder;
        XCTAssertEqualObjects(LookAhead(playlist, 100), [order subarrayWithRange:NSMakeRange(2, 6)]);
        XCTAssertNil([playlist trackAtStep:NSUIntegerMax]);

        // Under Repeat All, a read inside this cycle makes no next one.
        playlist.repeatMode = VibeRepeatModeAll;
        for (NSUInteger step = 0; step <= 5; step++) {
            XCTAssertEqual([playlist trackAtStep:step], order[2 + step]);
        }
        XCTAssertNil(playlist.nextPlayOrder);
        XCTAssertEqualObjects(playlist.playOrder, order);
        XCTAssertEqual(playlist.playOrderCursor, 2u);
    }
}

- (void)testShuffledRepeatAllLookAheadReachesIntoTheNextCycleAndKeepsIt {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(6, seed);
        playlist.repeatMode = VibeRepeatModeAll;
        WalkNext(playlist, 3);
        RecordingObserver *observer = [RecordingObserver new];
        playlist.observer = observer;
        NSArray<TestRow *> *order = playlist.playOrder;
        NSUInteger current = playlist.currentIndex;

        // Three left in this cycle, then the next one whole, then nothing.
        TestRow *first = [playlist trackAtStep:4];
        NSArray<TestRow *> *next = playlist.nextPlayOrder;
        XCTAssertEqual(next.count, 6u);
        XCTAssertEqual(first, next.firstObject);
        XCTAssertNotEqual(first, order.lastObject);
        for (NSUInteger step = 4; step <= 9; step++) {
            XCTAssertEqual([playlist trackAtStep:step], next[step - 4]);
        }
        XCTAssertNil([playlist trackAtStep:10]);
        XCTAssertNil([playlist trackAtStep:NSUIntegerMax]);
        for (NSUInteger step = 1; step <= playlist.count; step++) {
            XCTAssertNotNil([playlist trackAtStep:step]);
        }

        // The read made the cycle once. Nothing else moved.
        XCTAssertEqualObjects(playlist.nextPlayOrder, next);
        XCTAssertEqualObjects(playlist.playOrder, order);
        XCTAssertEqual(playlist.playOrderCursor, 2u);
        XCTAssertEqual(playlist.currentIndex, current);
        XCTAssertEqual(observer.events.count, 0u);
    }
}

// A row played this cycle comes back only in the next one, after any rows
// the two cycles share. So count steps can miss it, and a scan for a row to
// play runs to the first nil.
- (void)testAShuffledScanReachesEveryRowOnlyByTheFirstNil {
    NSArray<TestRow *> *rows = TracksNamed(@"a b c d");
    VibePlaylist *playlist = NewPlaylist();
    playlist.shuffleEnabled = YES;
    playlist.repeatMode = VibeRepeatModeAll;
    NSArray<TestRow *> *nextOrder = @[rows[2], rows[3], rows[0], rows[1]];
    XCTAssertTrue([playlist replaceAllWithTracks:rows playOrder:rows cursor:1 nextPlayOrder:nextOrder]);
    NSArray<TestRow *> *firstCount = [LookAhead(playlist, playlist.count + 1)
                                      subarrayWithRange:NSMakeRange(1, playlist.count)];
    XCTAssertEqualObjects(NamesOf(firstCount), @"c d c d");
    XCTAssertEqual([playlist trackAtStep:5], rows[0]);

    for (NSUInteger count = 1; count <= 6; count++) {
        for (uint64_t seed = 1; seed <= 20; seed++) {
            for (NSUInteger played = 1; played <= count; played++) {
                VibePlaylist *shuffled = ShuffledPlaylist(count, seed);
                shuffled.repeatMode = VibeRepeatModeAll;
                WalkNext(shuffled, played);
                NSArray<TestRow *> *ahead = LookAhead(shuffled, 100);
                XCTAssertNil([shuffled trackAtStep:ahead.count]);
                NSArray<TestRow *> *scan = [ahead subarrayWithRange:NSMakeRange(1, ahead.count - 1)];
                XCTAssertTrue([[NSSet setWithArray:scan] isEqualToSet:[NSSet setWithArray:shuffled.tracks]],
                              @"%lu rows, seed %llu, %lu played", (unsigned long)count, seed, (unsigned long)played);
            }
        }
    }
}

- (void)testLookingAheadThenAdvancingLandsOnTheSameTracks {
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        for (NSNumber *shuffle in @[@NO, @YES]) {
            for (uint64_t seed = 1; seed <= 10; seed++) {
                VibePlaylist *playlist = NumberedPlaylist(7);
                playlist.randomBelow = SeededRandom(seed);
                playlist.repeatMode = mode.integerValue;
                playlist.currentIndex = seed % 7;
                playlist.shuffleEnabled = shuffle.boolValue;
                WalkNext(playlist, 3);

                NSArray<TestRow *> *ahead = LookAhead(playlist, 30);
                XCTAssertEqualObjects(WalkNext(playlist, ahead.count), ahead,
                                      @"mode %@, shuffle %@, seed %llu", mode, shuffle, seed);
                if (mode.integerValue != VibeRepeatModeAll) {
                    XCTAssertFalse(playlist.hasNextTrack);
                }
            }
        }
    }
}

// The lookahead made the next cycle, so a save carries it, and the restored
// queue looks ahead and walks into exactly that cycle.
- (void)testALookedAheadCycleSurvivesSaveAndRestore {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        VibePlaylist *playlist = ShuffledPlaylist(6, seed);
        playlist.repeatMode = VibeRepeatModeAll;
        WalkNext(playlist, 2);
        NSArray<TestRow *> *ahead = LookAhead(playlist, 100);
        XCTAssertEqual(ahead.count, 11u);
        XCTAssertNotNil(playlist.nextPlayOrder);

        VibePlaylist *restored = RestoredPlaylist(playlist, seed);
        XCTAssertEqualObjects(restored.nextPlayOrder, playlist.nextPlayOrder);
        XCTAssertEqualObjects(LookAhead(restored, 100), ahead, @"seed %llu", seed);
        XCTAssertEqualObjects(WalkNext(restored, ahead.count), ahead, @"seed %llu", seed);
    }
}

// Each step is index arithmetic, so a scan over every step of a large queue
// is linear. A walk per step would be quadratic, far past the bound.
- (void)testLookingAheadThroughALargeQueueStaysFast {
    VibePlaylist *playlist = ShuffledPlaylist(100000, 1);
    playlist.repeatMode = VibeRepeatModeAll;
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSUInteger answered = 0;
    for (NSUInteger step = 1; step <= 2 * playlist.count; step++) {
        answered += [playlist trackAtStep:step] != nil;
    }
    double elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6;
    XCTAssertEqual(answered, 2 * playlist.count - 1);
    XCTAssertLessThan(elapsed, 1000.0);
    XCTAssertEqual(playlist.playOrderCursor, 0u);
}

@end
