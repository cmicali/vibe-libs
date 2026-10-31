//
//  DebugChannel.m
//
//  Installs the debug channel over a table of one command and the standard
//  verbs, writes each command file as a client does, posts the wake-up, and
//  reads the reply back.
//

#import <Foundation/Foundation.h>
#import <notify.h>

#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugStandardVerbs.h"
#import "DebugWireFormat.h"

FOUNDATION_EXTERN BOOL ConsumerDebugChannelAnswers(void);

// A tool has no bundle identifier, so it names its channel itself.
static NSString *const kChannel = @"vibe-libs.consumer";

static NSDictionary *ConsumerAsk(NSArray<NSString *> *args) {
    NSString *commandId = NSUUID.UUID.UUIDString;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"id": commandId, @"args": args} options:0 error:nil];
    [payload writeToFile:VibeDebugCommandPath(kChannel, commandId) atomically:YES];
    notify_post(VibeDebugCommandNotificationName(kChannel).UTF8String);

    NSString *responsePath = VibeDebugResponsePath(kChannel, commandId);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (![NSFileManager.defaultManager fileExistsAtPath:responsePath] && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSData *data = [NSData dataWithContentsOfFile:responsePath];
    [NSFileManager.defaultManager removeItemAtPath:responsePath error:nil];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

BOOL ConsumerDebugChannelAnswers(void) {
    NSArray<NSDictionary *> *own = @[
        VibeDebugCmd(@"echo <text>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeJSONString(@{@"echo": VibeRestArgument(tokens)});
        }),
    ];
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
    options.healthExtras = ^NSDictionary *(id controller) {
        return @{@"consumer": @{@"tables": @2}};
    };
    NSArray<NSArray<NSDictionary *> *> *tables = @[own, VibeDebugStandardVerbs(options)];
    VibeInstallDebugCommandChannel(kChannel, ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        for (NSArray<NSDictionary *> *table in tables) {
            NSDictionary *spec = VibeDebugSpecForVerb(table, args.firstObject);
            if (spec) {
                return ((VibeDebugCommandHandler)spec[@"handler"])(args, commandId, NSNull.null);
            }
        }
        return VibeDebugUnknownCommandReply(args.firstObject, tables, nil);
    });

    NSDictionary *echo = ConsumerAsk(@[@"echo", @"a b"]);
    if (![echo isEqual:@{@"echo": @"a b"}]) {
        fprintf(stderr, "consumer: the debug channel replied %s\n", echo.description.UTF8String ?: "nothing");
        return NO;
    }
    NSDictionary *build = ConsumerAsk(@[@"dump_build"]);
    if (![build[@"pid"] isEqual:@(NSProcessInfo.processInfo.processIdentifier)]
            || ![build[@"channel"] isEqual:VibeDebugCommandNotificationName(kChannel)]) {
        fprintf(stderr, "consumer: dump_build replied %s\n", build.description.UTF8String ?: "nothing");
        return NO;
    }
    NSDictionary *health = ConsumerAsk(@[@"dump_health"]);
    if (![health[@"ok"] isEqual:@YES] || [health[@"process"][@"threads"] unsignedIntegerValue] == 0
            || ![health[@"consumer"] isEqual:@{@"tables": @2}]) {
        fprintf(stderr, "consumer: dump_health replied %s\n", health.description.UTF8String ?: "nothing");
        return NO;
    }
    return YES;
}
