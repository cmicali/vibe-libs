//
//  DebugChannel.h
//  vibe-libs
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The platform-neutral half of the debug command channel: the command-file
// drain, payload validation, response writing, the stale-file sweep and the
// wake-up listeners. The app supplies the executor, and its tables own every
// verb.

#ifdef __cplusplus
extern "C" {
#endif

// Runs one parsed command. args[0] is the verb; the rest are its arguments,
// one token per client argv entry, never re-tokenized. Returns the JSON reply
// to write, or nil when the command completes asynchronously and writes its
// own reply later through VibeWriteDebugResponse.
typedef NSString * _Nullable (^VibeDebugChannelExecutor)(NSArray<NSString *> *args,
                                                         NSString *commandId);

// Names the channel, sweeps its files orphaned by earlier runs, then listens
// on its notification on the main queue. The name is the app's bundle
// identifier or a name of its own. Every name on the wire derives from it
// (DebugWireFormat.h). On iOS it also watches the container's tmp directory:
// the host writes command files straight into it, but a host-side notifyutil
// posts into the mac's namespace, not the simulator's.
void VibeInstallDebugCommandChannel(NSString *channel, VibeDebugChannelExecutor executor);

// The name the channel was installed under, or nil before. A verb that names
// a file on the wire passes it.
NSString * _Nullable VibeDebugChannelName(void);

// Writes the per-command response file the client polls for; asynchronous
// commands call it from their own completion.
void VibeWriteDebugResponse(NSString *commandId, NSString *response);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
