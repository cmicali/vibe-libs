// The channel's three parts: the wire format's paths, replies and parsers,
// the lookup over a command table, and a command file drained to its reply
// through the notification a client posts. Then the client, on a background
// queue against the channel the tests install, while main drains it.

#import <XCTest/XCTest.h>
#import <fcntl.h>
#import <notify.h>
#import <unistd.h>

#import "DebugChannel.h"
#import "DebugClient.h"
#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"

// The commands holding the latency-critical activity. Only the tests read it,
// so no header declares it.
NSUInteger VibeDebugCommandsInFlight(void);

@interface DebugChannelTests : XCTestCase
@end

@implementation DebugChannelTests

// The channel holds one executor per process, so every test installs it once
// and swaps what it runs.
static VibeDebugChannelExecutor gRunning;
// Named for this process. Two runs at once, from two worktrees, share one
// temporary directory, and would drain each other's commands.
static NSString *TestChannel(void) {
    static NSString *channel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        channel = [NSString stringWithFormat:@"vibe-libs.debugchannel.tests.%d", getpid()];
    });
    return channel;
}

// The install is a launch. What it did with the two commands it found.
static NSString *gEarlyReply;
static BOOL gStaleSwept;
static BOOL gStaleRan;

static id JSONObject(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

// Writes the payload as a client does, renamed into place.
static NSString *WritePayload(NSData *payload, NSString *commandId) {
    NSString *path = VibeDebugCommandPath(TestChannel(), commandId);
    NSString *part = [path stringByAppendingString:@".part"];
    [payload writeToFile:part atomically:NO];
    [NSFileManager.defaultManager moveItemAtPath:part toPath:path error:nil];
    return path;
}

static NSString *WriteCommand(NSArray *args, NSString *commandId) {
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"id": commandId, @"args": args} options:0 error:nil];
    return WritePayload(payload, commandId);
}

static void Post(void) {
    notify_post(VibeDebugCommandNotificationName(TestChannel()).UTF8String);
}

// Spins main until the reply lands. Returns the reply, or nil.
static NSString *AwaitReply(NSString *commandId) {
    NSString *responsePath = VibeDebugResponsePath(TestChannel(), commandId);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (![NSFileManager.defaultManager fileExistsAtPath:responsePath] && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSString *reply = [NSString stringWithContentsOfFile:responsePath encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:responsePath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:VibeDebugCommandPath(TestChannel(), commandId) error:nil];
    return reply;
}

static NSString *Send(NSData *payload, NSString *commandId) {
    WritePayload(payload, commandId);
    Post();
    return AwaitReply(commandId);
}

static NSString *SendArgs(NSArray *args) {
    NSString *commandId = NSUUID.UUID.UUIDString;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"id": commandId, @"args": args} options:0 error:nil];
    return Send(payload, commandId);
}

// Before the install, a live client writes a command, as one waiting for a
// launch does. A dead client's command from an earlier run is older than this
// process.
static void InstallChannelOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *earlyId = NSUUID.UUID.UUIDString;
        WriteCommand(@[@"early"], earlyId);
        NSString *stale = WriteCommand(@[@"stale"], NSUUID.UUID.UUIDString);
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400]}
                                       ofItemAtPath:stale
                                              error:nil];
        gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
            gStaleRan |= [args.firstObject isEqualToString:@"stale"];
            return VibeJSONString(@{@"verb": args.firstObject});
        };
        VibeInstallDebugCommandChannel(TestChannel(), ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
            return gRunning(args, commandId);
        });
        gStaleSwept = ![NSFileManager.defaultManager fileExistsAtPath:stale];
        gEarlyReply = AwaitReply(earlyId);
        [NSFileManager.defaultManager removeItemAtPath:stale error:nil];
    });
}

- (void)setUp {
    InstallChannelOnce();
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeErrorJSON(@"no executor for '%@'", args.firstObject);
    };
}

#pragma mark - The wire format

- (void)testEachCommandHasItsOwnFiles {
    NSString *tmp = NSTemporaryDirectory();
    XCTAssertEqualObjects(VibeDebugCommandPath(@"app", @"abc"),
                          [tmp stringByAppendingPathComponent:@"app.debug-command-abc.json"]);
    XCTAssertEqualObjects(VibeDebugResponsePath(@"app", @"abc"),
                          [tmp stringByAppendingPathComponent:@"app.debug-response-abc.txt"]);
    XCTAssertEqualObjects(VibeDebugScreenshotPathForCommand(@"app", @"abc"),
                          [tmp stringByAppendingPathComponent:@"app.debug-screenshot-abc.png"]);
    XCTAssertNotEqualObjects(VibeDebugCommandPath(@"app", @"abc"), VibeDebugCommandPath(@"app", @"abd"));
}

