//
// Open expansion may finish out of order, or never: burst ordering,
// replacement supersession, giving up on a straggler, and a request in parts.
//

#import <XCTest/XCTest.h>

#import "OpenRequestCoordinator.h"
#import "OpenRequestCoordinator+Debug.h"

@interface OpenRequestCoordinatorTests : XCTestCase
@end

@implementation OpenRequestCoordinatorTests {
    OpenRequestCoordinator *_coordinator;
    NSMutableArray<NSString *> *_deliveries;
    // The deadlines armed, oldest first. A deadline elapses only when a test
    // fires it, so no test waits on the clock.
    NSMutableArray<dispatch_block_t> *_deadlines;
}

- (void)setUp {
    [super setUp];
    _deliveries = [NSMutableArray array];
    _deadlines = [NSMutableArray array];
    _coordinator = [[OpenRequestCoordinator alloc] init];
    NSMutableArray<dispatch_block_t> *deadlines = _deadlines;
    _coordinator.deadlineScheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
        [deadlines addObject:block];
    };
}

- (void)fireNextDeadline {
    dispatch_block_t deadline = _deadlines.firstObject;
    XCTAssertNotNil(deadline, @"no deadline armed");
    [_deadlines removeObjectAtIndex:0];
    deadline();
}

// Records deliveries so assertions read as the sequence the list sees.
- (OpenRequestToken *)beginAppending:(BOOL)append tagged:(NSString *)tag {
    NSMutableArray<NSString *> *deliveries = _deliveries;
    return [_coordinator beginRequestAppending:append
                                      delivery:^(NSArray *rows, NSUInteger folders, BOOL appending) {
        [deliveries addObject:[NSString stringWithFormat:@"%@:%@:%lu:%lu", tag,
                appending ? @"append" : @"replace",
                (unsigned long)rows.count, (unsigned long)folders]];
    }];
}

// The coordinator never reads a row, so any object stands in for one.
static NSArray<NSURL *> *OpenRows(NSUInteger count) {
    NSMutableArray<NSURL *> *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [rows addObject:[NSURL fileURLWithPath:
                [NSString stringWithFormat:@"/private/tmp/open-%lu.mp3", (unsigned long)i]]];
    }
    return rows;
}

- (void)testAppendWaitsForEarlierReplacement {
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"second"];
    [_coordinator finishRequest:append rows:OpenRows(1) folderCount:0];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:replacement rows:OpenRows(2) folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:2:1", @"second:append:1:0"]));
}

- (void)testNewReplacementSupersedesAStalledGeneration {
    OpenRequestToken *stalled = [self beginAppending:NO tagged:@"stalled"];
    OpenRequestToken *stalledAppend = [self beginAppending:YES tagged:@"stalledAppend"];
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"replacement"];
    XCTAssertFalse([_coordinator isRequestCurrent:stalled]);
    XCTAssertFalse([_coordinator isRequestCurrent:stalledAppend]);
    XCTAssertTrue([_coordinator isRequestCurrent:replacement]);

    [_coordinator finishRequest:replacement rows:OpenRows(1) folderCount:0];
    [_coordinator finishRequest:stalled rows:OpenRows(3) folderCount:1];
    [_coordinator finishRequest:stalledAppend rows:OpenRows(2) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"replacement:replace:1:0"]));
}

- (void)testEmptyResultStillUnblocksFollowingAppend {
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"second"];
    [_coordinator finishRequest:append rows:OpenRows(1) folderCount:0];
    [_coordinator finishRequest:replacement rows:@[] folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:0:1", @"second:append:1:0"]));
}

- (void)testCloseDropsPendingAndBufferedOpensAndAllowsANewAppend {
    OpenRequestToken *walking = [self beginAppending:NO tagged:@"walking"];
    OpenRequestToken *buffered = [self beginAppending:YES tagged:@"buffered"];
    [_coordinator finishRequest:buffered rows:OpenRows(1) folderCount:0];
    [_coordinator invalidate];
    XCTAssertFalse([_coordinator isRequestCurrent:walking]);
    XCTAssertFalse([_coordinator isRequestCurrent:buffered]);
    [_coordinator finishRequest:walking rows:OpenRows(2) folderCount:1];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);

    OpenRequestToken *fresh = [self beginAppending:YES tagged:@"fresh"];
    [_coordinator finishRequest:fresh rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"fresh:append:1:0"]));
}

