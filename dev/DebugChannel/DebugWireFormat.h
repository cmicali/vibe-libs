//
//  DebugWireFormat.h
//  vibe-libs
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

// The channel's wire format: the notification name, the per-command file
// paths and the JSON reply serialization. The app's tables and its client
// must agree on it, so the channel owns it.
//
// Every name on the wire derives from the channel's name, which the app
// chooses: its bundle identifier, or a name of its own. The notification is
// <channel>.debug.command. Each file is <channel>.debug-<kind>-<id>, in the
// temporary directory. So two apps' channels never meet.

#ifdef __cplusplus
extern "C" {
#endif

NSString *VibeDebugCommandNotificationName(NSString *channel);
// The start of a file's name. kind is command, response, or screenshot.
NSString *VibeDebugFilePrefix(NSString *channel, NSString *kind);

NSString *VibeDebugTmpPath(NSString *name);
NSString *VibeDebugCommandPath(NSString *channel, NSString *commandId);
NSString *VibeDebugResponsePath(NSString *channel, NSString *commandId);
NSString *VibeDebugScreenshotPathForCommand(NSString *channel, NSString *commandId);

NSString *VibeJSONString(NSDictionary *dict);
NSString *VibeErrorJSON(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

BOOL VibeParseDouble(NSString *token, double *out);
// A byte count, with a K or M suffix for KiB or MiB.
BOOL VibeParseByteCount(NSString *token, uint64_t *bytes);

#ifdef __cplusplus
}
#endif
