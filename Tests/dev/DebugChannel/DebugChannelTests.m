// The channel's three parts: the wire format's paths, replies and parsers,
// the lookup over a command table, and a command file drained to its reply
// through the notification a client posts.

#import <XCTest/XCTest.h>
#import <notify.h>

#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"

@interface DebugChannelTests : XCTestCase
@end

@implementation DebugChannelTests

// The channel holds one executor per process, so every test installs it once
// and swaps what it runs.
static VibeDebugChannelExecutor gRunning;
static NSString *const kChannel = @"vibe-libs.debugchannel.tests";

static void InstallChannelOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VibeInstallDebugCommandChannel(kChannel, ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
            return gRunning(args, commandId);
        });
    });
}

static id JSONObject(NSString *json) {
    return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

// Writes the payload as a client does, renamed into place, then posts the
// wake-up and spins main until the reply lands. Returns the reply, or nil.
static NSString *Send(NSData *payload, NSString *commandId) {
    NSString *path = VibeDebugCommandPath(kChannel, commandId);
    NSString *part = [path stringByAppendingString:@".part"];
    [payload writeToFile:part atomically:NO];
    [NSFileManager.defaultManager moveItemAtPath:part toPath:path error:nil];
    notify_post(VibeDebugCommandNotificationName(kChannel).UTF8String);
    NSString *responsePath = VibeDebugResponsePath(kChannel, commandId);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (![NSFileManager.defaultManager fileExistsAtPath:responsePath] && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSString *reply = [NSString stringWithContentsOfFile:responsePath encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:responsePath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    return reply;
}

static NSString *SendArgs(NSArray *args) {
    NSString *commandId = NSUUID.UUID.UUIDString;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"id": commandId, @"args": args} options:0 error:nil];
    return Send(payload, commandId);
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
    XCTAssertEqualObjects(VibeDebugChannelName(), kChannel);
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

@end