// The first batch's walk hangs on a mount that never answers; without the
// deadline every later batch in the burst would buffer unseen.
- (void)testAStragglerIsAbandonedRatherThanHoldingItsBurst {
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *second = [self beginAppending:YES tagged:@"second"];
    OpenRequestToken *third = [self beginAppending:YES tagged:@"third"];
    [_coordinator finishRequest:third rows:OpenRows(3) folderCount:0];
    [_coordinator finishRequest:second rows:OpenRows(2) folderCount:0];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator abandonStalledRequests];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"third:append:3:0"]));

    // A late answer is dropped rather than reordering the list.
    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"third:append:3:0"]));
}

- (void)testASlowWalkBehindAWedgedOneStillDelivers {
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *slow = [self beginAppending:YES tagged:@"slow"];
    OpenRequestToken *third = [self beginAppending:YES tagged:@"third"];
    [_coordinator finishRequest:third rows:OpenRows(3) folderCount:0];

    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator finishRequest:slow rows:OpenRows(2) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"slow:append:2:0", @"third:append:3:0"]));

    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqual(_deliveries.count, 2u);
}

// Once the first gap is abandoned, the second wedged walk is a gap of its own
// that only a re-armed deadline frees.
- (void)testASecondStragglerGetsItsOwnDeadline {
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *second = [self beginAppending:YES tagged:@"second"];
    [self beginAppending:YES tagged:@"alsoWedged"];
    OpenRequestToken *fourth = [self beginAppending:YES tagged:@"fourth"];
    [_coordinator finishRequest:second rows:OpenRows(2) folderCount:0];
    [_coordinator finishRequest:fourth rows:OpenRows(4) folderCount:0];
    XCTAssertEqual(_deadlines.count, 1u, @"one deadline per missing head");

    [self fireNextDeadline];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0"]));
    XCTAssertEqual(_deadlines.count, 1u, @"re-armed for the second gap");

    [self fireNextDeadline];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"fourth:append:4:0"]));

    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqual(_deliveries.count, 2u);
}

// The older timer exits on the generation mismatch, so a replacement that
// inherited its arming would wait for a deadline that never comes.
- (void)testAReplacementGetsItsOwnDeadlineWhileAnOlderOneIsArmed {
    [self beginAppending:NO tagged:@"oldWedged"];
    OpenRequestToken *oldSecond = [self beginAppending:YES tagged:@"oldSecond"];
    [_coordinator finishRequest:oldSecond rows:OpenRows(2) folderCount:0];

    [self beginAppending:NO tagged:@"newWedged"];
    OpenRequestToken *newSecond = [self beginAppending:YES tagged:@"newSecond"];
    [_coordinator finishRequest:newSecond rows:OpenRows(5) folderCount:0];
    XCTAssertEqual(_deadlines.count, 2u, @"the replacement armed its own");

    [self fireNextDeadline];   // the old generation's: a no-op
    XCTAssertEqual(_deliveries.count, 0u);
    [self fireNextDeadline];
    XCTAssertEqualObjects(_deliveries, (@[@"newSecond:append:5:0"]));
}

