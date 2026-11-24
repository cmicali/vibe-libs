//
//  VibeFakeDropbox.h
//  vibe-libs
//
//  A stand-in Dropbox for an app's debug checks and tests: a directory on
//  disk answers as the account, over the client's own HTTP boundary (an
//  NSURLProtocol on its sessions), so the mirror, the browser, search and
//  every open run unchanged against a scripted tree with no sign-in, no
//  network and no account. The sign-in is Dropbox's web sheet, which only a
//  human can fill, and the mirror is lazy — a folder exists locally only
//  once something listed it — which is exactly the class of bug a scripted
//  tree reproduces.
//
//  Its serving engine is vibe-libs' files/HTTP fake (VibeFakeHTTPProtocol.h),
//  which the fake web server and the tests' HTTPStub share. This file holds
//  the account's routes, its tree, its faults and its log.
//
//  TRAP: installing replaces the account the client holds, and saves the
//  fake one in the client's Keychain service. The mirror then prunes every
//  other account's directory, and the uninstall deletes the Keychain item. So
//  a client with a real sign-in loses it and its downloads. Install the fake
//  over a client made with a Keychain service and a mirror root of its own.
//
//  The body compiles only under DEBUG, so a call from release code fails to
//  link. The piece's own tests script one request at a time over
//  DropboxStubProtocol. This fake is an account backed by a directory, for an
//  app's checks. It does not cover the PKCE sign-in (Dropbox's web sheet), an
//  expired token on a JSON call, or a file added or removed after the install.
//

#import <Foundation/Foundation.h>

@class DropboxClient;

NS_ASSUME_NONNULL_BEGIN

@interface VibeFakeDropbox : NSObject

// `directory` is the account's root: its folders are Dropbox folders, its
// files Dropbox files, ids are paths, and each file has a rev, named in every
// answer's Dropbox-API-Result and readable as a `rev:` path, that moves when
// the file's size or mtime does, as a re-upload's would. Indexed once here, so
// a request is a lookup. The client's
// sessions are rebuilt over the fake and the account is linked as a completed
// sign-in would be; installing again over an installed fake swaps the tree
// and clears the faults and the log, leaving the sessions alone. A download
// is paced in 64 KB pieces so the whole file takes about transferSeconds (0:
// at once), or at a `rate` fault's bytes per second; a resend from a Range
// is paced the same way from its offset, and a closed range — a tag read or
// the tail window — answers at once. Every answer carries Dropbox-API-Result.
+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client;

// Forgets the fake account, sending nothing, and puts the client back on the
// network.
+ (void)uninstallFromClient:(DropboxClient *)client;

+ (BOOL)isInstalled;

// One fault, for the file of that basename or, with nil, every file; each
// drives one of the client's streaming roads. NO for an unknown kind.
//   stall       a download delivers up to `after` bytes, then nothing until
//               resumeStalls (persistent)
//   drop        once: the body ends with a lost connection at `after` bytes
//   rev-change  once: as drop, and the file takes a new rev, so the resend's
//               Dropbox-API-Result names another version
//   throttle    once: a download answers 429 with Retry-After `seconds`
//   expired-token once: a download answers 401 expired_access_token
//   tail-fail   the tail read (the closed range of the file's last
//               VibeAudioFileTailWindowBytes) answers 500 (persistent)
//   slow-tail   the tail read answers after `seconds` (persistent)
//   slow-tags   any other ranged read — the tag parse's — answers after
//               `seconds` (persistent)
//   rate        downloads are paced at `rate` bytes per second (persistent)
//   latency     every files/download answers `seconds` late: a server's time
//               to first byte, which the tail read pays beside the download's
//               (persistent)
//   fail        the file's next `after` downloads, at least one, answer 409
//               path/not_found, which the client never retries, so the
//               download fails where the app sees it
//   offline     every request, JSON calls included, fails with
//               NSURLErrorNotConnectedToInternet. It takes no file
//               (persistent)
+ (BOOL)addFaultOfKind:(NSString *)kind
                  file:(nullable NSString *)file
                 after:(uint64_t)after
               seconds:(NSTimeInterval)seconds
                  rate:(uint64_t)rate;
+ (void)clearFaults;
// At most this many entries per list_folder page, so a folder larger than it
// lists through files/list_folder/continue. 0, the default after an install,
// pages by the request's own limit.
+ (void)setListPageSize:(NSUInteger)entries;
// Lifts every stall; the stalled downloads go on from where they stopped.
+ (void)resumeStalls;

// {requests: {endpoint: count}, downloads: {whole, resume, ranged, tail},
// faults, transfers (the downloads delivering now: delivered, size, stalled),
// log (the last downloads and reads: kind, range, status, rev, delivered,
// outcome)}.
+ (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END
