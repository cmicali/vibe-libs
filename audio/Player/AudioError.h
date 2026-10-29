//
//  AudioError.h
//  vibe-libs
//
//  The play path's error vocabulary — domain, userInfo keys, codes, kinds —
//  apart from the player so that a receiver deciding what to SAY about a
//  failure need not import the engine.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The domain every play-path error carries. The app pushes its own once, at
// launch, before the first play. Read before then, it asserts in a debug
// build and answers @"VibeAudioErrorDomain".
void VibeAudioErrorSetDomain(NSString *domain);
NSString *VibeAudioErrorDomain(void);
// userInfo key carrying the failing track's URL on play-path errors. Two
// rows of one file share it, so a receiver tells them apart by
// kVibeAudioErrorTrackKey and kVibeAudioErrorRequestIdentifierKey.
extern NSString *const kVibeAudioErrorTrackURLKey;
// The item the error is about, the very object the app handed the player.
// On a track error it is the failed item. On an output error it is the item
// that was current when the output failed. Absent when nothing was.
extern NSString *const kVibeAudioErrorTrackKey;
// The request identifier of that play, an NSNumber of uint64_t, beside
// kVibeAudioErrorTrackKey (AudioPlayer.h, Request identifiers).
extern NSString *const kVibeAudioErrorRequestIdentifierKey;
// On VibeAudioErrorNotPlaying only: the newest request identifier minted
// before the toggle, an NSNumber of uint64_t, 0 if none was. The reply
// settles every request at or below it and none above it.
extern NSString *const kVibeAudioErrorPrecedingRequestIdentifierKey;
// Whose error it is, an NSNumber of VibeAudioErrorKind. Read it through
// VibeAudioErrorKindOf.
extern NSString *const kVibeAudioErrorKindKey;
typedef NS_ENUM(NSInteger, VibeAudioErrorCode) {
    VibeAudioErrorFileOpenFailed = 1,
    VibeAudioErrorEngineStartFailed,
    VibeAudioErrorDeviceUnavailable,
    VibeAudioErrorNotPlaying,
    VibeAudioErrorFileOpenTimedOut,
    VibeAudioErrorDeviceInUse, // another process holds the device exclusively (macOS hog mode)
    VibeAudioErrorConnectionLost, // a streaming track's download stalled: paused in place, play replays it
};

// Whose failure an error is. The code alone cannot say: an output that would
// not start and a file that would not decode are both
// VibeAudioErrorEngineStartFailed.
typedef NS_ENUM(NSInteger, VibeAudioErrorKind) {
    VibeAudioErrorKindUnknown = 0, // not an error the engine made
    VibeAudioErrorKindTrack,       // the file: open, decode, a stalled stream
    VibeAudioErrorKindOutput,      // the device or the output: unavailable, in use, a refused start
    VibeAudioErrorKindNotPlaying,  // playPause found the engine stopped
};

// The kind the engine stamped. Unknown for nil or any other error.
VibeAudioErrorKind VibeAudioErrorKindOf(NSError * _Nullable error);

// Descriptions are for logs and are never localized. An app chooses the
// line it shows from the error code, with its own rule. An underlying
// error's description is appended in parentheses. The kind is the code's:
// a file open, a timeout, and a lost connection are the track's, NotPlaying
// is its own, and every other code is the output's.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying);
// The same, with the failing track's URL under kVibeAudioErrorTrackURLKey.
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying, NSURL * _Nullable trackURL);
// The same, with a kind the code does not imply, such as a decode failure,
// which is VibeAudioErrorEngineStartFailed and the track's.
NSError *VibeAudioErrorOfKind(VibeAudioErrorKind kind, VibeAudioErrorCode code, NSString *description,
                              NSError * _Nullable underlying, NSURL * _Nullable trackURL);

NS_ASSUME_NONNULL_END