// A gap that drains before its deadline leaves the old timer in flight.
- (void)testALaterGapDoesNotInheritADrainedGapsDeadline {
    OpenRequestToken *first = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *firstAppend = [self beginAppending:YES tagged:@"firstAppend"];
    [_coordinator finishRequest:firstAppend rows:OpenRows(2) folderCount:0];
    XCTAssertEqual(_deadlines.count, 1u);
    [_coordinator finishRequest:first rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:1:0", @"firstAppend:append:2:0"]));

    OpenRequestToken *laterWedged = [self beginAppending:YES tagged:@"laterWedged"];
    OpenRequestToken *laterAppend = [self beginAppending:YES tagged:@"laterAppend"];
    [_coordinator finishRequest:laterAppend rows:OpenRows(4) folderCount:0];
    XCTAssertEqual(_deadlines.count, 2u, @"the later gap armed a deadline of its own");

    [self fireNextDeadline];   // the drained gap's, still in flight: a no-op
    XCTAssertEqual(_deliveries.count, 2u);
    [self fireNextDeadline];
    XCTAssertEqualObjects(_deliveries, (@[
        @"first:replace:1:0",
        @"firstAppend:append:2:0",
        @"laterAppend:append:4:0",
    ]));

    [_coordinator finishRequest:laterWedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqual(_deliveries.count, 3u);
}

// A dropped link still resolving is held. A later append that finishes first
// waits for it, and the deadline gives up on nothing.
- (void)testAHeldRequestIsNeverAbandoned {
    OpenRequestToken *links = [self beginAppending:YES tagged:@"links"];
    [_coordinator holdRequest:links];
    OpenRequestToken *files = [self beginAppending:YES tagged:@"files"];
    [_coordinator finishRequest:files rows:OpenRows(2) folderCount:0];

    [self fireNextDeadline];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator releaseRequest:links];
    [_coordinator finishRequest:links rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"links:append:1:0", @"files:append:2:0"]));
}

// The release starts a whole deadline for what the head opens next, and that
// deadline still frees a head whose expansion then wedges.
- (void)testAReleasedRequestGetsAFullDeadline {
    OpenRequestToken *links = [self beginAppending:YES tagged:@"links"];
    [_coordinator holdRequest:links];
    OpenRequestToken *files = [self beginAppending:YES tagged:@"files"];
    [_coordinator finishRequest:files rows:OpenRows(2) folderCount:0];
    XCTAssertEqual(_deadlines.count, 1u);

    [_coordinator releaseRequest:links];
    XCTAssertEqual(_deadlines.count, 2u, @"the release armed a whole deadline");
    [self fireNextDeadline];   // the one armed before the release: a no-op
    XCTAssertEqual(_deliveries.count, 0u, @"not the deadline armed before the release");
    [self fireNextDeadline];
    XCTAssertEqualObjects(_deliveries, (@[@"files:append:2:0"]));

    [_coordinator finishRequest:links rows:OpenRows(1) folderCount:0];
    XCTAssertEqual(_deliveries.count, 1u);
}

// A hold belongs to its generation. A replacement drops it, and a release of
// the superseded token holds nothing up.
- (void)testAReplacementDropsAHold {
    OpenRequestToken *links = [self beginAppending:NO tagged:@"links"];
    [_coordinator holdRequest:links];
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *files = [self beginAppending:YES tagged:@"files"];
    [_coordinator finishRequest:files rows:OpenRows(2) folderCount:0];
    [_coordinator releaseRequest:links];

    [_coordinator abandonStalledRequests];
    XCTAssertEqualObjects(_deliveries, (@[@"files:append:2:0"]));
    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:0];
    XCTAssertEqual(_deliveries.count, 1u);
}

- (void)testAbandonIsANoOpWithNothingWaiting {
    OpenRequestToken *only = [self beginAppending:NO tagged:@"only"];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:only rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"only:replace:1:0"]));
}

- (void)testAFirstAppendIsNotRewrittenIntoAReplacement {
    OpenRequestToken *append = [self beginAppending:YES tagged:@"first"];
    [_coordinator finishRequest:append rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:append:1:0"]));
}

- (void)testAHeadsPartsDeliverAtOnceAndThenAppend {
    OpenRequestToken *walk = [self beginAppending:NO tagged:@"walk"];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    XCTAssertEqualObjects(_deliveries, (@[@"walk:replace:1:0"]));
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(3)];
    [_coordinator finishRequest:walk rows:@[] folderCount:2];
    XCTAssertEqualObjects(_deliveries, (@[@"walk:replace:1:0", @"walk:append:3:0", @"walk:append:0:2"]));
}