- (void)testEveryNameOnTheWireIsTheChannels {
    XCTAssertEqualObjects(VibeDebugCommandNotificationName(@"com.example.App"), @"com.example.App.debug.command");
    XCTAssertNotEqualObjects(VibeDebugCommandPath(@"com.example.App", @"abc"),
                             VibeDebugCommandPath(@"com.example.Other", @"abc"));
    XCTAssertFalse([VibeDebugFilePrefix(@"com.example.App.beta", @"command")
                    hasPrefix:VibeDebugFilePrefix(@"com.example.App", @"command")],
                   @"a name that extends another's still has files of its own");
    XCTAssertEqualObjects(VibeDebugChannelName(), TestChannel());
}

- (void)testEveryReplyIsOneJSONObject {
    NSString *json = VibeJSONString(@{@"b": @1, @"a": @"two"});
    XCTAssertEqualObjects(JSONObject(json), (@{@"a": @"two", @"b": @1}));
    XCTAssertLessThan([json rangeOfString:@"\"a\""].location, [json rangeOfString:@"\"b\""].location,
                      @"keys are sorted, so a reply diffs cleanly");
    XCTAssertEqualObjects(JSONObject(VibeErrorJSON(@"bad %@ %d", @"verb", 3)), @{@"error": @"bad verb 3"});
}

- (void)testNumbersParseWholeTokensOnly {
    double value = 0;
    XCTAssertTrue(VibeParseDouble(@"-1.5", &value));
    XCTAssertEqual(value, -1.5);
    XCTAssertFalse(VibeParseDouble(@"1.5s", &value));
    XCTAssertFalse(VibeParseDouble(@"", &value));

    uint64_t bytes = 0;
    XCTAssertTrue(VibeParseByteCount(@"512", &bytes));
    XCTAssertEqual(bytes, 512u);
    XCTAssertTrue(VibeParseByteCount(@"2K", &bytes));
    XCTAssertEqual(bytes, 2048u);
    XCTAssertTrue(VibeParseByteCount(@"1.5M", &bytes));
    XCTAssertEqual(bytes, 1572864u);
    XCTAssertFalse(VibeParseByteCount(@"-1K", &bytes));
    XCTAssertFalse(VibeParseByteCount(@"K", &bytes));
}

#pragma mark - The lookup

- (void)testTheTableAnswersByVerbAndListsEveryUsageOtherwise {
    NSArray<NSDictionary *> *table = @[
        VibeDebugCmd(@"greet <name>", 7, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id c) {
            return VibeJSONString(@{@"hello": VibeRestArgument(tokens)});
        }),
        VibeDebugCmd(@"ping", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id c) {
            return VibeJSONString(@{@"ok": @YES});
        }),
    ];
    XCTAssertEqualObjects(VibeDebugVerbFromUsage(@"greet <name>"), @"greet");
    XCTAssertEqualObjects(VibeDebugVerbFromUsage(@"ping"), @"ping");
    NSDictionary *spec = VibeDebugSpecForVerb(table, @"greet");
    XCTAssertEqualObjects(spec[@"usage"], @"greet <name>");
    XCTAssertEqual([spec[@"clientTimeout"] doubleValue], 7);
    NSString *reply = ((VibeDebugCommandHandler)spec[@"handler"])(@[@"greet", @"a", @"b"], @"id", NSNull.null);
    XCTAssertEqualObjects(JSONObject(reply), @{@"hello": @"a b"});
    XCTAssertNil(VibeDebugSpecForVerb(table, @"gree"), @"a verb matches whole");

    NSString *unknown = VibeDebugUnknownCommandReply(@"nope", @[table, @[]], @[@"sleep <seconds>"]);
    XCTAssertEqualObjects(JSONObject(unknown),
                          @{@"error": @"unknown command 'nope'. Commands: greet <name>, ping, sleep <seconds>"});
    XCTAssertEqualObjects(JSONObject(VibeDebugUnknownCommandReply(@"nope", @[table], nil)),
                          @{@"error": @"unknown command 'nope'. Commands: greet <name>, ping"});
}

