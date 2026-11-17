//
//  OpenRequestCoordinator.m
//  vibe-libs
//

#import "OpenRequestCoordinator.h"

// Not a bound on expansion: nothing is armed until a LATER batch has finished.
// How long a finished result waits behind an earlier one.
static const NSTimeInterval kStragglerDeadline = 10.0;

@interface OpenRequestToken : NSObject
@property NSUInteger openGeneration;
@property NSUInteger sequence;
@property BOOL append;
// A part has delivered, so everything after it appends.
@property BOOL delivered;
@property (copy) OpenRequestDelivery delivery;
@end

@implementation OpenRequestToken
@end

@interface OpenRequestResult : NSObject
@property (strong) OpenRequestToken *token;
// Parts not yet delivered, oldest first.
@property (strong) NSMutableArray<NSArray *> *parts;
@property BOOL finished;
@property (copy) NSArray *rows;
@property NSUInteger folderCount;
@end

@implementation OpenRequestResult
@end

@implementation OpenRequestCoordinator {
    NSUInteger _openGeneration;
    NSUInteger _nextSequence;
    NSUInteger _nextDeliverySequence;
    NSMutableDictionary<NSNumber *, OpenRequestResult *> *_completed;
    // One armed deadline per missing head. 0 is none; generations start at 1
    // and only ever climb.
    NSUInteger _armedDeadlineGeneration;
    NSUInteger _armedDeadlineSequence;
    // Stamps each armed deadline. Only the latest timer acts, so one a
    // release re-armed for the same request leaves the older nothing to do.
    NSUInteger _deadlineTimerGeneration;
    // The current generation's held requests, by sequence (holdRequest:).
    NSMutableIndexSet *_heldSequences;
}

+ (instancetype)sharedCoordinator {
    static OpenRequestCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[OpenRequestCoordinator alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 1, not 0: the armed-deadline state uses 0 as none.
        _openGeneration = 1;
        _completed = [NSMutableDictionary dictionary];
        _heldSequences = [NSMutableIndexSet indexSet];
        _deadlineScheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), block);
        };
    }
    return self;
}

- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    _openGeneration++;
    _nextSequence = 0;
    _nextDeliverySequence = 0;
    [_completed removeAllObjects];
    [_heldSequences removeAllIndexes];
}

- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (!append) {
        [self invalidate];
    }
    OpenRequestToken *token = [OpenRequestToken new];
    token.openGeneration = _openGeneration;
    token.sequence = _nextSequence++;
    token.append = append;
    token.delivery = delivery;
    return token;
}

- (BOOL)isRequestCurrent:(OpenRequestToken *)token {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    return token && token.openGeneration == _openGeneration;
}

// nil once the request finished, was superseded, or was given up on.
- (OpenRequestResult *)openResultForRequest:(OpenRequestToken *)token {
    if (![self isRequestCurrent:token] || token.sequence < _nextDeliverySequence) {
        return nil;
    }
    OpenRequestResult *result = _completed[@(token.sequence)];
    if (!result) {
        result = [OpenRequestResult new];
        result.token = token;
        result.parts = [NSMutableArray array];
        _completed[@(token.sequence)] = result;
    }
    return result.finished ? nil : result;
}

- (void)deliverPartOfRequest:(OpenRequestToken *)token rows:(NSArray *)rows {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (rows.count == 0) {
        return;
    }
    OpenRequestResult *result = [self openResultForRequest:token];
    if (!result) {
        return;
    }
    [result.parts addObject:rows];
    // A head that sends parts is not stalled, so what waits behind it gets a
    // full deadline from now.
    if (token.sequence == _nextDeliverySequence) {
        _armedDeadlineGeneration = 0;
    }
    [self deliverReadyResults];
    [self armStragglerDeadlineIfBuffered];
}

- (void)finishRequest:(OpenRequestToken *)token
                 rows:(NSArray *)rows
          folderCount:(NSUInteger)folderCount {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    OpenRequestResult *result = [self openResultForRequest:token];
    if (!result) {
        return;
    }
    result.finished = YES;
    result.rows = rows;
    result.folderCount = folderCount;
    [self deliverReadyResults];
    [self armStragglerDeadlineIfBuffered];
}