- (void)testAnAppendWaitsBehindAHeadStillSendingParts {
    OpenRequestToken *walk = [self beginAppending:NO tagged:@"walk"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"append"];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    [_coordinator finishRequest:append rows:OpenRows(2) folderCount:0];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(4)];
    XCTAssertEqualObjects(_deliveries, (@[@"walk:replace:1:0", @"walk:append:4:0"]));
    [_coordinator finishRequest:walk rows:@[] folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"walk:replace:1:0", @"walk:append:4:0", @"walk:append:0:1",
                                          @"append:append:2:0"]));
}

- (void)testALaterRequestsPartsWaitForTheEarlierFinish {
    OpenRequestToken *first = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *second = [self beginAppending:YES tagged:@"second"];
    [_coordinator deliverPartOfRequest:second rows:OpenRows(1)];
    [_coordinator deliverPartOfRequest:second rows:OpenRows(2)];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:first rows:OpenRows(3) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:3:0", @"second:append:1:0", @"second:append:2:0"]));
    [_coordinator finishRequest:second rows:@[] folderCount:1];
    XCTAssertEqualObjects(_deliveries.lastObject, @"second:append:0:1");
}

- (void)testAHeadSendingPartsArmsNoDeadlineAlone {
    OpenRequestToken *walk = [self beginAppending:NO tagged:@"walk"];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    XCTAssertEqual(_deadlines.count, 0u);
    [_coordinator abandonStalledRequests];
    [_coordinator finishRequest:walk rows:OpenRows(1) folderCount:1];
    XCTAssertEqualObjects(_deliveries.lastObject, @"walk:append:1:1");
}

- (void)testEachPartRestartsTheDeadlineOfWhatWaitsBehind {
    OpenRequestToken *walk = [self beginAppending:NO tagged:@"walk"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"append"];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    [_coordinator finishRequest:append rows:OpenRows(2) folderCount:0];
    XCTAssertEqual(_deadlines.count, 1u);
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    XCTAssertEqual(_deadlines.count, 2u);
    // The older deadline is stale and gives up on nothing.
    [self fireNextDeadline];
    XCTAssertEqual(_deliveries.count, 2u);
    [self fireNextDeadline];
    XCTAssertEqualObjects(_deliveries.lastObject, @"append:append:2:0");
    // The walk was given up on, so its rest is dropped.
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(5)];
    [_coordinator finishRequest:walk rows:OpenRows(1) folderCount:1];
    XCTAssertEqual(_deliveries.count, 3u);
}

- (void)testPartsOfASupersededOrFinishedRequestAreDropped {
    OpenRequestToken *old = [self beginAppending:NO tagged:@"old"];
    OpenRequestToken *walk = [self beginAppending:NO tagged:@"walk"];
    [_coordinator deliverPartOfRequest:old rows:OpenRows(1)];
    [_coordinator deliverPartOfRequest:walk rows:@[]];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:walk rows:OpenRows(2) folderCount:0];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    XCTAssertEqualObjects(_deliveries, (@[@"walk:replace:2:0"]));
}

- (void)testAPartsDeliveryThatBeginsAReplacementStopsTheOlderParts {
    OpenRequestCoordinator *coordinator = _coordinator;
    NSMutableArray<NSString *> *deliveries = _deliveries;
    OpenRequestToken *first = [self beginAppending:NO tagged:@"first"];
    __block NSUInteger parts = 0;
    OpenRequestToken *walk = [_coordinator beginRequestAppending:YES
                                                        delivery:^(NSArray *rows, NSUInteger folders, BOOL appending) {
        [deliveries addObject:[NSString stringWithFormat:@"walk:%lu", (unsigned long)rows.count]];
        if (++parts == 1) {
            [coordinator beginRequestAppending:NO delivery:^(NSArray *r, NSUInteger f, BOOL a) {}];
        }
    }];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(1)];
    [_coordinator deliverPartOfRequest:walk rows:OpenRows(2)];
    [_coordinator finishRequest:first rows:OpenRows(3) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:3:0", @"walk:1"]));
    XCTAssertEqual(_coordinator.debugBufferedResultCount, 0u);
}

@end