- (void)testADuplicateIsAVerbTwoTablesHold {
    VibeDebugCommandHandler none = ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id c) {
        return nil;
    };
    NSArray<NSDictionary *> *first = @[VibeDebugCmd(@"quit", 0, none), VibeDebugCmd(@"ping <x>", 0, none),
                                       VibeDebugCmd(@"dump_build", 0, none)];
    NSArray<NSDictionary *> *second = @[VibeDebugCmd(@"dump_build", 0, none), VibeDebugCmd(@"pong", 0, none),
                                        VibeDebugCmd(@"ping", 0, none)];
    NSArray<NSDictionary *> *third = @[VibeDebugCmd(@"dump_build [-]", 0, none)];
    XCTAssertEqualObjects(VibeDebugDuplicateVerbs(@[first, second, third]), (@[@"ping", @"dump_build"]),
                          @"by verb, not by usage, each once, in the order it first appears");
    XCTAssertEqualObjects(VibeDebugDuplicateVerbs(@[first, @[VibeDebugCmd(@"pong", 0, none)]]), @[]);
    XCTAssertEqualObjects(VibeDebugDuplicateVerbs(@[]), @[]);
}

- (void)testArgumentsKeepTheirTokens {
    XCTAssertEqualObjects(VibeRestArgument(@[@"open"]), @"");
    XCTAssertEqualObjects(VibeRestArgument(@[@"open", @"a b", @"c"]), @"a b c");
    XCTAssertEqualObjects(VibePathArgument(@[@"open", @"~/x"]), [NSHomeDirectory() stringByAppendingPathComponent:@"x"]);

    BOOL on = NO;
    XCTAssertTrue(VibeParseOnOff(@[@"set", @"ON"], &on));
    XCTAssertTrue(on);
    XCTAssertTrue(VibeParseOnOff(@[@"set", @"off"], &on));
    XCTAssertFalse(on);
    XCTAssertFalse(VibeParseOnOff(@[@"set", @"maybe"], &on));
    XCTAssertFalse(VibeParseOnOff(@[@"set"], &on));
}

- (void)testAFileArgumentMustBeAnExistingFile {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *file = [directory stringByAppendingPathComponent:@"track one.wav"];
    [NSData.data writeToFile:file atomically:NO];

    NSString *error = nil;
    XCTAssertEqualObjects(VibeExistingFileArgument(@[@"open", file], &error), file);
    XCTAssertNil(error);
    XCTAssertNil(VibeExistingFileArgument(@[@"open"], &error));
    XCTAssertEqualObjects(JSONObject(error), @{@"error": @"usage: open <file>"});
    XCTAssertNil(VibeExistingFileArgument(@[@"open", directory], &error));
    XCTAssertTrue([JSONObject(error)[@"error"] hasPrefix:@"open expects an existing file"]);
    XCTAssertNil(VibeExistingFileArgument(@[@"open", [file stringByAppendingString:@"x"]], &error));

    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

#pragma mark - The drain

- (void)testALaunchAnswersALiveClientsEarlyCommandAndSweepsADeadOnes {
    XCTAssertEqualObjects(JSONObject(gEarlyReply), @{@"verb": @"early"},
                          @"a command written since the process started is drained at install");
    XCTAssertTrue(gStaleSwept, @"a command older than the process is swept at install");
    XCTAssertFalse(gStaleRan, @"and never runs");
}

- (void)testACommandFileReachesTheExecutorAndItsReplyIsWritten {
    __block NSArray<NSString *> *ran = nil;
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        ran = args;
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    NSString *reply = SendArgs(@[@"open", @"/a path/with spaces.wav"]);
    XCTAssertEqualObjects(JSONObject(reply), @{@"verb": @"open"});
    XCTAssertEqualObjects(ran, (@[@"open", @"/a path/with spaces.wav"]), @"args arrive as sent, never re-tokenized");
}

- (void)testAnAsynchronousCommandWritesItsOwnReply {
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VibeWriteDebugResponse(commandId, VibeJSONString(@{@"later": @YES}));
        });
        return nil;
    };
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"slow"])), @{@"later": @YES});
}

