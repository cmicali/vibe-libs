//
//  DebugChannel.m
//  vibe-libs
//

#import "DebugChannel.h"

#if DEBUG

#import <notify.h>
#import <os/lock.h>
#import <sys/sysctl.h>
#import "DebugWireFormat.h"
#import "VibeMacros.h"

static VibeDebugChannelExecutor gExecutor;
static NSString *gChannel;

// A live client reads its reply within 20 ms. A host may read a screenshot's
// path minutes after its client returns. The bound leaves it that time.
static const NSTimeInterval kVibeDebugAbandonedFileAge = 10 * 60;

// The longest a verb that never replies holds the latency-critical activity.
static const NSTimeInterval kVibeDebugInFlightCap = 120;

#if TARGET_OS_OSX
static os_unfair_lock gInFlightLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gInFlight;
static id<NSObject> gLatencyCritical;
#endif

NSString *VibeDebugChannelName(void) {
    return gChannel;
}

// A command holds the latency-critical activity from pickup until its reply is
// written. One activity serves every command in flight. The second TRAP at the
// install says why.
static void VibeDebugCommandPickedUp(NSString *commandId) {
#if TARGET_OS_OSX
    os_unfair_lock_lock(&gInFlightLock);
    gInFlight = gInFlight ?: [NSMutableSet set];
    [gInFlight addObject:commandId];
    if (!gLatencyCritical) {
        gLatencyCritical = [NSProcessInfo.processInfo
                beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
                                  reason:@"debug command in flight"];
    }
    os_unfair_lock_unlock(&gInFlightLock);
#endif
}

// A reply may be written on any thread.
static void VibeDebugCommandSettled(NSString *commandId) {
#if TARGET_OS_OSX
    os_unfair_lock_lock(&gInFlightLock);
    [gInFlight removeObject:commandId];
    if (gInFlight.count == 0 && gLatencyCritical) {
        [NSProcessInfo.processInfo endActivity:gLatencyCritical];
        gLatencyCritical = nil;
    }
    os_unfair_lock_unlock(&gInFlightLock);
#endif
}

// For the tests, which declare it. Always 0 on iOS.
NSUInteger VibeDebugCommandsInFlight(void);
NSUInteger VibeDebugCommandsInFlight(void) {
    NSUInteger count = 0;
#if TARGET_OS_OSX
    os_unfair_lock_lock(&gInFlightLock);
    count = gInFlight.count;
    os_unfair_lock_unlock(&gInFlightLock);
#endif
    return count;
}

static NSString *VibeDebugLogTag(NSString *commandId) {
    return commandId.length > 8 ? [commandId substringToIndex:8] : (commandId ?: @"?");
}

// Parse short error replies for warning logs. Trim other replies to bound log size.
static void VibeLogDebugReply(NSString *commandId, NSString *response) {
    NSString *tag = VibeDebugLogTag(commandId);
    if (response.length < 4096 && [response containsString:@"\"error\""]) {
        NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id error = [json isKindOfClass:NSDictionary.class] ? json[@"error"] : nil;
        if ([error isKindOfClass:NSString.class]) {
            LogWarn(@"Debug reply %@ ERROR: %@", tag, error);
            return;
        }
    }
    NSString *flat = [[response componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
    while ([flat containsString:@"  "]) {
        flat = [flat stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (flat.length > 300) {
        flat = [NSString stringWithFormat:@"%@… (%lu bytes)", [flat substringToIndex:300],
                (unsigned long)response.length];
    }
    LogInfo(@"Debug reply %@: %@", tag, flat);
}

void VibeWriteDebugResponse(NSString *commandId, NSString *response) {
    [response writeToFile:VibeDebugResponsePath(gChannel, commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    VibeLogDebugReply(commandId, response);
    VibeDebugCommandSettled(commandId);
}

static void VibeHandleOneDebugCommandFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    // A malformed payload still gets an error reply whenever the id is
    // recoverable; a silent drop leaves the client polling out its window.
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *commandId = [payload isKindOfClass:NSDictionary.class] ? payload[@"id"] : nil;
    if (![commandId isKindOfClass:NSString.class] || commandId.length == 0) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"<not UTF-8>";
        if (raw.length > 256) {
            raw = [[raw substringToIndex:256] stringByAppendingString:@"…"];
        }
        LogError(@"Debug command payload has no usable id, dropping: %@", raw);
        return;
    }
    NSArray *args = payload[@"args"];
    NSString *malformed = nil;
    if (![args isKindOfClass:NSArray.class] || args.count == 0) {
        malformed = @"payload 'args' must be a non-empty JSON array";
    }
    else {
        for (id token in args) {
            if (![token isKindOfClass:NSString.class]) {
                malformed = @"payload 'args' must contain only strings";
                break;
            }
        }
    }
    if (malformed) {
        VibeWriteDebugResponse(commandId, VibeJSONString(@{@"error": malformed}));
        return;
    }
    // Before the verb runs, so one that hangs or crashes has still logged it.
    LogInfo(@"Debug command %@: %@", VibeDebugLogTag(commandId), [args componentsJoinedByString:@" "]);
    VibeDebugCommandPickedUp(commandId);
    NSString *response = gExecutor(args, commandId);
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
    else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVibeDebugInFlightCap * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VibeDebugCommandSettled(commandId);
        });
    }
}

static NSDate *VibeDebugModificationDate(NSURL *url) {
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    return date ?: NSDate.distantPast;
}

// This channel's files of these kinds, oldest first, by name within one date.
// Another app's files never appear.
static NSArray<NSURL *> *VibeDebugChannelFiles(NSArray<NSString *> *kinds) {
    NSDictionary<NSString *, NSString *> *suffixes = @{@"command": @".json", @"response": @".txt", @"screenshot": @".png"};
    NSURL *tmpDir = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:tmpDir
                                                   includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                      options:0
                                                                        error:nil]) {
        NSString *name = url.lastPathComponent;
        for (NSString *kind in kinds) {
            if ([name hasPrefix:VibeDebugFilePrefix(gChannel, kind)] && [name hasSuffix:suffixes[kind]]) {
                [files addObject:url];
            }
        }
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSComparisonResult order = [VibeDebugModificationDate(a) compare:VibeDebugModificationDate(b)];
        return order != NSOrderedSame ? order : [a.lastPathComponent compare:b.lastPathComponent];
    }];
    return files;
}

