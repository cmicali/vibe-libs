//
//  DebugChannel.m
//
//  Installs the debug channel over a table of one command, writes a command
//  file as a client does, posts the wake-up, and reads the reply back.
//

#import <Foundation/Foundation.h>
#import <notify.h>

#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"

FOUNDATION_EXTERN BOOL ConsumerDebugChannelAnswers(void);

BOOL ConsumerDebugChannelAnswers(void) {
    NSArray<NSDictionary *> *table = @[
        VibeDebugCmd(@"echo <text>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeJSONString(@{@"echo": VibeRestArgument(tokens)});
        }),
    ];
    // A tool has no bundle identifier, so it names its channel itself.
    NSString *channel = @"vibe-libs.consumer";
    VibeInstallDebugCommandChannel(channel, ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        NSDictionary *spec = VibeDebugSpecForVerb(table, args.firstObject);
        if (!spec) {
            return VibeDebugUnknownCommandReply(args.firstObject, @[table], nil);
        }
        return ((VibeDebugCommandHandler)spec[@"handler"])(args, commandId, NSNull.null);
    });

    NSString *commandId = NSUUID.UUID.UUIDString;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"id": commandId, @"args": @[@"echo", @"a b"]}
                                                      options:0 error:nil];
    [payload writeToFile:VibeDebugCommandPath(channel, commandId) atomically:YES];
    notify_post(VibeDebugCommandNotificationName(channel).UTF8String);

    NSString *responsePath = VibeDebugResponsePath(channel, commandId);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (![NSFileManager.defaultManager fileExistsAtPath:responsePath] && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSData *data = [NSData dataWithContentsOfFile:responsePath];
    [NSFileManager.defaultManager removeItemAtPath:responsePath error:nil];
    NSDictionary *reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![reply isEqual:@{@"echo": @"a b"}]) {
        fprintf(stderr, "consumer: the debug channel replied %s\n", reply.description.UTF8String ?: "nothing");
        return NO;
    }
    return YES;
}