// A verb runs in a main-queue block, and a run loop it spins services no
// other. So a command posted meanwhile runs once the verb returns.
- (void)testACommandPostedWhileAVerbSpinsMainRunsAfterTheVerb {
    NSString *secondId = NSUUID.UUID.UUIDString;
    __block BOOL spinning = NO;
    __block BOOL ranInsideTheSpin = NO;
    NSMutableArray<NSString *> *ran = [NSMutableArray array];
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        [ran addObject:args.firstObject];
        ranInsideTheSpin |= spinning;
        if ([args.firstObject isEqualToString:@"spin"]) {
            spinning = YES;
            WriteCommand(@[@"second"], secondId);
            Post();
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.3];
            while (until.timeIntervalSinceNow > 0) {
                [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
            }
            spinning = NO;
        }
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"spin"])), @{@"verb": @"spin"});
    XCTAssertEqualObjects(JSONObject(AwaitReply(secondId)), @{@"verb": @"second"});
    XCTAssertFalse(ranInsideTheSpin);
    XCTAssertEqualObjects(ran, (@[@"spin", @"second"]));
}

- (void)testTwoCommandsPostedBackToBackAreBothAnswered {
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    NSString *first = NSUUID.UUID.UUIDString;
    NSString *second = NSUUID.UUID.UUIDString;
    WriteCommand(@[@"first"], first);
    Post();
    WriteCommand(@[@"second"], second);
    Post();
    XCTAssertEqualObjects(JSONObject(AwaitReply(first)), @{@"verb": @"first"});
    XCTAssertEqualObjects(JSONObject(AwaitReply(second)), @{@"verb": @"second"});
}

// In a backlog the client that has waited longest runs first. A client's id is
// a UUID, so name order is no order at all.
- (void)testABacklogRunsOldestFirstAndTheNameBreaksATie {
    NSMutableArray<NSString *> *ran = [NSMutableArray array];
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        [ran addObject:args.firstObject];
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    NSDate *now = NSDate.date;
    NSDictionary<NSString *, NSDate *> *written = @{
        @"backlog-a": [now dateByAddingTimeInterval:-2],
        @"backlog-b": [now dateByAddingTimeInterval:-2],
        @"backlog-c": [now dateByAddingTimeInterval:-3],
    };
    for (NSString *commandId in written) {
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: written[commandId]}
                                                     ofItemAtPath:WriteCommand(@[commandId], commandId)
                                                            error:nil]);
    }
    Post();
    for (NSString *commandId in written) {
        AwaitReply(commandId);
    }
    XCTAssertEqualObjects(ran, (@[@"backlog-c", @"backlog-a", @"backlog-b"]));
}

// A client that gave up leaves its reply behind. A drain removes it once it is
// old, and leaves a fresh one for its client.
- (void)testADrainRemovesAbandonedRepliesAndKeepsFreshOnes {
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    NSString *staleReply = VibeDebugResponsePath(TestChannel(), @"abandoned");
    NSString *staleScreenshot = VibeDebugScreenshotPathForCommand(TestChannel(), @"abandoned");
    NSString *freshReply = VibeDebugResponsePath(TestChannel(), @"fresh");
    for (NSString *path in @[staleReply, staleScreenshot, freshReply]) {
        XCTAssertTrue([NSData.data writeToFile:path atomically:NO]);
    }
    for (NSString *path in @[staleReply, staleScreenshot]) {
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-11 * 60]}
                                                     ofItemAtPath:path
                                                            error:nil]);
    }
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"ours"])), @{@"verb": @"ours"});
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:staleReply]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:staleScreenshot]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:freshReply]);
    [NSFileManager.defaultManager removeItemAtPath:freshReply error:nil];
}

// A command holds the latency-critical activity until its reply is written. A
// synchronous one holds it while its executor runs. An asynchronous one holds
// it until its completion writes.
- (void)testACommandIsInFlightUntilItsReplyIsWritten {
    XCTAssertEqual(VibeDebugCommandsInFlight(), 0u);
    __block NSUInteger whileRunning = 0;
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        whileRunning = VibeDebugCommandsInFlight();
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"now"])), @{@"verb": @"now"});
    XCTAssertEqual(whileRunning, 1u);
    XCTAssertEqual(VibeDebugCommandsInFlight(), 0u);

    __block NSUInteger beforeReplying = 0;
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        dispatch_async(dispatch_get_main_queue(), ^{
            beforeReplying = VibeDebugCommandsInFlight();
            VibeWriteDebugResponse(commandId, VibeJSONString(@{@"later": @YES}));
        });
        return nil;
    };
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"later"])), @{@"later": @YES});
    XCTAssertEqual(beforeReplying, 1u);
    XCTAssertEqual(VibeDebugCommandsInFlight(), 0u);
}

