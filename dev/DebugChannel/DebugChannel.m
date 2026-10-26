//
//  DebugChannel.m
//  vibe-libs
//

#import "DebugChannel.h"

#if DEBUG

#import <notify.h>
#import <sys/sysctl.h>
#import "DebugWireFormat.h"
#import "VibeMacros.h"

static VibeDebugChannelExecutor gExecutor;
static NSString *gChannel;

NSString *VibeDebugChannelName(void) {
    return gChannel;
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
    NSString *response = gExecutor(args, commandId);
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
}

// notify_post coalesces back-to-back posts, so one wake-up drains every
// pending command file.
// TRAP: call it only from a main-queue block. A verb that spins the run loop
// inside one services no other main-queue block, so the next client's command
// waits for the verb to return and never runs inside it.
static void VibeHandleDebugCommandFiles(void) {
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *commandPrefix = VibeDebugFilePrefix(gChannel, @"command");
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasPrefix:commandPrefix] && [name hasSuffix:@".json"]) {
            VibeHandleOneDebugCommandFile([tmpDir stringByAppendingPathComponent:name]);
        }
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

// TRAP: only files older than this process go. A dead client's command would
// replay at the next launch and could change files. A live client's command
// written between the process start and the install is this run's, and the
// install drains it. Only this channel's files go. Another app's stay.
static void VibeSweepStaleChannelFiles(void) {
    NSString *tmpDir = NSTemporaryDirectory();
    NSDate *started = VibeDebugProcessStartDate();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *name in names) {
        if (([name hasPrefix:VibeDebugFilePrefix(gChannel, @"response")] && [name hasSuffix:@".txt"])
                || ([name hasPrefix:VibeDebugFilePrefix(gChannel, @"screenshot")] && [name hasSuffix:@".png"])
                || ([name hasPrefix:VibeDebugFilePrefix(gChannel, @"command")] && [name hasSuffix:@".json"])) {
            NSString *path = [tmpDir stringByAppendingPathComponent:name];
            NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (!modified || [modified compare:started] == NSOrderedAscending) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            }
        }
    }
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
    VibeSweepStaleChannelFiles();
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