// TRAP: a head still sending parts has a result but is not stalled. Arming
// for it alone would cut a long walk off after the deadline.
- (void)armStragglerDeadlineIfBuffered {
    NSUInteger head = _completed[@(_nextDeliverySequence)] ? 1 : 0;
    if (_completed.count > head) {
        [self armStragglerDeadline];
    }
}

- (void)holdRequest:(OpenRequestToken *)token {
    if ([self isRequestCurrent:token]) {
        [_heldSequences addIndex:token.sequence];
    }
}

- (void)releaseRequest:(OpenRequestToken *)token {
    if (![self isRequestCurrent:token] || ![_heldSequences containsIndex:token.sequence]) {
        return;
    }
    [_heldSequences removeIndex:token.sequence];
    // The head gets a full deadline from now for what it opens next. One
    // armed while it was held may be nearly spent, and one that found it held
    // did not re-arm.
    if (token.sequence == _nextDeliverySequence) {
        _armedDeadlineGeneration = 0;
        [self armStragglerDeadlineIfBuffered];
    }
}

- (void)abandonStalledRequests {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    NSUInteger head = _completed[@(_nextDeliverySequence)] ? 1 : 0;
    if (_completed.count == head || [_heldSequences containsIndex:_nextDeliverySequence]) {
        return;
    }
    // Only the head: the ones behind it may be slow rather than wedged, and a
    // skipped request's late parts and result are dropped by the sequence
    // check. The head is missing, or still sending parts. Its rows already
    // delivered stay.
    [_completed removeObjectForKey:@(_nextDeliverySequence)];
    _nextDeliverySequence++;
    [self deliverReadyResults];
    // Nothing else re-arms for a gap still buffered.
    [self armStragglerDeadlineIfBuffered];
}

- (void)deliverReadyResults {
    while (YES) {
        NSNumber *key = @(_nextDeliverySequence);
        OpenRequestResult *next = _completed[key];
        if (!next) {
            break;
        }
        OpenRequestToken *token = next.token;
        while (next.parts.count > 0) {
            NSArray *part = next.parts.firstObject;
            [next.parts removeObjectAtIndex:0];
            BOOL append = token.append || token.delivered;
            token.delivered = YES;
            token.delivery(part, 0, append);
            // The delivery may have begun a replacing request.
            if (![self isRequestCurrent:token]) {
                return;
            }
        }
        if (!next.finished) {
            break;
        }
        [_completed removeObjectForKey:key];
        _nextDeliverySequence++;
        token.delivery(next.rows, next.folderCount, token.append || token.delivered);
    }
}

- (void)armStragglerDeadline {
    NSUInteger generation = _openGeneration;
    NSUInteger missingSequence = _nextDeliverySequence;
    if (_armedDeadlineGeneration == generation &&
            _armedDeadlineSequence == missingSequence) {
        return;
    }
    _armedDeadlineGeneration = generation;
    _armedDeadlineSequence = missingSequence;
    NSUInteger timerGeneration = ++_deadlineTimerGeneration;
    __weak OpenRequestCoordinator *weakSelf = self;
    _deadlineScheduler(kStragglerDeadline, ^{
        OpenRequestCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // TRAP: a replacement or a later gap may have armed its own deadline;
        // disarming here would strand that missing request.
        if (strongSelf->_deadlineTimerGeneration != timerGeneration) {
            return;
        }
        strongSelf->_armedDeadlineGeneration = 0;
        if (strongSelf->_openGeneration != generation ||
                strongSelf->_nextDeliverySequence != missingSequence) {
            return;
        }
        [strongSelf abandonStalledRequests];
    });
}

@end

#if DEBUG
#import "OpenRequestCoordinator+Debug.h"

@implementation OpenRequestCoordinator (Debug)

- (NSUInteger)debugBufferedResultCount {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    return _completed.count;
}

@end
#endif