// Two unsandboxed apps share one temporary directory. Each drains only its own.
- (void)testAnotherChannelsCommandIsNeitherRunNorAnswered {
    __block NSMutableArray<NSString *> *ran = [NSMutableArray array];
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        [ran addObject:args.firstObject];
        return VibeJSONString(@{@"verb": args.firstObject});
    };
    NSString *other = @"vibe-libs.debugchannel.tests.other";
    NSString *commandId = NSUUID.UUID.UUIDString;
    NSString *path = VibeDebugCommandPath(other, commandId);
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"id": commandId, @"args": @[@"theirs"]}
                                                      options:0 error:nil];
    XCTAssertTrue([payload writeToFile:path atomically:YES]);
    notify_post(VibeDebugCommandNotificationName(other).UTF8String);
    // Our own reply means a drain has passed over the other channel's file.
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"ours"])), @{@"verb": @"ours"});
    XCTAssertEqualObjects(ran, @[@"ours"]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:VibeDebugResponsePath(other, commandId)]);
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

- (void)testAMalformedPayloadStillGetsAnErrorReply {
    XCTAssertEqualObjects(JSONObject(SendArgs(@[])),
                          @{@"error": @"payload 'args' must be a non-empty JSON array"});
    XCTAssertEqualObjects(JSONObject(SendArgs(@[@"seek", @3])),
                          @{@"error": @"payload 'args' must contain only strings"});
}

#pragma mark - The client

static VibeDebugClientOptions *ClientOptions(void) {
    VibeDebugClientOptions *options = [VibeDebugClientOptions new];
    options.channel = TestChannel();
    options.displayName = @"Tests";
    options.messagePrefix = @"tests";
    return options;
}

// Runs the client as `tests --debug-cmd <args>` on a background queue, while
// main drains the channel, as an app and its client do in two processes.
// Answers the exit code, and what the client wrote to stdout.
static int RunClient(NSArray<NSString *> *args, VibeDebugClientOptions *options, NSData **output) {
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSData.data writeToFile:outPath atomically:NO];
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    int fd = open(outPath.fileSystemRepresentation, O_WRONLY | O_TRUNC);
    dup2(fd, STDOUT_FILENO);
    close(fd);
    __block int status = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            const char **argv = calloc(args.count + 2, sizeof(char *));
            argv[0] = "tests";
            argv[1] = "--debug-cmd";
            for (NSUInteger i = 0; i < args.count; i++) {
                argv[i + 2] = args[i].UTF8String;
            }
            status = VibeDebugClientMain((int)args.count + 2, argv, options);
            free(argv);
        }
        dispatch_semaphore_signal(done);
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    fflush(stdout);
    dup2(saved, STDOUT_FILENO);
    close(saved);
    if (output) {
        *output = [NSData dataWithContentsOfFile:outPath];
    }
    [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
    return status;
}