static void VibeRemoveDebugChannelFiles(NSArray<NSString *> *kinds, NSDate *before) {
    for (NSURL *url in VibeDebugChannelFiles(kinds)) {
        if ([VibeDebugModificationDate(url) compare:before] == NSOrderedAscending) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
    }
}

// notify_post coalesces back-to-back posts, so one wake-up drains every
// pending command file. It runs the oldest first. A command's id is a UUID,
// and name order let a backlog's oldest client run out its wait. A client that
// gave up leaves its reply behind. The drain removes old replies. A pending
// command is live. The drain never removes one.
// TRAP: call it only from a main-queue block. A verb that spins the run loop
// inside one services no other main-queue block, so the next client's command
// waits for the verb to return and never runs inside it.
static void VibeHandleDebugCommandFiles(void) {
    VibeRemoveDebugChannelFiles(@[@"response", @"screenshot"],
                                [NSDate dateWithTimeIntervalSinceNow:-kVibeDebugAbandonedFileAge]);
    for (NSURL *url in VibeDebugChannelFiles(@[@"command"])) {
        VibeHandleOneDebugCommandFile(url.path);
    }
}

// When this process started. Now when the system cannot say, so every file
// counts as stale.
static NSDate *VibeDebugProcessStartDate(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) {
        return NSDate.date;
    }
    struct timeval start = info.kp_proc.p_starttime;
    return [NSDate dateWithTimeIntervalSince1970:start.tv_sec + start.tv_usec / 1e6];
}

#if TARGET_OS_IPHONE
// Fires on any tmp mutation, response writes included; a spurious drain costs
// one readdir. The host must rename complete command files into place: a file
// read mid-write is deleted unexecuted.
static dispatch_source_t gTmpWatcher;

static void VibeInstallTmpDirectoryWatcher(void) {
    int fd = open(NSTemporaryDirectory().fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        LogError(@"Debug channel: cannot watch tmp directory (errno %d)", errno);
        return;
    }
    gTmpWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                         DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gTmpWatcher, ^{
        VibeHandleDebugCommandFiles();
    });
    dispatch_source_set_cancel_handler(gTmpWatcher, ^{
        close(fd);
    });
    dispatch_resume(gTmpWatcher);
}
#endif

void VibeInstallDebugCommandChannel(NSString *channel, VibeDebugChannelExecutor executor) {
    if (channel.length == 0) {
        LogError(@"Debug channel: no name, so no channel");
        return;
    }
    gChannel = [channel copy];
    gExecutor = [executor copy];
    // TRAP: only files older than this process go. A dead client's command
    // would replay at the next launch and could change files. A live client's
    // command written between the process start and the install is this
    // run's, and the install drains it. Only this channel's files go.
    VibeRemoveDebugChannelFiles(@[@"command", @"response", @"screenshot"], VibeDebugProcessStartDate());
    static int token;
    notify_register_dispatch(VibeDebugCommandNotificationName(gChannel).UTF8String, &token,
                             dispatch_get_main_queue(), ^(int t) {
        VibeHandleDebugCommandFiles();
    });
#if TARGET_OS_IPHONE
    VibeInstallTmpDirectoryWatcher();
#endif
#if TARGET_OS_OSX
    // TRAP: macOS naps an app whose windows are all hidden and that plays
    // nothing. Every thread drops to background priority and its timers
    // stall. On a busy Mac the drain then misses the client's wait. A display
    // asleep hides every window.
    // TRAP: this activity stops the nap, but a hidden window's timers still
    // fire late once the app is idle. A 1 s timer-driven verb took 2 to 8 s.
    // So each command also holds a latency-critical activity until its reply
    // is written (VibeDebugCommandPickedUp). Held for the whole process, it
    // would skew an app's benchmarks against older versions.
    static id<NSObject> activity;
    if (!activity) {
        activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                reason:@"debug command channel"];
    }
#endif
    // A command written before the listener existed posted to no one.
    dispatch_async(dispatch_get_main_queue(), ^{
        VibeHandleDebugCommandFiles();
    });
}

#endif
