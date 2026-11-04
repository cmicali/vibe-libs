//
//  ArchivedArtShare.m
//  vibe-libs
//

#import "ArchivedArtShare.h"

#import <os/lock.h>
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

#import "NSURL+Hash.h"

const NSUInteger kVibeArchivedArtShareCount = 16;

// One picture's forms, or the promise of them while a parse makes them.
@interface VibeArchivedArtEntry : NSObject
@property (nonatomic, readonly) dispatch_group_t made;
@property (nonatomic, nullable) NSData *thumbnail;
@property (nonatomic, nullable) NSData *rendition;
@end

@implementation VibeArchivedArtEntry
- (instancetype)init {
    self = [super init];
    if (self) {
        _made = dispatch_group_create();
    }
    return self;
}
@end

// How long it keeps its pictures after their last use, so a scan's covers
// are not held at rest.
static const int64_t kVibeArchivedArtShareIdleNS = 30 * NSEC_PER_SEC;

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static uint64_t sLastUse;
static BOOL sForgetScheduled;
static NSMutableDictionary<NSData *, VibeArchivedArtEntry *> *sEntries;
// The digests, oldest first.
static NSMutableArray<NSData *> *sOrder;

static void VibeForgetPictures(void) {
    os_unfair_lock_lock(&sLock);
    [sEntries removeAllObjects];
    [sOrder removeAllObjects];
    os_unfair_lock_unlock(&sLock);
}

// Forgets every picture once none has been used for the idle time. Runs
// with the lock held, and schedules one check at a time.
static void VibeScheduleForgetLocked(void) {
    if (sForgetScheduled) {
        return;
    }
    sForgetScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kVibeArchivedArtShareIdleNS),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&sLock);
        sForgetScheduled = NO;
        if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sLastUse >= (uint64_t)kVibeArchivedArtShareIdleNS) {
            [sEntries removeAllObjects];
            [sOrder removeAllObjects];
        } else {
            VibeScheduleForgetLocked();
        }
        os_unfair_lock_unlock(&sLock);
    });
}

void VibeArchivedArtOfPicture(NSData *picture,
                              VibeArchivedArtMaker make,
                              NSData *_Nullable *_Nonnull thumbnail,
                              NSData *_Nullable *_Nonnull rendition) {
    NSData *digest = picture.sha256Digest;
    BOOL maker = NO;
    os_unfair_lock_lock(&sLock);
    if (!sEntries) {
        sEntries = [NSMutableDictionary dictionary];
        sOrder = [NSMutableArray array];
#if !TARGET_OS_OSX
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
            (void)note;
            VibeForgetPictures();
        }];
#endif
    }
    sLastUse = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    VibeScheduleForgetLocked();
    VibeArchivedArtEntry *entry = sEntries[digest];
    if (!entry) {
        maker = YES;
        entry = [[VibeArchivedArtEntry alloc] init];
        dispatch_group_enter(entry.made);
        sEntries[digest] = entry;
        [sOrder addObject:digest];
        if (sOrder.count > kVibeArchivedArtShareCount) {
            [sEntries removeObjectForKey:sOrder.firstObject];
            [sOrder removeObjectAtIndex:0];
        }
    }
    os_unfair_lock_unlock(&sLock);
    if (maker) {
        NSData *madeThumbnail = nil;
        NSData *madeRendition = nil;
        // A throw still lets the waiters go, with no forms.
        @try {
            make(&madeThumbnail, &madeRendition);
            entry.thumbnail = madeThumbnail;
            entry.rendition = madeRendition;
        } @finally {
            dispatch_group_leave(entry.made);
        }
    } else {
        // TRAP: the wait is outside the lock, which only the table needs.
        dispatch_group_wait(entry.made, DISPATCH_TIME_FOREVER);
    }
    *thumbnail = entry.thumbnail;
    *rendition = entry.rendition;
}

void VibeArchivedArtShareResetForTesting(void) {
    VibeForgetPictures();
}