static NSArray<NSString *> *OutputLines(NSData *output) {
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    return [[text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsSeparatedByString:@"\n"];
}

- (void)testTheClientsExitCodeIsTheReplys {
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return [args.firstObject isEqualToString:@"ping"] ? VibeJSONString(@{@"pong": args.lastObject})
                                                         : VibeErrorJSON(@"no %@", args.firstObject);
    };
    NSData *output = nil;
    XCTAssertEqual(RunClient(@[@"ping", @"a b"], ClientOptions(), &output), 0);
    XCTAssertEqualObjects(JSONObject([[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding]),
                          @{@"pong": @"a b"}, @"an argument with a space arrives as one token");
    XCTAssertEqual(RunClient(@[@"nope"], ClientOptions(), &output), 2, @"an error reply");
    XCTAssertEqualObjects(JSONObject([[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding]),
                          @{@"error": @"no nope"});
}

- (void)testNoReplyWithinTheVerbsWaitIsExitOne {
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return nil;
    };
    VibeDebugClientOptions *options = ClientOptions();
    __block NSString *asked = nil;
    options.waitForVerb = ^NSTimeInterval(NSString *verb) {
        asked = verb;
        return 0.5;
    };
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    XCTAssertEqual(RunClient(@[@"silent"], options, NULL), 1);
    CFAbsoluteTime waited = CFAbsoluteTimeGetCurrent() - start;
    XCTAssertEqualObjects(asked, @"silent");
    XCTAssertGreaterThanOrEqual(waited, 0.5);
    XCTAssertLessThan(waited, 4.5, @"the verb's wait, not the 5 s default");
}

- (void)testAUsageErrorIsExitSixtyFour {
    XCTAssertEqual(RunClient(@[], ClientOptions(), NULL), 64);
    XCTAssertEqual(RunClient(@[@"sleep", @"forever"], ClientOptions(), NULL), 64);
    XCTAssertEqual(RunClient(@[@"script"], ClientOptions(), NULL), 64);
    NSData *output = nil;
    XCTAssertEqual(RunClient(@[@"sleep", @"0.01"], ClientOptions(), &output), 0, @"sleep runs in the client");
    XCTAssertEqualObjects(JSONObject([[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding])[@"ok"],
                          @YES);
}

- (void)testAScriptStopsAtItsFirstFailure {
    __block NSMutableArray<NSString *> *ran = [NSMutableArray array];
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        [ran addObject:[args componentsJoinedByString:@"|"]];
        return [args.firstObject isEqualToString:@"fail"] ? VibeErrorJSON(@"failed")
                                                          : VibeJSONString(@{@"ran": args.lastObject});
    };
    NSString *script = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [@"ping 'a b'\n# a comment\n\nfail\nping after\n" writeToFile:script atomically:YES
                                                         encoding:NSUTF8StringEncoding error:nil];
    NSData *output = nil;
    XCTAssertEqual(RunClient(@[@"script", script], ClientOptions(), &output), 2);
    [NSFileManager.defaultManager removeItemAtPath:script error:nil];
    XCTAssertEqualObjects(ran, (@[@"ping|a b", @"fail"]), @"quotes group a token, and nothing runs after a failure");
    XCTAssertEqualObjects(OutputLines(output), (@[@"{\"ran\":\"a b\"}", @"{\"error\":\"failed\"}"]),
                          @"one compact reply per command");
}

- (void)testAFileVerbsFileReachesStdoutUnderADash {
    NSData *bytes = [@"not really a PNG" dataUsingEncoding:NSUTF8StringEncoding];
    __block NSString *written = nil;
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        written = VibeDebugScreenshotPathForCommand(TestChannel(), commandId);
        [bytes writeToFile:written atomically:YES];
        return VibeJSONString(@{@"path": written});
    };
    VibeDebugClientOptions *options = ClientOptions();
    options.fileVerbs = @[@"shot"];
    NSData *output = nil;
    XCTAssertEqual(RunClient(@[@"shot", @"-"], options, &output), 0);
    XCTAssertEqualObjects(output, bytes);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:written], @"the client removes the file it read");

    NSString *script = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [@"shot first\n" writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTAssertEqual(RunClient(@[@"script", script], options, &output), 0);
    [NSFileManager.defaultManager removeItemAtPath:script error:nil];
    XCTAssertEqualObjects(JSONObject(OutputLines(output).firstObject),
                          (@{@"ok": @YES, @"label": @"first", @"pngBase64": [bytes base64EncodedStringWithOptions:0]}));
}

- (void)testALocalVerbRunsInTheClientAndNeverReachesTheApp {
    __block BOOL reached = NO;
    gRunning = ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        reached = YES;
        return VibeJSONString(@{@"app": @YES});
    };
    VibeDebugClientOptions *options = ClientOptions();
    options.localVerb = ^int(NSArray<NSString *> *args, BOOL inScript, void (^print)(NSString *json)) {
        if (![args.firstObject isEqualToString:@"local"]) {
            return -1;
        }
        print(VibeJSONString(@{@"local": @(inScript)}));
        return 0;
    };
    NSData *output = nil;
    XCTAssertEqual(RunClient(@[@"local"], options, &output), 0);
    XCTAssertEqualObjects(JSONObject([[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding]),
                          @{@"local": @NO});
    XCTAssertFalse(reached);
    XCTAssertEqual(RunClient(@[@"remote"], options, &output), 0, @"any other verb rides the channel");
    XCTAssertTrue(reached);
}

@end
